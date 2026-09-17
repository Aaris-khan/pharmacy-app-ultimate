import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Create the binding once, then reinstall the in-memory secure-storage
  // backend before every individual test. Individual suites may call
  // ensureInitialized() while registering tests, so a one-time mock installed
  // before testMain can be replaced before AiScreen is actually mounted.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });
  await testMain();
}
