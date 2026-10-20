import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/components.dart';
import 'package:huarunwin/ui/downloads_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RefreshableDownloads extends DownloadManager {
  RefreshableDownloads() : super(Directory.systemTemp);
  int refreshCalls = 0;
  Completer<void>? pending;

  @override
  bool get refreshing => pending != null;

  @override
  Future<void> refresh() {
    if (pending != null) return pending!.future;
    refreshCalls++;
    final request = pending = Completer<void>();
    notifyListeners();
    return request.future;
  }

  void finish({Object? error}) {
    final request = pending!;
    pending = null;
    notifyListeners();
    if (error == null) {
      request.complete();
    } else {
      request.completeError(error);
    }
  }

  @override
  void dispose() {
    client.close(force: true);
    macResolver.client.close(force: true);
    super.dispose();
  }
}

DownloadTask installedTask({bool packageAvailable = true}) => DownloadTask(
  id: 'fixture',
  appName: 'Fixture App',
  url: '',
  filePath: '/fixture/package.zip',
  installedPath: '/Applications/Fixture.app',
  kind: 'zip',
  platform: 'macOS',
  state: DownloadState.installed,
  packageAvailable: packageAvailable,
  createdAt: DateTime(2026, 10, 17),
);

void main() {
  late RefreshableDownloads downloads;

  setUp(() {
    downloads = RefreshableDownloads();
  });
  tearDown(() => downloads.dispose());

  for (final size in [const Size(390, 844), const Size(1240, 900)]) {
    testWidgets(
      'entry and adaptive refresh keep content at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        downloads.tasks.add(installedTask());
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(body: DownloadsPage(manager: downloads)),
          ),
        );
        await tester.pump();
        expect(downloads.refreshCalls, 1);
        if (size.width < 600) {
          expect(find.byTooltip('刷新下载状态'), findsNothing);
          expect(find.text('Fixture App'), findsOneWidget);
          downloads.finish();
          await tester.pumpAndSettle();
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, 400),
          );
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(downloads.refreshCalls, 2);
          expect(find.text('Fixture App'), findsOneWidget);
          downloads.finish(
            error: const FileSystemException('fixture I/O error'),
          );
          await tester.pumpAndSettle();
          expect(find.text('部分文件状态未能刷新，已保留原有记录，请稍后重试。'), findsOneWidget);
          expect(find.text('Fixture App'), findsOneWidget);
          expect(tester.takeException(), isNull);
          return;
        }
        final refresh = find.byType(RefreshIconButton);
        final button = find.descendant(
          of: refresh,
          matching: find.byType(IconButton),
        );
        expect(tester.widget<IconButton>(button).onPressed, isNull);
        expect(
          find.descendant(
            of: refresh,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.text('Fixture App'), findsOneWidget);
        await tester.tap(button);
        await tester.pump();
        expect(downloads.refreshCalls, 1);

        downloads.finish();
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
        await tester.tap(find.byTooltip('刷新下载状态'));
        await tester.pump();
        expect(downloads.refreshCalls, 2);
        expect(find.text('Fixture App'), findsOneWidget);
        downloads.finish(error: const FileSystemException('fixture I/O error'));
        await tester.pumpAndSettle();
        expect(find.text('部分文件状态未能刷新，已保留原有记录，请稍后重试。'), findsOneWidget);
        expect(find.text('Fixture App'), findsOneWidget);
        expect(tester.widget<IconButton>(button).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }

  testWidgets(
    'missing package hides file action while installed app can open',
    (tester) async {
      downloads.tasks.add(installedTask(packageAvailable: false));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: downloads)),
        ),
      );
      downloads.finish();
      await tester.pumpAndSettle();
      expect(find.text('已安装'), findsOneWidget);
      expect(find.text('打开应用'), findsOneWidget);
      expect(find.text('查看文件'), findsNothing);
      expect(find.text('安装包已被移动或删除，已安装的应用仍可打开。'), findsOneWidget);
    },
  );

  testWidgets('switching away and back triggers another automatic refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final repository = CatalogRepository(Directory.systemTemp);
    final controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    )..snapshot = CatalogSnapshot(const [], DateTime.now());
    addTearDown(() {
      controller.dispose();
      repository.client.close(force: true);
    });
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
    expect(downloads.refreshCalls, 0);
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pump();
    expect(downloads.refreshCalls, 1);
    downloads.finish();
    await tester.pumpAndSettle();
    await tester.tap(find.text('偏好设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-library')));
    await tester.pump();
    expect(downloads.refreshCalls, 2);
    downloads.finish();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'leaving during refresh does not display errors on another page',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: downloads)),
        ),
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('其他页面'))),
      );
      downloads.finish(error: const FileSystemException('fixture I/O error'));
      await tester.pumpAndSettle();
      expect(find.text('其他页面'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
