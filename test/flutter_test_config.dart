import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Install the in-memory secure-storage backend immediately after the Flutter
  // test binding exists, before any suite registers or mounts AiScreen. Keep
  // reinstalling it before each individual test as isolation between tests.
  TestWidgetsFlutterBinding.ensureInitialized();
  void resetSecureStorage() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  }

  resetSecureStorage();
  setUp(resetSecureStorage);
  await testMain();
}
