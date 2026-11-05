import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_models.dart';
import 'ai_prompt.dart';

class AiNetworkException implements Exception {
  const AiNetworkException(
    this.code,
    this.message, {
    this.statusCode,
    this.retryable = false,
    this.retryAfter,
  });

  final String code;
  final String message;
  final int? statusCode;
  final bool retryable;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

class AiProviderResponse {
  const AiProviderResponse({
    required this.content,
    required this.usage,
    required this.finishReason,
    required this.latency,
    this.rawResponseBytes = 0,
  });

  final String content;
  final AiUsage usage;
  final String? finishReason;
  final Duration latency;
  final int rawResponseBytes;
}

class AiChatCompletionsClient {
  AiChatCompletionsClient({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static Uri endpoint(String baseUrl) {
    var value = baseUrl.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.endsWith('/chat/completions')) return Uri.parse(value);
    if (value.endsWith('/v1')) return Uri.parse('$value/chat/completions');
    return Uri.parse('$value/chat/completions');
  }

  static void validateBaseUrl(String baseUrl, {bool allowLocalhost = false}) {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const AiNetworkException('INVALID_BASE_URL', 'Base URL 无效');
    }
    if (uri.scheme == 'https') return;
    final local =
        uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1';
    if (uri.scheme == 'http' && allowLocalhost && local) return;
    throw const AiNetworkException(
      'INSECURE_BASE_URL',
      '仅允许 HTTPS；本机 localhost 调试地址需要显式开启',
    );
  }

  /// DeepSeek uses a `thinking` object; other OpenAI-compatible providers take
  /// `reasoning_effort` directly. `auto` sends nothing so existing providers
  /// keep their server defaults.
  static Map<String, dynamic> _reasoningBody(
    AiProviderProfile profile,
    AiReasoningEffort effort,
  ) {
    if (effort == AiReasoningEffort.auto) return const {};
    final deepseek =
        profile.id == 'deepseek' ||
        profile.host.toLowerCase().endsWith('deepseek.com');
    if (deepseek) {
      if (effort == AiReasoningEffort.off) {
        return const {
          'thinking': {'type': 'disabled'},
        };
      }
      return {
        'thinking': const {'type': 'enabled'},
        'reasoning_effort': effort.wire,
      };
    }
    return {'reasoning_effort': effort.wire};
  }

  Future<AiProviderResponse> complete({
    required AiProviderProfile profile,
    required String apiKey,
    required String model,
    required String systemPrompt,
    required String userText,
    required AiOutputMode outputMode,
    required int maxOutputTokens,
    required Duration timeout,
    bool jsonResponse = true,
  }) async {
    validateBaseUrl(profile.baseUrl);
    if (apiKey.trim().isEmpty) {
      throw const AiNetworkException('MISSING_KEY', '还没有填写 API Key');
    }
    if (model.trim().isEmpty) {
      throw const AiNetworkException('MISSING_MODEL', '还没有选择模型');
    }
    final uri = endpoint(profile.baseUrl);
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userText},
      ],
      'stream': false,
      'temperature': profile.temperature,
      ..._reasoningBody(profile, profile.reasoningEffort),
      if (maxOutputTokens > 0) 'max_tokens': maxOutputTokens,
      if (jsonResponse)
        'response_format': switch (outputMode) {
          AiOutputMode.jsonObject => {'type': 'json_object'},
          AiOutputMode.jsonSchema => {
            'type': 'json_schema',
            'json_schema': {
              'name': 'ai_edits_v1',
              'strict': true,
              'schema': aiJsonSchemaProjection(),
            },
          },
        },
    };
    final started = DateTime.now();
    http.Response response;
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${apiKey.trim()}',
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        })
        ..body = jsonEncode(body);
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed).timeout(timeout);
    } on TimeoutException {
      throw const AiNetworkException(
        'TIMEOUT',
        '请求超时。请求可能已经到达服务商，未自动重发',
        retryable: false,
      );
    } on http.ClientException catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        '网络请求失败：${error.message}',
        retryable: true,
      );
    } catch (error) {
      throw AiNetworkException(
        'NETWORK_ERROR',
        '网络请求失败：$error',
        retryable: true,
      );
    }
    final latency = DateTime.now().difference(started);
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const AiNetworkException(
        'REDIRECT_BLOCKED',
        '服务商返回重定向，已阻止携带凭据跟随',
        retryable: false,
      );
    }
    if (response.statusCode != 200) {
      final retryAfter = _retryAfter(response.headers['retry-after']);
      final detail = _errorMessage(text);
      throw AiNetworkException(
        _statusCode(response.statusCode),
        detail,
        statusCode: response.statusCode,
        retryable:
            response.statusCode == 408 ||
            response.statusCode == 429 ||
            response.statusCode >= 500,
        retryAfter: retryAfter,
      );
    }
    dynamic raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const AiNetworkException(
        'API_ERROR',
        '服务商返回了非 JSON 响应',
        retryable: false,
      );
    }
    final map = _map(raw);
    if (map == null) {
      throw const AiNetworkException('API_ERROR', '服务商响应结构无效');
    }
    final choices = map['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiNetworkException('RESPONSE_EMPTY', '服务商没有返回 choices');
    }
    final first = _map(choices.first);
    final message = _map(first?['message']);
    final finishReason = first?['finish_reason'] is String
        ? first!['finish_reason'] as String
        : null;
    final refusal = message?['refusal'];
    if (refusal is String && refusal.trim().isNotEmpty) {
      throw AiNetworkException('REFUSAL', '模型拒绝了本次请求：$refusal');
    }
    final content = message?['content'];
    if (content is! String || content.trim().isEmpty) {
      throw AiNetworkException(
        'RESPONSE_EMPTY',
        finishReason == 'length' ? '模型输出被长度限制截断' : '模型返回了空内容',
      );
    }
    if (finishReason == 'length') {
      throw const AiNetworkException('FINISH_REASON_LENGTH', '模型输出被长度限制截断');
    }
    if (finishReason == 'content_filter') {
      throw const AiNetworkException(
        'FINISH_REASON_CONTENT_FILTER',
        '模型输出被内容过滤',
      );
    }
    return AiProviderResponse(
      content: content,
      usage: _usage(map['usage']),
      finishReason: finishReason,
      latency: latency,
      rawResponseBytes: response.bodyBytes.length,
    );
  }

  Future<AiModelCapability> probe({
    required AiProviderProfile profile,
    required String apiKey,
    required String model,
    required AiOutputMode outputMode,
    required Duration timeout,
  }) async {
    final key = AiSettingsCapabilityKey.of(
      providerId: profile.id,
      baseUrl: profile.baseUrl,
      modelId: model,
      mode: outputMode,
    );
    try {
      await complete(
        profile: profile,
        apiKey: apiKey,
        model: model,
        systemPrompt: outputMode == AiOutputMode.jsonObject
            ? '只输出 json。$kAiJsonObjectProtocol'
            : '只输出符合给定 schema 的 JSON。',
        userText: '这是连接测试。请返回 {"edits":[]}。',
        outputMode: outputMode,
        maxOutputTokens: 64,
        timeout: timeout,
      );
      return AiModelCapability(
        key: key,
        providerId: profile.id,
        endpoint: endpoint(profile.baseUrl).toString(),
        apiFamily: 'chat.completions',
        modelId: model,
        outputMode: outputMode,
        schemaStrict: outputMode == AiOutputMode.jsonSchema,
        schemaProjectionHash: aiSchemaProjectionHash(),
        verifiedAt: DateTime.now(),
        ok: true,
      );
    } on AiNetworkException catch (error) {
      return AiModelCapability(
        key: key,
        providerId: profile.id,
        endpoint: endpoint(profile.baseUrl).toString(),
        apiFamily: 'chat.completions',
        modelId: model,
        outputMode: outputMode,
        schemaStrict: false,
        schemaProjectionHash: aiSchemaProjectionHash(),
        verifiedAt: DateTime.now(),
        ok: false,
        detail: error.message,
      );
    }
  }

  static AiUsage _usage(Object? raw) {
    final map = _map(raw) ?? const {};
    final prompt = _int(map['prompt_tokens']);
    final completion = _int(map['completion_tokens']);
    final total = _int(map['total_tokens']);
    final promptDetails = _map(map['prompt_tokens_details']);
    final completionDetails = _map(map['completion_tokens_details']);
    final cached =
        _int(promptDetails?['cached_tokens']) ??
        _int(map['prompt_cache_hit_tokens']);
    final reasoning = _int(completionDetails?['reasoning_tokens']);
    final any =
        prompt != null ||
        completion != null ||
        total != null ||
        cached != null ||
        reasoning != null;
    final status = !any
        ? AiUsageStatus.unknown
        : prompt != null && (completion != null || total != null)
        ? AiUsageStatus.known
        : AiUsageStatus.partial;
    return AiUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      cachedTokens: cached,
      reasoningTokens: reasoning,
      status: status,
    );
  }

  static Duration? _retryAfter(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null && seconds > 0) return Duration(seconds: seconds);
    final date = DateTime.tryParse(value);
    if (date != null) {
      final delta = date.difference(DateTime.now());
      if (delta > Duration.zero) return delta;
    }
    return null;
  }

  static String _errorMessage(String text) {
    try {
      final raw = jsonDecode(text);
      final map = _map(raw);
      final error = _map(map?['error']);
      final message = error?['message'] ?? map?['message'];
      if (message is String && message.trim().isNotEmpty) {
        return message.length > 300 ? message.substring(0, 300) : message;
      }
    } catch (_) {}
    return text.trim().isEmpty ? '服务商请求失败' : '服务商请求失败（${text.length} 字节）';
  }

  static String _statusCode(int status) => switch (status) {
    401 || 403 => 'AUTH_ERROR',
    404 => 'MODEL_OR_ENDPOINT_NOT_FOUND',
    408 => 'TIMEOUT',
    429 => 'RATE_LIMITED',
    >= 500 => 'SERVER_ERROR',
    400 || 422 => 'REQUEST_REJECTED',
    _ => 'API_ERROR',
  };

  static Map<String, dynamic>? _map(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry('$key', value));
    return null;
  }

  static int? _int(Object? value) => switch (value) {
    int v => v,
    num v when v.isFinite => v.toInt(),
    _ => null,
  };
}

/// Small helper kept here so the client and the settings store build the same
/// capability key without importing each other's private state.
class AiSettingsCapabilityKey {
  const AiSettingsCapabilityKey._();
  static String of({
    required String providerId,
    required String baseUrl,
    required String modelId,
    required AiOutputMode mode,
  }) {
    final endpoint = AiChatCompletionsClient.endpoint(baseUrl).toString();
    return jsonEncode([
      providerId,
      endpoint,
      'chat.completions',
      modelId,
      mode.wire,
      aiSchemaProjectionHash(),
    ]);
  }
}
