import 'dart:convert';

import '../domain/ai_configuration.dart';

typedef AiConnectionRead = Future<String?> Function(String key);

/// A single queue owns active-connection and provider-profile writes. Callers
/// supply platform secure storage; credentials never enter inventory storage.
class AiConnectionStore {
  AiConnectionStore({
    required AiConnectionRead read,
    required Future<void> Function(String, String) write,
  }) : _read = read,
       _write = write;
  final AiConnectionRead _read;
  final Future<void> Function(String, String) _write;
  static const configurationKey = 'pharmacy.ai.configuration';
  Future<void> _tail = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<AiConfiguration> _active(AiConnectionRead read) async =>
      AiConfiguration.fromStored(await read(configurationKey));

  Future<AiConfiguration> load({AiConnectionRead? read}) =>
      _serialized(() => _active(read ?? _read));

  Future<AiConfiguration?> forProvider(
    String provider, {
    AiConnectionRead? read,
  }) => _serialized(() async {
    final connectionRead = read ?? _read;
    final id = AiProviderDefinition.forId(provider).id;
    AiConfiguration active;
    try {
      active = await _active(connectionRead);
    } on FormatException {
      active = const AiConfiguration();
    }
    if (active.definition.id == id && active.key.isNotEmpty) return active;
    final raw = await connectionRead('pharmacy.ai.profile.${id}');
    if (raw == null) return active.definition.id == id ? active : null;
    final saved = AiConfiguration.fromStored(raw);
    if (saved.definition.id != id) return null;
    return saved.copyWith(localBrainEnabled: active.localBrainEnabled);
  });

  Future<void> _persist(
    AiConfiguration config, {
    required AiConnectionRead read,
  }) async {
    AiConfiguration old;
    try {
      old = await _active(read);
    } on FormatException {
      old = const AiConfiguration();
    }
    // Migrate the previous single-connection format before switching providers.
    if (old.definition.id != config.definition.id && old.key.isNotEmpty) {
      await _write(
        'pharmacy.ai.profile.${old.definition.id}',
        jsonEncode(old.toJson()),
      );
    }
    await _write(
      'pharmacy.ai.profile.${config.definition.id}',
      jsonEncode(config.toJson()),
    );
    // Scanner and local-route policy retain their existing active-envelope key.
    await _write(configurationKey, jsonEncode(config.toJson()));
  }

  Future<void> save(AiConfiguration config, {AiConnectionRead? read}) =>
      _serialized(() => _persist(config, read: read ?? _read));

  Future<void> setLocalBrainEnabled(
    bool enabled, {
    AiConnectionRead? read,
  }) => _serialized(() async {
    final connectionRead = read ?? _read;
    final active = await _active(connectionRead);
    await _persist(
      active.copyWith(localBrainEnabled: enabled),
      read: connectionRead,
    );
  });

  Future<void> forgetActiveKey({AiConnectionRead? read}) =>
      _serialized(() async {
        final connectionRead = read ?? _read;
        final active = await _active(connectionRead);
        await _persist(active.copyWith(key: ''), read: connectionRead);
      });
}
