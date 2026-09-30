import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'canonical_medicine_catalog_service.dart';

const aarisCatalogManifestAsset = 'aaris-medicine-catalog.manifest.json';

class CatalogReleaseSyncResult {
  const CatalogReleaseSyncResult({
    required this.checked,
    required this.changed,
    required this.revision,
    this.applied = 0,
    this.tag = '',
  });

  final bool checked;
  final bool changed;
  final int revision;
  final int applied;
  final String tag;
}

class CatalogReleaseSyncService {
  CatalogReleaseSyncService._();

  static final CatalogReleaseSyncService instance =
      CatalogReleaseSyncService._();

  static const _repo = 'Aaris-khan/pharmacy-app-ultimate';
  static const _maxManifestBytes = 256 * 1024;
  static const _maxShardBytes = 10 * 1024 * 1024;
  static const _successInterval = Duration(hours: 6);
  static const _failureBackoff = Duration(minutes: 10);

  final http.Client _client = http.Client();
  Future<CatalogReleaseSyncResult>? _inflight;
  DateTime? _lastAttempt;
  DateTime? _lastSuccess;

  Future<CatalogReleaseSyncResult> syncIfNeeded() {
    final active = _inflight;
    if (active != null) return active;

    final now = DateTime.now().toUtc();
    if (_lastSuccess != null &&
        now.difference(_lastSuccess!) < _successInterval) {
      return _unchanged(checked: false);
    }
    if (_lastAttempt != null &&
        now.difference(_lastAttempt!) < _failureBackoff) {
      return _unchanged(checked: false);
    }

    _lastAttempt = now;
    final work = _sync().then((result) {
      _lastSuccess = DateTime.now().toUtc();
      return result;
    });
    _inflight = work.whenComplete(() => _inflight = null);
    return _inflight!;
  }

  Future<CatalogReleaseSyncResult> _unchanged({
    required bool checked,
  }) async {
    final revision =
        await CanonicalMedicineCatalogService.instance.lastAppliedRevision;
    return CatalogReleaseSyncResult(
      checked: checked,
      changed: false,
      revision: revision,
    );
  }

  Future<CatalogReleaseSyncResult> _sync() async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$_repo/releases',
      const {'per_page': '20'},
    );
    final response = await _client.get(
      uri,
      headers: const {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Aaris-Pharmacy-Catalog/1',
      },
    ).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('Catalogue metadata returned HTTP ${response.statusCode}.');
    }
    if (response.bodyBytes.length > 1024 * 1024) {
      throw const FormatException('Catalogue release metadata is too large.');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final release = _selectRelease(decoded);
    if (release == null) return _unchanged(checked: true);

    final manifestAsset = release.assets[aarisCatalogManifestAsset];
    if (manifestAsset == null ||
        manifestAsset.bytes <= 0 ||
        manifestAsset.bytes > _maxManifestBytes) {
      throw const FormatException('Catalogue manifest asset is invalid.');
    }
    final manifestBytes = await _download(
      manifestAsset,
      maxBytes: _maxManifestBytes,
    );
    final manifest = _CatalogManifest.parse(
      utf8.decode(manifestBytes, allowMalformed: false),
    );

    final catalog = CanonicalMedicineCatalogService.instance;
    var revision = await catalog.lastAppliedRevision;
    if (manifest.lastRevision <= revision) {
      if (manifest.snapshot) {
        await catalog.deprecateSourceBeforeRevision(
          source: manifest.productSource,
          revision: manifest.firstRevision,
        );
      }
      return CatalogReleaseSyncResult(
        checked: true,
        changed: false,
        revision: revision,
        tag: release.tag,
      );
    }

    var applied = 0;
    for (final shard in manifest.shards) {
      if (shard.lastRevision <= revision) continue;
      final asset = release.assets[shard.name];
      if (asset == null || asset.bytes != shard.bytes) {
        throw FormatException('Catalogue shard is missing: ${shard.name}');
      }
      final bytes = await _download(asset, maxBytes: _maxShardBytes);
      final result = await catalog.applyVerifiedDelta(
        bytes,
        expectedSha256: shard.sha256,
      );
      applied += result.applied;
      revision = result.lastAppliedRevision;
    }

    if (manifest.snapshot && revision >= manifest.lastRevision) {
      await catalog.deprecateSourceBeforeRevision(
        source: manifest.productSource,
        revision: manifest.firstRevision,
      );
    }

    return CatalogReleaseSyncResult(
      checked: true,
      changed: applied > 0,
      revision: revision,
      applied: applied,
      tag: release.tag,
    );
  }

  Future<Uint8List> _download(
    _ReleaseAsset asset, {
    required int maxBytes,
  }) async {
    if (asset.bytes <= 0 || asset.bytes > maxBytes) {
      throw const FormatException('Catalogue asset exceeds the safety limit.');
    }
    final request = http.Request('GET', asset.url)
      ..headers['User-Agent'] = 'Aaris-Pharmacy-Catalog/1';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw StateError('Catalogue asset returned HTTP ${response.statusCode}.');
    }
    final declared = response.contentLength;
    if (declared != null &&
        (declared != asset.bytes || declared > maxBytes)) {
      await response.stream.drain<void>();
      throw const FormatException('Catalogue asset size mismatch.');
    }

    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 12),
    )) {
      received += chunk.length;
      if (received > maxBytes || received > asset.bytes) {
        throw const FormatException('Catalogue asset exceeds its declared size.');
      }
      builder.add(chunk);
    }
    if (received != asset.bytes) {
      throw const FormatException('Catalogue asset size mismatch.');
    }
    return builder.takeBytes();
  }
}

class _ReleaseSelection {
  const _ReleaseSelection(this.tag, this.assets);

  final String tag;
  final Map<String, _ReleaseAsset> assets;
}

class _ReleaseAsset {
  const _ReleaseAsset(this.name, this.url, this.bytes);

  final String name;
  final Uri url;
  final int bytes;

  factory _ReleaseAsset.parse(Map<String, dynamic> map) {
    final name = '${map['name'] ?? ''}'.trim();
    final url = Uri.tryParse('${map['browser_download_url'] ?? ''}');
    final bytes = map['size'];
    if (name.isEmpty ||
        url == null ||
        url.scheme != 'https' ||
        url.host.toLowerCase() != 'github.com' ||
        bytes is! int ||
        bytes < 0) {
      throw const FormatException('Invalid catalogue Release asset.');
    }
    return _ReleaseAsset(name, url, bytes);
  }
}

_ReleaseSelection? _selectRelease(Object? decoded) {
  if (decoded is! List) return null;
  for (final raw in decoded) {
    if (raw is! Map) continue;
    final release = Map<String, dynamic>.from(raw);
    final tag = '${release['tag_name'] ?? ''}'.trim();
    if (!tag.startsWith('catalog-') ||
        release['draft'] == true ||
        release['prerelease'] == true) {
      continue;
    }
    final values = release['assets'];
    if (values is! List) continue;
    final assets = <String, _ReleaseAsset>{};
    try {
      for (final value in values.whereType<Map>()) {
        final asset = _ReleaseAsset.parse(Map<String, dynamic>.from(value));
        assets[asset.name] = asset;
      }
    } on FormatException {
      continue;
    }
    if (assets.containsKey(aarisCatalogManifestAsset)) {
      return _ReleaseSelection(tag, assets);
    }
  }
  return null;
}

class _CatalogShard {
  const _CatalogShard({
    required this.name,
    required this.sha256,
    required this.bytes,
    required this.firstRevision,
    required this.lastRevision,
  });

  final String name;
  final String sha256;
  final int bytes;
  final int firstRevision;
  final int lastRevision;

  factory _CatalogShard.parse(Map<String, dynamic> map) {
    final name = '${map['name'] ?? ''}'.trim();
    final sha = '${map['sha256'] ?? ''}'.trim().toLowerCase();
    final bytes = map['bytes'];
    final records = map['records'];
    final first = map['first_revision'];
    final last = map['last_revision'];
    if (!RegExp(r'^aaris-medicine-catalog-\d{4}\.jsonl$').hasMatch(name) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
        bytes is! int ||
        bytes <= 0 ||
        bytes > CatalogReleaseSyncService._maxShardBytes ||
        records is! int ||
        records <= 0 ||
        records > 50000 ||
        first is! int ||
        last is! int ||
        first <= 0 ||
        last < first) {
      throw const FormatException('Invalid catalogue shard manifest.');
    }
    return _CatalogShard(
      name: name,
      sha256: sha,
      bytes: bytes,
      firstRevision: first,
      lastRevision: last,
    );
  }
}

class _CatalogManifest {
  const _CatalogManifest({
    required this.shards,
    required this.snapshot,
    required this.productSource,
  });

  final List<_CatalogShard> shards;
  final bool snapshot;
  final String productSource;

  int get firstRevision => shards.first.firstRevision;
  int get lastRevision => shards.last.lastRevision;

  factory _CatalogManifest.parse(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('Catalogue manifest must be JSON.');
    }
    final map = Map<String, dynamic>.from(decoded);
    final source = map['source'];
    final rawShards = map['shards'];
    final sourceMap = source is Map
        ? Map<String, dynamic>.from(source)
        : const <String, dynamic>{};
    final snapshot = map['mode'] == 'snapshot';
    final productSource = '${sourceMap['product_source'] ?? ''}'.trim();
    if (map['schema'] != 1 ||
        map['kind'] != 'aaris-medicine-catalog' ||
        source is! Map ||
        sourceMap['redistributable'] != true ||
        !snapshot ||
        !productSource.startsWith('public:') ||
        productSource.length > 80 ||
        rawShards is! List ||
        rawShards.isEmpty ||
        rawShards.length > 64) {
      throw const FormatException('Unsupported catalogue manifest.');
    }
    final shards = rawShards
        .whereType<Map>()
        .map((raw) => _CatalogShard.parse(Map<String, dynamic>.from(raw)))
        .toList(growable: false);
    if (shards.length != rawShards.length) {
      throw const FormatException('Invalid catalogue shard list.');
    }
    var previous = 0;
    final names = <String>{};
    for (final shard in shards) {
      if (!names.add(shard.name) || shard.firstRevision <= previous) {
        throw const FormatException(
          'Catalogue shard revisions must be strictly ordered.',
        );
      }
      previous = shard.lastRevision;
    }
    return _CatalogManifest(
      shards: List<_CatalogShard>.unmodifiable(shards),
      snapshot: snapshot,
      productSource: productSource,
    );
  }
}
