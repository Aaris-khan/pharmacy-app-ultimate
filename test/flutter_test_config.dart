import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Give widget/unit tests the package's in-memory secure-storage backend.
///
/// Without this global test bootstrap, AiScreen startup reads fall through to
/// the host platform implementation. Those unresolved reads keep AiService's
/// defensive storage deadlines alive after a widget is disposed, which makes
/// otherwise-correct widget tests fail with pending Timer assertions.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FlutterSecureStorage.setMockInitialValues(const <String, String>{});
  await testMain();
}
