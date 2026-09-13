import 'dart:async';
import 'dart:isolate';

import '../domain/inventory.dart';
import '../domain/medicine.dart';
import '../domain/search.dart';

void _searchEntry(SendPort main) {
  final receive = ReceivePort();
  main.send(receive.sendPort);
  MedicineSearch? engine;
  MedicineSearch? archivedEngine;
  List<Medicine>? indexedRecords;
  var revision = -1;
  receive.listen((dynamic raw) {
    final message = raw as Map;
    final id = message['id'] as int;
    try {
      final kind = message['kind'] as String;
      if (kind == 'index') {
        indexedRecords = (message['records'] as List).cast<Medicine>();
        engine = MedicineSearch(indexedRecords!);
        // Removed history is intentionally indexed lazily. Normal medicine
        // search stays as small and hot as before even when years of archived
        // stock are retained for recovery/audit.
        archivedEngine = null;
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else if (kind == 'reuseIndex') {
        if (engine == null || indexedRecords == null) {
          throw StateError('Search index changed. Retry this search.');
        }
        // Stock-only facts (quantity, price, row revision) do not participate
        // in the expensive token/fuzzy projection. The main isolate already
        // proved every searchable/status field is unchanged; rebind only the
        // dataset revision so subsequent requests keep the actor protocol exact
        // without rebuilding an identical index.
        revision = message['revision'] as int;
        main.send({'id': id, 'result': true});
      } else {
        if (engine == null ||
            indexedRecords == null ||
            revision != message['revision']) {
          throw StateError('Search index changed. Retry this search.');
        }
        if (kind == 'searchArchived') {
          archivedEngine ??= MedicineSearch(
            indexedRecords!.where((medicine) => medicine.archived),
            includeArchived: true,
          );
          main.send({
            'id': id,
            'result': archivedEngine!.searchArchived(
              message['query'] as String,
              message['today'] as DateTime,
              limit: message['limit'] as int,
            ),
          });
        } else if (kind == 'search') {
          main.send({
            'id': id,
            'result': engine!.search(
              message['query'] as String,
              message['scope'] as SearchScope,
              message['settings'] as WarningSettings,
              message['today'] as DateTime,
              limit: message['limit'] as int,
            ),
          });
        } else {
          throw StateError('Unknown search operation.');
        }
      }
    } catch (e) {
      main.send({'id': id, 'error': e.toString()});
    }
  });
}

class _SearchWorkerTransportFailure implements Exception {
  const _SearchWorkerTransportFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One restartable actor session.
///
/// Search errors produced by the domain engine are ordinary request failures and
/// keep the actor alive. Isolate exit/protocol/startup failures are transport
/// failures: every borrower is settled, the actor is retired, and SearchWorker
/// may create one fresh session for the same queued operation.
class _SearchWorkerSession {
  final ReceivePort _receive = ReceivePort();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<dynamic>> _pending = {};

  Isolate? _isolate;
  SendPort? _port;
  StreamSubscription<dynamic>? _subscription;
  bool _alive = true;
  int _id = 0;

  bool get alive => _alive;

  Future<void> start() async {
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session is unavailable.',
      );
    }
    _subscription = _receive.listen(_onMessage);
    try {
      _isolate = await Isolate.spawn(
        _searchEntry,
        _receive.sendPort,
        onExit: _receive.sendPort,
        onError: _receive.sendPort,
      );
      _port = await _ready.future.timeout(const Duration(seconds: 8));
    } catch (error) {
      final failure = error is _SearchWorkerTransportFailure
          ? error
          : _SearchWorkerTransportFailure(
              'Background search could not start: $error',
            );
      _fail(failure);
      throw failure;
    }
  }

  void _onMessage(dynamic value) {
    if (!_alive) return;
    if (value is SendPort) {
      if (!_ready.isCompleted) _ready.complete(value);
      return;
    }
    if (value == null || value is List) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search stopped unexpectedly.',
        ),
      );
      return;
    }
    if (value is! Map) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an invalid transport message.',
        ),
      );
      return;
    }

    final result = Map<dynamic, dynamic>.from(value);
    final id = result['id'];
    if (id is! int) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an invalid request ID.',
        ),
      );
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null || pending.isCompleted) return;
    final error = result['error'];
    if (error is String) {
      pending.completeError(StateError(error));
      return;
    }
    if (!result.containsKey('result')) {
      _fail(
        const _SearchWorkerTransportFailure(
          'Background search returned an incomplete response.',
        ),
      );
      return;
    }
    pending.complete(result['result']);
  }

  Future<dynamic> request(Map<String, dynamic> message) async {
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session stopped.',
      );
    }
    final port = _port ?? await _ready.future;
    if (!_alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search session stopped.',
      );
    }
    final id = ++_id;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    port.send({...message, 'id': id});
    return completer.future;
  }

  void _fail(Object error) {
    if (!_alive) return;
    _alive = false;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port = null;
    _receive.close();
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }

  void close() => _fail(
    const _SearchWorkerTransportFailure('Background search closed.'),
  );
}

bool _sameSearchProjection(Medicine before, Medicine after) =>
    before.id == after.id &&
    before.name == after.name &&
    before.brand == after.brand &&
    before.manufacturer == after.manufacturer &&
    before.salt == after.salt &&
    before.strength == after.strength &&
    before.form == after.form &&
    before.mfg == after.mfg &&
    before.expiry == after.expiry &&
    before.barcode == after.barcode &&
    before.batchNumber == after.batchNumber &&
    before.block == after.block &&
    before.row == after.row &&
    before.vertical == after.vertical &&
    before.location == after.location &&
    before.notes == after.notes &&
    before.ocrText == after.ocrText &&
    before.sold == after.sold &&
    before.archived == after.archived;

class SearchWorker {
  _SearchWorkerSession? _session;
  Future<_SearchWorkerSession>? _starting;
  final Map<String, Medicine> _indexedRecordRefs = {};
  int _revision = -1;
  int _indexBuilds = 0;
  bool _closed = false;
  Future<void> _queue = Future.value();

  /// Diagnostic only. Useful for regression tests and future performance
  /// telemetry; it does not participate in search decisions.
  int get debugIndexBuilds => _indexBuilds;

  Future<_SearchWorkerSession> _worker() {
    if (_closed) {
      return Future.error(StateError('Search closed.'));
    }
    final current = _session;
    if (current != null && current.alive) return Future.value(current);
    if (current != null) _retire(current);
    final starting = _starting;
    if (starting != null) return starting;

    late final Future<_SearchWorkerSession> operation;
    operation = _startWorker().whenComplete(() {
      if (identical(_starting, operation)) _starting = null;
    });
    _starting = operation;
    return operation;
  }

  Future<_SearchWorkerSession> _startWorker() async {
    final session = _SearchWorkerSession();
    await session.start();
    if (_closed) {
      session.close();
      throw StateError('Search closed.');
    }
    _session = session;
    _revision = -1;
    _indexedRecordRefs.clear();
    return session;
  }

  void _retire(_SearchWorkerSession session) {
    session.close();
    if (!identical(_session, session)) return;
    _session = null;
    _revision = -1;
    _indexedRecordRefs.clear();
  }

  bool _canReuseIndex(List<Medicine> records) {
    if (_revision < 0 || _indexedRecordRefs.length != records.length) {
      return false;
    }
    final replacements = <Medicine>[];
    for (final record in records) {
      final indexed = _indexedRecordRefs[record.id];
      if (indexed == null) return false;
      if (identical(indexed, record)) continue;
      if (!_sameSearchProjection(indexed, record)) return false;
      replacements.add(record);
    }
    // Quantity, cost, row revision and other non-search facts may change very
    // frequently during dispensing. Update only those object witnesses while
    // retaining the expensive token/fuzzy index built from identical search
    // facts. The worker never returns Medicine objects, only stable stock IDs.
    for (final record in replacements) {
      _indexedRecordRefs[record.id] = record;
    }
    return true;
  }

  Future<_SearchWorkerSession> _ensureIndex(
    List<Medicine> records,
    int revision,
  ) async {
    final session = await _worker();
    if (_revision == revision) return session;
    if (_canReuseIndex(records)) {
      await session.request({
        'kind': 'reuseIndex',
        'revision': revision,
      });
      if (!session.alive) {
        throw const _SearchWorkerTransportFailure(
          'Background search stopped while rebinding its index.',
        );
      }
      _revision = revision;
      return session;
    }
    await session.request({
      'kind': 'index',
      'records': records,
      'revision': revision,
    });
    if (!session.alive) {
      throw const _SearchWorkerTransportFailure(
        'Background search stopped while indexing.',
      );
    }
    _revision = revision;
    _indexedRecordRefs
      ..clear()
      ..addEntries(records.map((record) => MapEntry(record.id, record)));
    _indexBuilds++;
    return session;
  }

  Future<T> _withTransportRecovery<T>(Future<T> Function() operation) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await operation();
      } on _SearchWorkerTransportFailure {
        final session = _session;
        if (session != null) _retire(session);
        if (_closed || attempt == 1) rethrow;
      }
    }
    throw StateError('Background search recovery failed.');
  }

  Future<List<SearchHit>> search(
    List<Medicine> records,
    int revision,
    String query,
    SearchScope scope,
    WarningSettings settings,
    DateTime today,
  ) {
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        final response = await session.request({
          'kind': 'search',
          'revision': revision,
          'query': query,
          'scope': scope,
          'settings': settings,
          'today': today,
          'limit': query.trim().isEmpty ? 100000 : 150,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<List<SearchHit>> searchArchived(
    List<Medicine> records,
    int revision,
    String query,
    DateTime today,
  ) {
    final result = _queue.then(
      (_) => _withTransportRecovery(() async {
        final session = await _ensureIndex(records, revision);
        final response = await session.request({
          'kind': 'searchArchived',
          'revision': revision,
          'query': query,
          'today': today,
          'limit': query.trim().isEmpty ? 100000 : 150,
        });
        return (response as List).cast<SearchHit>();
      }),
    );
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final session = _session;
    _session = null;
    session?.close();
    _revision = -1;
    _indexedRecordRefs.clear();
  }
}
