import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/android_resigning_options.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call.method);
          return [
            {'id': 'new-key', 'label': 'New', 'certificateSha256': 'new'},
          ];
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
  });

  test('renaming stays a draft, rejects equal/invalid names and resets on resource changes', () async {
    final controller = AndroidResigningController(
      NativeInstaller(),
      originalPackageName: 'test.app',
    );
    addTearDown(controller.dispose);
    expect(controller.targetPackageName, isNull);
    await controller.setEnabled(true);
    controller.setChangePackageName(true);
    expect(controller.targetPackageName, 'test.app.huarun');
    expect(controller.canConfirm, isTrue);
    controller.packageName.text = 'test.app';
    expect(controller.canConfirm, isFalse);
    controller.packageName.text = 'test.1bad';
    expect(controller.canConfirm, isFalse);
    controller.packageName.text = 'test.app.personal';
    expect(controller.canConfirm, isTrue);
    controller.reset();
    expect(controller.targetPackageName, isNull);
    expect(controller.changePackageName, isFalse);
    expect(calls, ['apkSigningKeys']);
  });

  test(
    'missing historical identity cannot silently switch to an available key',
    () async {
      final controller = AndroidResigningController(
        NativeInstaller(),
        suggestedPackageName: 'test.app.personal',
        suggestedKey: const AndroidSigningKey(
          id: 'old-key',
          label: 'Old',
          certificateSha256: 'old',
        ),
      );
      addTearDown(controller.dispose);
      await controller.setEnabled(true);
      controller.setChangePackageName(true);
      expect(controller.targetPackageName, 'test.app.personal');
      expect(controller.key!.id, 'old-key');
      expect(controller.key!.available, isFalse);
      expect(controller.canConfirm, isFalse);
      expect(calls, ['apkSigningKeys']);
    },
  );
}
