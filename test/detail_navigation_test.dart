import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/detail.dart';
import 'package:shared_preferences/shared_preferences.dart';

const app = CatalogApp(
  id: 'keyboard-example',
  name: 'Keyboard Example',
  url: 'https://huarun.win/apps/keyboard-example',
  platforms: ['Windows', 'macOS'],
);

class DetailRepository extends CatalogRepository {
  DetailRepository(super.directory);

  @override
  Future<DetailSnapshot> detail(
    CatalogApp summary, {
    bool refresh = false,
  }) async => DetailSnapshot(
    const AppDetails(app: app, description: 'Keyboard navigation details'),
    DateTime.now(),
  );
}

void main() {
  late Directory directory;
  late DetailRepository repository;
  late AppController controller;
  late DownloadManager downloads;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-detail-keys');
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    repository = DetailRepository(directory);
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot([app], DateTime.now());
    downloads = DownloadManager(directory);
  });

  tearDown(() async {
    controller.dispose();
    repository.client.close(force: true);
    downloads.client.close(force: true);
    downloads.macResolver.client.close(force: true);
    downloads.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
  }

  for (final commandBack in [false, true]) {
    testWidgets(
      '${commandBack ? 'Command+[' : 'Escape'} returns from details and leaves the catalog open',
      (tester) async {
        await mount(tester);
        await tester.tap(find.text(app.name));
        await tester.pumpAndSettle();
        expect(find.byType(DetailPage), findsOneWidget);
        await tester.tap(find.text('Keyboard navigation details'));
        await tester.pumpAndSettle();

        for (var press = 0; press < 2; press++) {
          if (commandBack) {
            await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
          }
          await tester.sendKeyEvent(
            commandBack
                ? LogicalKeyboardKey.bracketLeft
                : LogicalKeyboardKey.escape,
          );
          if (commandBack) {
            await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
          }
          await tester.pumpAndSettle();
          expect(find.byType(DetailPage), findsNothing);
          expect(find.text(app.name), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'Escape closes the download dialog before returning from details',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('platform-option-Windows')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(app.name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择下载平台'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(downloads.tasks, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(find.byTooltip('平台与设备：Windows'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
