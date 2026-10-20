import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/adaptive_dialog.dart';
import 'package:huarunwin/ui/compact_navigation.dart';
import 'package:huarunwin/ui/page_components.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void viewport(WidgetTester tester, Size size, {double scale = 1}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'compact catalog uses a single list with large text and keyboard ($brightness)',
      (tester) async {
        viewport(tester, const Size(320, 720), scale: 2);
        final folder = Directory.systemTemp.createTempSync('huarun-narrow');
        final repository = CatalogRepository(folder);
        SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
        final controller =
            AppController(repository, await SharedPreferences.getInstance())
              ..snapshot = CatalogSnapshot([
                for (var i = 0; i < 20; i++)
                  CatalogApp(
                    id: 'client-$i',
                    name: 'FlClash 长名称应用 $i',
                    description: '跨平台客户端，支持多种内核与配置。',
                    url: 'https://huarun.win/apps/client-$i',
                    platforms: const ['Android', 'macOS', 'Windows', 'Linux'],
                    price: '免费下载 · 部分功能付费',
                    core: 'mihomo',
                    source: '开源',
                  ),
              ], DateTime.now());
        final downloads = DownloadManager(folder);
        addTearDown(() {
          controller.dispose();
          downloads.dispose();
          repository.client.close(force: true);
          folder.deleteSync(recursive: true);
        });
        controller.setTheme(
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        );
        await tester.pumpWidget(
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('网格视图'), findsNothing);
        expect(find.byTooltip('列表视图'), findsNothing);
        final bar = tester.getRect(
          find.byKey(const ValueKey('android-navigation-bar')),
        );
        expect(bar.left, greaterThanOrEqualTo(12));
        expect(bar.right, lessThanOrEqualTo(308));
        await tester.enterText(find.byType(TextField), 'FlClash');
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        expect(find.byType(CompactNavigation), findsNothing);
        expect(find.byType(TextField).hitTestable(), findsOneWidget);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(find.byType(CompactNavigation), findsOneWidget);
        await tester.drag(find.text('FlClash 长名称应用 0'), const Offset(0, -650));
        await tester.pumpAndSettle();
        expect(find.byType(TextField).hitTestable(), findsNothing);
        expect(find.byType(CompactNavigation).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.macOS,
      }),
    );
  }

  testWidgets(
    'compact forms keep cancel and confirm above the keyboard while content scrolls',
    (tester) async {
      viewport(tester, const Size(320, 640), scale: 2);
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showAdaptiveForm<bool>(
                    context: context,
                    builder: (context) => AdaptiveDialog(
                      title: '筛选应用',
                      content: Column(
                        children: [
                          for (var i = 0; i < 20; i++) Text('资源选项 $i'),
                          const TextField(
                            decoration: InputDecoration(labelText: '金额'),
                          ),
                        ],
                      ),
                      actions: DialogActionsRow(
                        confirmLabel: '确认',
                        onCancel: () => Navigator.pop(context, false),
                        onConfirm: () => Navigator.pop(context, true),
                      ),
                    ),
                  );
                },
                child: const Text('打开筛选'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开筛选'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.text('确认').hitTestable(), findsOneWidget);
      final actions = tester.getRect(find.byType(DialogActionsRow));
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '20');
      expect(tester.getRect(find.byType(DialogActionsRow)), actions);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(DialogActionsRow)).bottom,
        lessThanOrEqualTo(360),
      );
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.text('确认').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, false);
    },
  );
}
