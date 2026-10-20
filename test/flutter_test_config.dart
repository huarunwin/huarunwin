import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // Widget tests must not wait for the host's native application inventory.
    // Platform-specific tests can replace this handler with their own fixture.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInventory.channel, (call) async {
          if (call.method == 'installedApplications') return <Object?>[];
          throw MissingPluginException('No fixture for ${call.method}');
        });
  });
  await testMain();
}

abstract final class NativeInventory {
  static const channel = MethodChannel('win.huarun/installer');
}
