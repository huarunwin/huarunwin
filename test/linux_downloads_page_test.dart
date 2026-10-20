import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/ui/downloads_page.dart';

class LinuxPageInstaller extends NativeInstaller {
  final opened = <String>[];
  @override
  Future<void> openAppImage(String path) async {
    opened.add(path);
  }
}

class LinuxPageDownloads extends DownloadManager {
  LinuxPageDownloads(super.directory)
    : super(installer: LinuxPageInstaller(), writeHistory: (_) async {});
  var installs = 0;
  @override
  Future<void> refresh() async {}
  @override
  Future<void> install(
    DownloadTask task, {
    bool authorize = false,
    Map<String, String>? quitApplication,
    Map<String, String>? signerApproval,
    AndroidInstallMethod androidMethod = AndroidInstallMethod.huarun,
    DownloadPackage? package,
  }) async {
    installs++;
    task.state = DownloadState.installed;
    task.installedPath =
        '/home/fixture/Applications/HuarunWin/app-a/Application.AppImage';
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'Linux AppImage installation requires confirmation and opens only on request',
    (tester) async {
      final manager = LinuxPageDownloads(Directory.systemTemp);
      addTearDown(() {
        manager.dispose();
        manager.client.close(force: true);
        manager.macResolver.client.close(force: true);
      });
      final task = DownloadTask(
        id: 'linux',
        appName: 'Linux Fixture',
        url: '',
        filePath: '/downloads/fixture.AppImage',
        platform: 'Linux',
        kind: 'appimage',
        state: DownloadState.downloaded,
        createdAt: DateTime.now(),
      );
      manager.tasks.add(task);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('安装应用'));
      await tester.pumpAndSettle();
      expect(find.textContaining('~/Applications/HuarunWin'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(manager.installs, 0);
      await tester.tap(find.text('安装应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始安装'));
      await tester.pumpAndSettle();
      expect(manager.installs, 1);
      final installer = manager.installer as LinuxPageInstaller;
      expect(installer.opened, isEmpty);
      await tester.tap(find.text('打开应用'));
      await tester.pumpAndSettle();
      expect(installer.opened, [task.installedPath]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
