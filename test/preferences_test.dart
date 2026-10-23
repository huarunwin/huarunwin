import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';
import 'package:huarunwin/ui/settings.dart';
import 'package:huarunwin/ui/about_page.dart';
import 'package:huarunwin/ui/licenses_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InstallationDownloads extends DownloadManager {
  InstallationDownloads(super.directory);

  @override
  Future<void> refresh() async {}
}

void main() {
  testWidgets('appearance persists and quarantine has no user setting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'removeQuarantine': false});
    final prefs = await SharedPreferences.getInstance();
    final dir = Directory.systemTemp.createTempSync('huarun-preferences');
    final repo = CatalogRepository(dir);
    final controller = AppController(repo, prefs);
    final downloads = DownloadManager(dir);
    addTearDown(() {
      controller.dispose();
      downloads.dispose();
      downloads.client.close(force: true);
      downloads.macResolver.client.close(force: true);
      repo.client.close(force: true);
      dir.deleteSync(recursive: true);
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MaterialApp(
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          themeMode: controller.themeMode,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: SettingsPage(controller: controller, downloads: downloads),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final (label, mode) in [
      ('深色', ThemeMode.dark),
      ('浅色', ThemeMode.light),
      ('跟随系统', ThemeMode.system),
    ]) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(controller.themeMode, mode);
      expect(prefs.getString('theme'), mode.name);
      expect(tester.takeException(), isNull);
    }
    expect(find.text('处理下载隔离标记'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    await tester.scrollUntilVisible(find.text('关于华润赢'), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于华润赢'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    await tester.scrollUntilVisible(find.text('软件许可'), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.text('软件许可'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'installation clears quarantine after confirmation and authorization',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'huarun-install-flow',
      );
      final manager = InstallationDownloads(directory);
      final task = DownloadTask(
        id: 'install-test',
        appName: 'Test App',
        url: '',
        filePath: '${directory.path}/fixture.zip',
        kind: 'zip',
        platform: 'macOS',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      File(task.filePath).writeAsStringSync('fixture package');
      manager.tasks.add(task);
      final calls = <MethodCall>[];
      var requireAuthorization = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeInstaller.channel,
        (call) async {
          calls.add(call);
          if (requireAuthorization && call.arguments['authorize'] != true) {
            throw PlatformException(code: 'permission_required');
          }
          return '/Applications/Test App.app';
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          NativeInstaller.channel,
          null,
        );
        manager.dispose();
        manager.client.close(force: true);
        manager.macResolver.client.close(force: true);
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );

      await tester.tap(find.text('安装应用'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.text('处理下载隔离标记'), findsNothing);
      expect(find.textContaining('已安装的同一应用会被替换'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);

      Future<void> startInstall() async {
        await tester.tap(find.text('安装应用'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('开始安装'));
        await tester.pumpAndSettle();
      }

      await startInstall();
      expect(task.state, DownloadState.installed);
      expect(calls.single.arguments, {
        'package': task.filePath,
        'removeQuarantine': true,
        'authorize': false,
      });

      task.state = DownloadState.downloaded;
      requireAuthorization = true;
      calls.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await startInstall();
      expect(find.text('需要管理员授权'), findsOneWidget);
      await tester.tap(find.text('暂不安装'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(task.state, DownloadState.downloaded);

      calls.clear();
      await startInstall();
      await tester.tap(find.text('继续授权'));
      await tester.pumpAndSettle();
      expect(task.state, DownloadState.installed);
      expect(calls.length, 2);
      expect(
        calls.every((call) => call.arguments['removeQuarantine'] == true),
        isTrue,
      );
      expect(calls.last.arguments['authorize'], isTrue);
      expect(tester.takeException(), isNull);
    },
    skip: !Platform.isMacOS,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
