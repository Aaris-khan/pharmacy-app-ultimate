import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('search and import serialize interactive route entry', () {
    final search = File('lib/ui/search_screen.dart').readAsStringSync();
    final importCenter = File('lib/ui/import_screen.dart').readAsStringSync();

    expect(search, contains('_routeOpening = false'));
    expect(
      search,
      contains(
        'Future<void> _runExclusiveRoute(Future<void> Function() action) async',
      ),
    );
    expect(search, contains('if (_routeOpening || !mounted) return;'));
    expect(search, isNot(contains('_voiceOpening')));
    expect(search, contains('onPressed: _routeOpening ? null : _scanner'));
    expect(search, contains('onPressed: _routeOpening ? null : _mic'));
    expect(search, contains('onPressed: _routeOpening ? null : _bulk'));
    expect(
      '_runExclusiveRoute('.allMatches(search).length,
      greaterThanOrEqualTo(10),
    );
    expect(
      search,
      isNot(contains('onPressed: () => openEditor(\n')),
    );
    expect(
      search,
      isNot(contains('onPressed: () => Navigator.push(\n')),
    );

    expect(importCenter, contains('bool _flowOpening = false;'));
    expect(
      importCenter,
      contains('bool get _actionsLocked => _busy || _flowOpening;'),
    );
    expect(
      importCenter,
      contains('Future<void> _runFlow(Future<void> Function() action) async'),
    );
    expect(importCenter, contains('if (_actionsLocked || !mounted) return;'));
    expect(
      importCenter,
      contains('Future<void> _scan() => _runFlow(() async {'),
    );
    expect(
      importCenter,
      contains('Future<void> _pasteList() => _runFlow(() async {'),
    );
    expect(importCenter, isNot(contains('onTap: _busy ? null')));
  });
}
