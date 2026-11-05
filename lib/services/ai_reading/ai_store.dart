import 'dart:async';
import 'dart:convert';

import 'package:hive_ce/hive.dart';

import '../encrypted_hive.dart';
import 'ai_models.dart';

/// Encrypted persistence for the AI reading feature.
///
/// Formal results, feedback/protection aggregates, prompts, trials and usage
/// are deliberately separate boxes. A formal cache write can never overwrite a
/// feedback asset, and a feedback aggregate is one atomic chapter snapshot.
class AiStore {
  AiStore._();
  static final instance = AiStore._();

  static const formalBoxName = 'ai_formal_v1';
  static const runsBoxName = 'ai_runs_v1';
  static const requestsBoxName = 'ai_requests_v1';
  static const feedbackBoxName = 'ai_feedback_chapter_v1';
  static const promptsBoxName = 'ai_prompts_v1';
  static const candidatesBoxName = 'ai_candidates_v1';
  static const trialsBoxName = 'ai_trials_v1';
  static const trialResultsBoxName = 'ai_trial_results_v1';
  static const usageBoxName = 'ai_usage_aggregate_v1';
  static const pendingBoxName = 'ai_pending_bindings_v1';

  Box<dynamic>? _formal;
  Box<dynamic>? _runs;
  Box<dynamic>? _requests;
  Box<dynamic>? _feedback;
  Box<dynamic>? _prompts;
  Box<dynamic>? _candidates;
  Box<dynamic>? _trials;
  Box<dynamic>? _trialResults;
  Box<dynamic>? _usage;
  Box<dynamic>? _pending;

  Future<void>? _initFuture;
  bool _available = false;
  String? _status;
  final _queues = <String, Future<void>>{};

  bool get isAvailable => _available;
  String? get status => _status;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final opened = await Future.wait([
        EncryptedHive.openBox<dynamic>(
          Hive,
          formalBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          runsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          requestsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          feedbackBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          promptsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          candidatesBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          trialsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          trialResultsBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          usageBoxName,
          requireEncryption: true,
        ),
        EncryptedHive.openBox<dynamic>(
          Hive,
          pendingBoxName,
          requireEncryption: true,
        ),
      ]);
      _formal = opened[0];
      _runs = opened[1];
      _requests = opened[2];
      _feedback = opened[3];
      _prompts = opened[4];
      _candidates = opened[5];
      _trials = opened[6];
      _trialResults = opened[7];
      _usage = opened[8];
      _pending = opened[9];
      _available = true;
      _status = null;
    } catch (error) {
      _available = false;
      _status = 'AI 数据箱不可用：$error';
    }
  }

  // ── Formal cache ────────────────────────────────────────────────────────

  String formalKey(String bookId, String hash) => jsonEncode([bookId, hash]);

  Future<AiFormalCacheEntry?> formal(String bookId, String hash) async {
    if (!_available) return null;
    final raw = _formal?.get(formalKey(bookId, hash));
    final entry = AiFormalCacheEntry.fromJson(raw);
    if (entry == null) return null;
    // A stale schema should be a miss, not a crash.
    if (entry.canonicalVersion != 1 || entry.canonicalHash != hash) return null;
    return entry;
  }

  /// Commits one formal result with a generation CAS.
  ///
  /// The compare and the write run on the same per-key queue, so a slower
  /// request cannot overwrite a newer refresh. Equal-generation writes from a
  /// different run are also rejected; the stored result wins.
  Future<bool> putFormal(AiFormalCacheEntry entry) async {
    if (!_available) throw StateError(_status ?? 'AI 数据箱不可用');
    final key = formalKey(entry.bookId, entry.canonicalHash);
    final queueKey = 'formal:$key';
    final previous = _queues[queueKey] ?? Future<void>.value();
    final completer = Completer<bool>();
    _queues[queueKey] = previous.then((_) async {
      try {
        final current = AiFormalCacheEntry.fromJson(_formal?.get(key));
        if (current != null && entry.generation < current.generation) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        if (current != null &&
            entry.generation == current.generation &&
            current.activeRunId != entry.activeRunId) {
          if (!completer.isCompleted) completer.complete(false);
          return;
        }
        await _formal?.put(key, entry.toJson());
        if (!completer.isCompleted) completer.complete(true);
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> deleteFormal(String bookId, String hash) async {
    await _formal?.delete(formalKey(bookId, hash));
  }

  /// Drops every formal correction result. Feedback, protections, prompts and
  /// usage ledgers are separate assets and are intentionally untouched.
  Future<void> clearFormal() async {
    await _formal?.clear();
  }

  Future<List<AiFormalCacheEntry>> allFormal() async {
    if (!_available) return const [];
    return [
      for (final value in _formal?.values ?? const [])
        if (AiFormalCacheEntry.fromJson(value) case final entry?) entry,
    ];
  }

  // ── Runs / requests ─────────────────────────────────────────────────────

  Future<void> putRun(AiRunRecord run) async {
    await _runs?.put(run.runId, run.toJson());
  }

  Future<void> putRequest(AiRequestRecord request) async {
    await _requests?.put(request.requestId, request.toJson());
  }

  Future<List<AiRequestRecord>> requests() async {
    if (!_available) return const [];
    return [
      for (final value in _requests?.values ?? const [])
        if (AiRequestRecord.fromJson(value) case final record?) record,
    ];
  }

  Future<List<AiRunRecord>> runs() async {
    if (!_available) return const [];
    return [
      for (final value in _runs?.values ?? const [])
        if (AiRunRecord.fromJson(value) case final record?) record,
    ];
  }

  /// Explicit "clear usage ledger" action. Never touches feedback, protections,
  /// prompts or formal cache.
  Future<void> clearLedgers() async {
    await _requests?.clear();
    await _runs?.clear();
    await _usage?.clear();
  }

  // ── Feedback aggregate (single-key CAS) ─────────────────────────────────

  Future<AiFeedbackAggregate?> aggregate({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
  }) async {
    if (!_available) return null;
    final key = jsonEncode([
      bookId,
      chapterId,
      canonicalVersion,
      canonicalHash,
    ]);
    final parsed = AiFeedbackAggregate.fromJson(_feedback?.get(key));
    if (parsed == null) return null;
    if (parsed.canonicalVersion != canonicalVersion ||
        parsed.canonicalHash != canonicalHash) {
      return null;
    }
    return parsed;
  }

  Future<List<AiFeedbackAggregate>> allAggregates() async {
    if (!_available) return const [];
    return [
      for (final value in _feedback?.values ?? const [])
        if (AiFeedbackAggregate.fromJson(value) case final aggregate?)
          aggregate,
    ];
  }

  /// Serialises read-modify-write for one chapter snapshot. The callback gets
  /// the current aggregate (or null) and returns the next one; the store
  /// assigns `aggregateRevision` and writes the whole snapshot in one put.
  Future<AiFeedbackAggregate> mutateAggregate({
    required String bookId,
    required String chapterId,
    required int canonicalVersion,
    required String canonicalHash,
    required FutureOr<AiFeedbackAggregate> Function(
      AiFeedbackAggregate? current,
    )
    mutate,
  }) async {
    if (!_available) throw StateError(_status ?? 'AI 数据箱不可用');
    final key = jsonEncode([
      bookId,
      chapterId,
      canonicalVersion,
      canonicalHash,
    ]);
    final previous = _queues[key] ?? Future<void>.value();
    final completer = Completer<AiFeedbackAggregate>();
    _queues[key] = previous.then((_) async {
      try {
        final current = AiFeedbackAggregate.fromJson(_feedback?.get(key));
        var next = await mutate(current);
        next = AiFeedbackAggregate(
          bookId: bookId,
          chapterId: chapterId,
          canonicalVersion: canonicalVersion,
          canonicalHash: canonicalHash,
          aggregateRevision: (current?.aggregateRevision ?? 0) + 1,
          cases: List.unmodifiable(next.cases),
          protections: List.unmodifiable(next.protections),
          updatedAt: DateTime.now(),
        );
        _validateAggregate(next);
        await _feedback?.put(key, next.toJson());
        if (!completer.isCompleted) completer.complete(next);
      } catch (error, stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void _validateAggregate(AiFeedbackAggregate aggregate) {
    final ids = <String>{};
    for (final feedback in aggregate.cases) {
      if (!ids.add(feedback.feedbackId)) {
        throw StateError('反馈 ID 重复');
      }
    }
    final active = aggregate.activeProtections;
    for (var i = 0; i < active.length; i++) {
      for (var j = i + 1; j < active.length; j++) {
        final a = active[i];
        final b = active[j];
        if (a.sourceStart < b.sourceEnd && b.sourceStart < a.sourceEnd) {
          throw StateError('生效保护区间相交');
        }
      }
    }
  }

  /// Preflight validator for the backup importer. Running this before any
  /// write keeps an invalid file from partially mutating the asset boxes.
  void validateAggregateForRestore(AiFeedbackAggregate aggregate) =>
      _validateAggregate(aggregate);

  /// Restores a validated aggregate. Used only by the backup importer after a
  /// full preflight; normal UI writes go through [mutateAggregate].
  Future<void> putAggregate(AiFeedbackAggregate aggregate) async {
    _validateAggregate(aggregate);
    await _feedback?.put(aggregate.key, aggregate.toJson());
  }

  Future<void> deleteAggregate(AiFeedbackAggregate aggregate) async {
    await _feedback?.delete(aggregate.key);
  }

  // ── Prompts / candidates / trials ───────────────────────────────────────

  Future<void> putPrompt(AiPromptRecord prompt) async {
    await _prompts?.put(prompt.promptId, prompt.toJson());
  }

  Future<List<AiPromptRecord>> prompts() async {
    if (!_available) return const [];
    return [
      for (final value in _prompts?.values ?? const [])
        if (AiPromptRecord.fromJson(value) case final prompt?) prompt,
    ];
  }

  Future<void> putCandidate(AiPromptCandidate candidate) async {
    await _candidates?.put(candidate.candidateId, candidate.toJson());
  }

  Future<List<AiPromptCandidate>> candidates() async {
    if (!_available) return const [];
    return [
      for (final value in _candidates?.values ?? const [])
        if (AiPromptCandidate.fromJson(value) case final candidate?) candidate,
    ];
  }

  Future<void> putTrial(AiTrialRecord trial) async {
    await _trials?.put(trial.trialId, trial.toJson());
  }

  Future<List<AiTrialRecord>> trials() async {
    if (!_available) return const [];
    return [
      for (final value in _trials?.values ?? const [])
        if (AiTrialRecord.fromJson(value) case final trial?) trial,
    ];
  }

  Future<void> putTrialResult(AiTrialResultRecord result) async {
    await _trialResults?.put(
      jsonEncode([result.trialId, result.chapterId]),
      result.toJson(),
    );
  }

  Future<List<AiTrialResultRecord>> trialResults([String? trialId]) async {
    if (!_available) return const [];
    return [
      for (final value in _trialResults?.values ?? const [])
        if (AiTrialResultRecord.fromJson(value) case final result?)
          if (trialId == null || result.trialId == trialId) result,
    ];
  }

  // ── Usage projections ───────────────────────────────────────────────────

  Future<AiBudgetProjection?> projection(String day, String? bookId) async {
    if (!_available) return null;
    return AiBudgetProjection.fromJson(_usage?.get(jsonEncode([day, bookId])));
  }

  Future<void> putProjection(AiBudgetProjection projection) async {
    await _usage?.put(projection.key, projection.toJson());
  }

  Future<List<AiBudgetProjection>> projections() async {
    if (!_available) return const [];
    return [
      for (final value in _usage?.values ?? const [])
        if (AiBudgetProjection.fromJson(value) case final projection?)
          projection,
    ];
  }

  // ── Pending local-book bindings ─────────────────────────────────────────

  Future<void> putPending(AiPendingBinding binding) async {
    await _pending?.put(binding.id, binding.toJson());
  }

  Future<List<AiPendingBinding>> pendingBindings() async {
    if (!_available) return const [];
    return [
      for (final value in _pending?.values ?? const [])
        if (AiPendingBinding.fromJson(value) case final binding?) binding,
    ];
  }

  Future<void> deletePending(String id) async {
    await _pending?.delete(id);
  }

  /// Device-only retention: request/run rows older than 180 days and raw trial
  /// edits beyond the latest five per book. Feedback, protections, prompts and
  /// formal cache are never pruned here.
  Future<void> prune({DateTime? now}) async {
    if (!_available) return;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 180));
    for (final box in [_runs, _requests]) {
      if (box == null) continue;
      final doomed = <dynamic>[];
      for (final key in box.keys) {
        final value = box.get(key);
        final map = value is Map ? value : const {};
        final date = _date(map['startedAt']);
        if (date != null && date.isBefore(cutoff)) doomed.add(key);
      }
      if (doomed.isNotEmpty) await box.deleteAll(doomed);
    }
    final results = await trialResults();
    final byBook = <String, List<AiTrialResultRecord>>{};
    for (final result in results) {
      final trial = (await trials()).where((t) => t.trialId == result.trialId);
      final bookId = trial.isEmpty ? '' : trial.first.bookId;
      byBook.putIfAbsent(bookId, () => []).add(result);
    }
    for (final entry in byBook.entries) {
      entry.value.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (final old in entry.value.skip(5)) {
        await _trialResults?.delete(jsonEncode([old.trialId, old.chapterId]));
      }
    }
  }

  static DateTime? _date(Object? value) {
    if (value is int && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }
}
