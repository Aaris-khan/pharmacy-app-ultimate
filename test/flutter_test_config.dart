import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Establish Flutter's test binding before replacing the secure-storage
  // platform implementation. Some suites call ensureInitialized() themselves;
  // doing it here first keeps the in-memory storage backend authoritative for
  // the whole test isolate and prevents AiService's bounded storage read from
  // leaving a four-second timeout timer behind at widget teardown.
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues(<String, String>{});
  await testMain();
}
