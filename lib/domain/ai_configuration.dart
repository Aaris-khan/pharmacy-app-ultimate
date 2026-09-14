enum AiProviderProtocol { gemini, chatCompletions, anthropicMessages }

class AiConfiguration {
  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.key = '',
    this.localBrainEnabled = false,
    this.streamingEnabled = true,
    this.jsonModeEnabled,
    this.responseTimeoutSeconds = 90,
  });
  final String provider, model, endpoint, key;
  final bool localBrainEnabled, streamingEnabled;

  /// null preserves the legacy default: JSON mode for Gemini, prompt-only for
  /// compatible servers. This is configured capability, never inferred from a
  /// model's brand/name. Every result still passes the same domain validator.
  final bool? jsonModeEnabled;
  final int responseTimeoutSeconds;

  AiProviderProtocol get protocol => switch (provider) {
    'Gemini' => AiProviderProtocol.gemini,
    'OpenAI' || 'Compatible' || 'OpenAI-compatible' =>
      AiProviderProtocol.chatCompletions,
    'Anthropic' => AiProviderProtocol.anthropicMessages,
    _ => throw const FormatException('Choose a supported API protocol.'),
  };

  String get providerLabel => switch (protocol) {
    AiProviderProtocol.gemini => 'Google Gemini',
    AiProviderProtocol.chatCompletions =>
      provider == 'OpenAI' ? 'OpenAI' : 'OpenAI-compatible',
    AiProviderProtocol.anthropicMessages => 'Anthropic',
  };

  bool get useJsonMode =>
      jsonModeEnabled ?? protocol == AiProviderProtocol.gemini;

  Duration get responseTimeout {
    if (responseTimeoutSeconds < 10 || responseTimeoutSeconds > 180) {
      throw const FormatException('AI response timeout must be 10–180 seconds.');
    }
    return Duration(seconds: responseTimeoutSeconds);
  }

  AiConfiguration copyWith({
    String? provider,
    String? model,
    String? endpoint,
    String? key,
    bool? localBrainEnabled,
    bool? streamingEnabled,
    bool? jsonModeEnabled,
    int? responseTimeoutSeconds,
  }) => AiConfiguration(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    key: key ?? this.key,
    localBrainEnabled: localBrainEnabled ?? this.localBrainEnabled,
    streamingEnabled: streamingEnabled ?? this.streamingEnabled,
    jsonModeEnabled: jsonModeEnabled ?? this.jsonModeEnabled,
    responseTimeoutSeconds:
        responseTimeoutSeconds ?? this.responseTimeoutSeconds,
  );

  // This envelope belongs exclusively in platform-backed secure storage. It must
  // never be included in inventory export, backup or diagnostics.
  Map<String, dynamic> toJson() => {
    'version': 2,
    'provider': provider,
    'model': model,
    'endpoint': endpoint,
    'key': key,
    'localBrainEnabled': localBrainEnabled,
    'streamingEnabled': streamingEnabled,
    'jsonModeEnabled': jsonModeEnabled,
    'responseTimeoutSeconds': responseTimeoutSeconds,
  };

  factory AiConfiguration.fromJson(Map<String, dynamic> data) {
    String text(String name, String fallback, int limit) {
      final value = data[name];
      if (value == null) return fallback;
      if (value is! String || value.length > limit) {
        throw const FormatException('Saved AI configuration is invalid.');
      }
      return value;
    }
    bool boolean(String name, bool fallback) {
      final value = data[name];
      if (value == null) return fallback;
      if (value is! bool) {
        throw const FormatException('Saved AI capability is invalid.');
      }
      return value;
    }
    final version = data['version'];
    if (version != null && version != 1 && version != 2) {
      throw const FormatException('Saved AI configuration version is unsupported.');
    }
    final jsonMode = data['jsonModeEnabled'];
    final timeout = data['responseTimeoutSeconds'] ?? 90;
    if ((jsonMode != null && jsonMode is! bool) ||
        timeout is! int || timeout < 10 || timeout > 180) {
      throw const FormatException('Saved AI capabilities are invalid.');
    }
    final config = AiConfiguration(
      provider: text('provider', 'Gemini', 80),
      model: text('model', '', 200),
      endpoint: text('endpoint', '', 2048),
      key: text('key', '', 8192),
      localBrainEnabled: boolean('localBrainEnabled', false),
      streamingEnabled: boolean('streamingEnabled', true),
      jsonModeEnabled: jsonMode as bool?,
      responseTimeoutSeconds: timeout,
    );
    config.protocol;
    return config;
  }

  Uri get uri {
    if (model.trim().isEmpty || key.trim().isEmpty) {
      throw const FormatException('Enter your model name and API key.');
    }
    if (model.length > 200 || key.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(model) ||
        RegExp(r'[\r\n\x00]').hasMatch(key)) {
      throw const FormatException('Model name or API credential is invalid.');
    }
    responseTimeout;
    switch (protocol) {
      case AiProviderProtocol.gemini:
        if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(model)) {
          throw const FormatException('Enter a model name, not a URL.');
        }
        return Uri.https(
          'generativelanguage.googleapis.com',
          '/v1beta/models/$model:generateContent',
        );
      case AiProviderProtocol.anthropicMessages:
        return Uri.https('api.anthropic.com', '/v1/messages');
      case AiProviderProtocol.chatCompletions:
        if (provider == 'OpenAI') {
          return Uri.https('api.openai.com', '/v1/chat/completions');
        }
        final value = Uri.tryParse(endpoint.trim());
        if (endpoint.length > 2048 || value == null ||
            value.scheme != 'https' || value.host.isEmpty ||
            value.userInfo.isNotEmpty || value.hasQuery || value.hasFragment) {
          throw const FormatException(
            'Enter an HTTPS base URL or chat/completions endpoint without credentials or query parameters.',
          );
        }
        // Existing custom full endpoints remain exact. Only conventional base
        // paths are expanded, so proxy deployment prefixes are never discarded.
        final path = value.path.replaceFirst(RegExp(r'/+$'), '');
        if (path.isEmpty) return value.replace(path: '/v1/chat/completions');
        if (path.endsWith('/v1')) {
          return value.replace(path: '$path/chat/completions');
        }
        return value;
    }
  }
}
