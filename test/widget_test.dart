import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/compact_navigation.dart';

void main() {
  for (final size in [const Size(1240, 900), const Size(390, 844)]) {
    testWidgets('catalog header scrolls with applications at $size', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
      final folder = Directory.systemTemp.createTempSync('huarun-scroll-test');
      addTearDown(() => folder.deleteSync(recursive: true));
      final controller = AppController(
        CatalogRepository(folder),
        await SharedPreferences.getInstance(),
      );
      controller.snapshot = CatalogSnapshot([
        for (var index = 0; index < 30; index++)
          CatalogApp(
            id: 'app-$index',
            name: 'Example $index',
            url: 'https://huarun.win/apps/example-$index',
            platforms: const ['macOS'],
          ),
      ], DateTime.now());
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: DownloadManager(folder)),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field.hitTestable(), findsOneWidget);
      final navigation = size.width >= 900
          ? find.text('偏好设置')
          : find.byType(CompactNavigation);
      final navigationTop = tester.getTopLeft(navigation).dy;

      await tester.drag(find.text('Example 0'), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsNothing);
      expect(tester.getTopLeft(navigation).dy, navigationTop);
      expect(navigation.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.dragFrom(
        Offset(size.width - 100, 400),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await tester.enterText(field, 'no-matching-application');
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop search and iOS navigation work together', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    final folder = Directory.systemTemp.createTempSync('huarun-widget-test');
    addTearDown(() => folder.deleteSync(recursive: true));
    final controller = AppController(
      CatalogRepository(folder),
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(const [
      CatalogApp(
        id: 'one',
        name: 'Mac Example',
        url: 'https://huarun.win/apps/one',
        platforms: ['macOS'],
        description: '这是一个 Mac 应用',
        price: '免费',
        source: '开源',
      ),
      CatalogApp(
        id: 'two',
        name: 'Android Example',
        url: 'https://huarun.win/apps/two',
        platforms: ['Android'],
        description: '这是一个手机应用',
      ),
    ], DateTime.now());
    tester.view.physicalSize = const Size(1240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: DownloadManager(folder)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mac Example'), findsOneWidget);
    expect(find.text('Android Example'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Mac');
    await tester.pumpAndSettle();
    expect(find.text('Mac Example'), findsOneWidget);
    expect(find.text('Android Example'), findsNothing);
    tester.view.physicalSize = const Size(700, 844);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('设置'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('应用库'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('应用库为空'), findsOneWidget);
    expect(find.byTooltip('返回'), findsNothing);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();
    expect(find.text('Mac Example'), findsOneWidget);
    expect(find.text('Android Example'), findsNothing);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('应用目录'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      2,
    );
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(controller.themeMode, ThemeMode.dark);
    await tester.scrollUntilVisible(
      find.text('关于华润赢'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.pumpAndSettle();
    expect(find.text('关于华润赢'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
