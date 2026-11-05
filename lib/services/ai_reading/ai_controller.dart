import 'package:flutter/foundation.dart';

import '../chapter_text_formatter.dart';
import '../../models/text_replacement_rule.dart';
import '../text_replacement_engine.dart';
import 'ai_budget.dart';
import 'ai_chapter_snapshot.dart';
import 'ai_coordinator.dart';
import 'ai_display_composition.dart';
import 'ai_feedback.dart';
import 'ai_models.dart';
import 'ai_settings.dart';
import 'ai_store.dart';

class AiChapterView {
  const AiChapterView({
    required this.bookId,
    required this.chapterId,
    required this.snapshot,
    required this.composition,
    required this.mode,
    required this.status,
    required this.aiEnabled,
    required this.consent,
    this.lastError,
  });

  final String bookId;
  final String chapterId;
  final AiChapterSnapshot snapshot;
  final AiCompositionResult composition;
  final AiDisplayMode mode;
  final String status;
  final bool aiEnabled;
  final bool consent;
  final String? lastError;

  bool get hasCache => composition.formal != null;
  int get editCount => composition.formal?.edits.length ?? 0;
  int get visibleCount =>
      _visibleCount(composition.formal, composition.skippedByProtection) +
      composition.approvedCount;

  static int _visibleCount(AiFormalCacheEntry? formal, int skipped) {
    final total = formal?.edits.length ?? 0;
    return (total - skipped).clamp(0, total);
  }
}

/// Process-wide facade used by the reader, settings pages and backup.
///
/// It owns no BuildContext. Every operation is safe to call before [init]
/// completes; the store/settings then report unavailable and callers degrade to
/// the original chapter.
class AiReadingController extends ChangeNotifier {
  AiReadingController._();
  static final instance = AiReadingController._();

  final _settings = AiSettingsStore.instance;
  final _store = AiStore.instance;
  final _composition = AiDisplayComposition.instance;
  final _coordinator = AiCoordinator.instance;
  final _budget = AiBudgetService.instance;

  bool _initialized = false;
  Future<void>? _initFuture;
  int revision = 0;
  int _prefetchEpoch = 0;
  final _status = <String, AiChapterRunStatus>{};
  final _inflight = <String, Future<AiTaskResult?>>{};

  AiSettingsStore get settings => _settings;
  AiStore get store => _store;
  AiBudgetService get budget => _budget;

  bool get isReady =>
      _initialized && _settings.isAvailable && _store.isAvailable;
  String? get unavailableReason => _settings.status ?? _store.status;

  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    await _settings.init();
    await _store.init();
    try {
      await _store.prune();
    } catch (_) {
      // Retention cleanup must never block reading.
    }
    _initialized = true;
    _settings.addListener(_onSettingsChanged);
    AiFeedbackService.instance.addListener(_onSettingsChanged);
    notifyListeners();
  }

  void _onSettingsChanged() {
    revision++;
    notifyListeners();
  }

  String _chapterKey(String bookId, String chapterId) =>
      '$bookId\u0000$chapterId';

  String _requestKey(String bookId, String canonicalHash) =>
      '$bookId\u0000formal\u0000$canonicalHash';

  AiChapterRunStatus statusFor(String bookId, String chapterId) =>
      _status[_chapterKey(bookId, chapterId)] ?? AiChapterRunStatus.idle();

  AiCompositionConfig configFor(String bookId) {
    final effective = _settings.resolve(bookId);
    return AiCompositionConfig(
      aiRequestEnabled: effective.enabled,
      displayMode: effective.displayMode,
    );
  }

  Future<AiChapterView> viewFor({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    required TextReplacementSnapshot customSnapshot,
    bool temporaryOriginal = false,
    int? previewSourceStart,
    int? previewSourceEnd,
    TextReplacementEngine? replacementEngine,
  }) async {
    // Reading never waits for AI storage. The app boot and settings pages
    // start [init]; before it finishes, compose with defaults and re-render
    // when the store notifies.
    final snapshot = AiChapterSnapshotBuilder.fromContent(
      content,
      chapterTitle,
    );
    final effective = _settings.resolve(bookId);
    final config = AiCompositionConfig(
      aiRequestEnabled: effective.enabled,
      displayMode: effective.displayMode,
      temporaryOriginal: temporaryOriginal,
      previewSourceStart: previewSourceStart,
      previewSourceEnd: previewSourceEnd,
    );
    final composition = await _composition.compose(
      bookId: bookId,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      content: content,
      snapshot: snapshot,
      customSnapshot: customSnapshot,
      config: config,
      replacementEngine: replacementEngine,
    );
    final status = statusFor(bookId, chapterId);
    final label = _statusLabel(
      effective: effective,
      composition: composition,
      status: status,
      config: config,
    );
    return AiChapterView(
      bookId: bookId,
      chapterId: chapterId,
      snapshot: snapshot,
      composition: composition,
      mode: config.effectiveMode,
      status: label,
      aiEnabled: effective.enabled,
      consent:
          _settings.device.cloudConsent && !_settings.device.deviceDisabled,
      lastError: status.error ?? composition.error,
    );
  }

  String _statusLabel({
    required AiEffectiveSettings effective,
    required AiCompositionResult composition,
    required AiChapterRunStatus status,
    required AiCompositionConfig config,
  }) {
    if (!effective.enabled) return 'AI 阅读优化已关闭';
    if (_settings.device.deviceDisabled) return '本机已停用 AI 请求';
    if (!_settings.device.cloudConsent) return '需要同意云端正文传输';
    if (status.running) return '校对中';
    if (status.error != null) return '失败，显示原文';
    if (config.effectiveMode == AiDisplayMode.original) {
      final count = composition.formal?.edits.length ?? 0;
      return count == 0 ? '显示原文' : '显示原文，已缓存 $count 处修改';
    }
    if (config.effectiveMode == AiDisplayMode.customOnly) {
      final count = composition.formal?.edits.length ?? 0;
      return count == 0 ? '仅自定义替换' : '显示自定义替换，已缓存 $count 处 AI 修改';
    }
    if (composition.formal != null) {
      if (composition.formal!.edits.isEmpty) return '本章无需修改';
      final visible =
          composition.formal!.edits.length -
          composition.skippedByProtection +
          composition.approvedCount;
      if (visible <= 0) return '修改均被锁定跳过';
      return '已应用 $visible 处修改';
    }
    return '未校对';
  }

  /// Starts a real request. [automatic] means prefetch: over-budget stops
  /// silently instead of asking for confirmation. Manual calls can return
  /// `needsBudgetConfirmation`; the UI then asks and retries with
  /// [confirmedOverBudget].
  Future<AiTaskResult?> requestChapter({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    bool forceRefresh = false,
    bool automatic = false,
    bool confirmedOverBudget = false,
  }) async {
    if (!_initialized) return null;
    await init();
    final AiChapterSnapshot snapshot;
    try {
      snapshot = AiChapterSnapshotBuilder.fromContent(content, chapterTitle);
    } on AiSnapshotException {
      return null;
    }
    // The formal cache is keyed by book + canonical hash, not by chapter. Two
    // chapters with identical body text share one in-flight request instead of
    // paying for the same correction twice.
    final key = _requestKey(bookId, snapshot.canonicalHash);
    final existing = _inflight[key];
    if (existing != null && !forceRefresh) return existing;
    final future = _runRequest(
      bookId: bookId,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      content: content,
      forceRefresh: forceRefresh,
      automatic: automatic,
      confirmedOverBudget: confirmedOverBudget,
    );
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    }
  }

  Future<AiTaskResult?> _runRequest({
    required String bookId,
    required String chapterId,
    required String chapterTitle,
    required ChapterContent content,
    required bool forceRefresh,
    required bool automatic,
    required bool confirmedOverBudget,
  }) async {
    final key = _chapterKey(bookId, chapterId);
    final effective = _settings.resolve(bookId);
    if (!effective.enabled) return null;
    if (!_settings.device.cloudConsent || _settings.device.deviceDisabled) {
      return null;
    }
    _status[key] = AiChapterRunStatus.running();
    notifyListeners();
    try {
      final result = await _coordinator.runFormal(
        bookId: bookId,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        content: content,
        kind: forceRefresh ? AiRunKind.formalRefresh : AiRunKind.formalFirst,
        forceRefresh: forceRefresh,
        automatic: automatic,
        confirmedOverBudget: confirmedOverBudget,
        onState: (state) {
          final current = _status[key];
          if (current == null) return;
          _status[key] = current.copyWith(running: true, state: state);
          notifyListeners();
        },
      );
      _status[key] = AiChapterRunStatus(
        running: false,
        success: result.ok,
        error: result.error,
        formal: result.formal,
        needsBudgetConfirmation: result.needsBudgetConfirmation,
        budgetMessage: result.budgetMessage,
        state: result.ok ? AiRunState.success : AiRunState.failed,
      );
      revision++;
      notifyListeners();
      return result;
    } catch (error) {
      _status[key] = AiChapterRunStatus(
        running: false,
        success: false,
        error: '$error',
        state: AiRunState.failed,
      );
      revision++;
      notifyListeners();
      return null;
    }
  }

  /// Cancels queued prefetch work. An HTTP request that is already in flight
  /// cannot be un-billed, but no further chapter will be requested.
  void cancelPrefetch() {
    _prefetchEpoch++;
  }

  /// Called by the reader when the progress crosses the configured trigger.
  Future<void> maybePrefetch({
    required String bookId,
    required String nextChapterId,
    required String nextChapterTitle,
    required ChapterContent nextContent,
    required double chapterProgress,
  }) async {
    if (!_initialized) return;
    final epoch = _prefetchEpoch;
    await init();
    if (epoch != _prefetchEpoch) return;
    final effective = _settings.resolve(bookId);
    if (!effective.enabled || !effective.prefetchEnabled) return;
    if (!_settings.device.cloudConsent || _settings.device.deviceDisabled) {
      return;
    }
    if (chapterProgress < effective.prefetchTriggerRatio) return;
    final AiChapterSnapshot snapshot;
    try {
      snapshot = AiChapterSnapshotBuilder.fromContent(
        nextContent,
        nextChapterTitle,
      );
    } on AiSnapshotException {
      return;
    }
    if (_inflight.containsKey(_requestKey(bookId, snapshot.canonicalHash))) {
      return;
    }
    final cached = await _store.formal(bookId, snapshot.canonicalHash);
    if (cached != null || epoch != _prefetchEpoch) return;
    await requestChapter(
      bookId: bookId,
      chapterId: nextChapterId,
      chapterTitle: nextChapterTitle,
      content: nextContent,
      automatic: true,
    );
  }

  Future<void> setDisplayMode(String bookId, AiDisplayMode mode) async {
    final overrides = _settings.bookOverrides(bookId);
    if (overrides.containsKey('displayMode')) {
      await _settings.setBookOverride(bookId, 'displayMode', mode.name);
    } else {
      await _settings.saveGlobal(_settings.global.copyWith(displayMode: mode));
    }
    revision++;
    notifyListeners();
  }

  Future<void> setBookDisplayMode(String bookId, AiDisplayMode? mode) async {
    if (mode == null) {
      await _settings.clearBookOverride(bookId, 'displayMode');
    } else {
      await _settings.setBookOverride(bookId, 'displayMode', mode.name);
    }
    revision++;
    notifyListeners();
  }

  Future<void> setEnabled(String bookId, bool enabled) async {
    if (!enabled) cancelPrefetch();
    final overrides = _settings.bookOverrides(bookId);
    if (overrides.containsKey('enabled')) {
      await _settings.setBookOverride(bookId, 'enabled', enabled);
    } else {
      await _settings.saveGlobal(_settings.global.copyWith(enabled: enabled));
    }
    revision++;
    notifyListeners();
  }

  Future<void> setCloudConsent(bool value) async {
    if (!value) cancelPrefetch();
    await _settings.saveDevice(_settings.device.copyWith(cloudConsent: value));
    revision++;
    notifyListeners();
  }
}

class AiChapterRunStatus {
  const AiChapterRunStatus({
    required this.running,
    required this.success,
    required this.state,
    this.error,
    this.formal,
    this.needsBudgetConfirmation = false,
    this.budgetMessage,
  });

  factory AiChapterRunStatus.idle() => const AiChapterRunStatus(
    running: false,
    success: false,
    state: AiRunState.interrupted,
  );

  factory AiChapterRunStatus.running() => const AiChapterRunStatus(
    running: true,
    success: false,
    state: AiRunState.running,
  );

  final bool running;
  final bool success;
  final AiRunState state;
  final String? error;
  final AiFormalCacheEntry? formal;
  final bool needsBudgetConfirmation;
  final String? budgetMessage;

  AiChapterRunStatus copyWith({
    bool? running,
    bool? success,
    AiRunState? state,
    String? error,
    AiFormalCacheEntry? formal,
    bool? needsBudgetConfirmation,
    String? budgetMessage,
  }) => AiChapterRunStatus(
    running: running ?? this.running,
    success: success ?? this.success,
    state: state ?? this.state,
    error: error ?? this.error,
    formal: formal ?? this.formal,
    needsBudgetConfirmation:
        needsBudgetConfirmation ?? this.needsBudgetConfirmation,
    budgetMessage: budgetMessage ?? this.budgetMessage,
  );
}
