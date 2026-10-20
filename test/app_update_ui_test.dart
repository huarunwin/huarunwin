import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/app_changelog.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/app_update_dialog.dart';
import 'package:huarunwin/ui/app_update_installation.dart';
import 'package:huarunwin/ui/theme.dart';

class UpdateDevice extends NativeInstaller {
  @override
  Future<String?> architecture() async => 'arm64';
}

class UpdateDownloads extends DownloadManager {
  UpdateDownloads()
    : super(
        Directory.systemTemp,
        installer: UpdateDevice(),
        writeHistory: (_) async {},
      );

  final requests = <({DownloadLink link, String channel})>[];
  @override
  Future<DownloadTask> downloadSelfUpdate(
    DownloadLink link,
    String channel,
  ) async {
    requests.add((link: link, channel: channel));
    final task = DownloadTask(
      id: 'update-${requests.length}',
      appName: '华润赢更新',
      url: link.url,
      filePath: '/update/fixture.zip',
      kind: link.kind!,
      platform: link.platform,
      createdAt: DateTime.now(),
      state: DownloadState.downloading,
      selfUpdateChannel: channel,
      version: link.version,
      total: 100,
    );
    tasks.add(task);
    return task;
  }

  @override
  void cancel(DownloadTask task) {
    task.state = DownloadState.cancelled;
    notifyListeners();
  }

  @override
  Future<void> retry(DownloadTask task) async {
    task.state = DownloadState.downloading;
    task.error = null;
    notifyListeners();
  }

  void complete() {
    tasks.single.state = DownloadState.downloaded;
    tasks.single.received = 100;
    notifyListeners();
  }

  @override
  void dispose() {
    client.close(force: true);
    macResolver.client.close(force: true);
    super.dispose();
  }
}

AppRelease release({int packages = 1}) => AppRelease(
  version: '0.2.0-rc.1',
  changes: const ['更新说明'],
  downloadUrl: Uri.parse('https://example.com/releases/0.2.0-rc.1'),
  packages: [
    for (var i = 0; i < packages; i++)
      DownloadLink(
        url: 'https://example.com/update-$i.zip',
        label: '安装包 $i',
        platform: 'macOS',
        kind: 'zip',
        architecture: 'arm64',
      ),
  ],
);

void main() {
  for (final size in [const Size(320, 640), const Size(1240, 900)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'update dialog actions and large text fit $size $brightness',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 1.8;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          AppUpdateAction? result;
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness, width: size.width),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showAppUpdateDialog(
                        context: context,
                        release: release(),
                        channel: AppUpdateChannel.debug,
                      );
                    },
                    child: const Text('检查更新'),
                  ),
                ),
              ),
            ),
          );
          for (final action in AppUpdateAction.values) {
            await tester.tap(find.text('检查更新'));
            await tester.pumpAndSettle();
            expect(find.text('发现测试版本'), findsOneWidget);
            expect(find.text('取消'), findsOneWidget);
            expect(find.text('本版本不再提示'), findsOneWidget);
            expect(find.text('前往下载'), findsOneWidget);
            expect(tester.takeException(), isNull);
            final label = switch (action) {
              AppUpdateAction.cancel => '取消',
              AppUpdateAction.ignore => '本版本不再提示',
              AppUpdateAction.download => '前往下载',
            };
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
            expect(result, action);
          }
          await tester.tap(find.text('检查更新'));
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(result, isNull);
          expect(find.text('发现测试版本'), findsNothing);
        },
      );
    }
  }

  late UpdateDownloads manager;
  setUp(() => manager = UpdateDownloads());
  tearDown(() => manager.dispose());

  Future<void> start(WidgetTester tester, {int packages = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AppUpdateDownloadPage(
                    release: release(packages: packages),
                    channel: AppUpdateChannel.debug,
                    manager: manager,
                  ),
                ),
              ),
              child: const Text('更新入口'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('更新入口'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'recommended package downloads, cancellation and retry stay in app',
    (tester) async {
      await start(tester);
      expect(manager.requests.single.channel, 'debug');
      expect(manager.requests.single.link.version, '0.2.0-rc.1');
      expect(find.text('正在下载安装包…'), findsOneWidget);
      await tester.tap(find.text('取消下载'));
      await tester.pumpAndSettle();
      expect(find.text('下载已取消'), findsOneWidget);
      await tester.tap(find.text('重新下载'));
      await tester.pump();
      expect(manager.tasks.single.state, DownloadState.downloading);
      expect(manager.requests, hasLength(1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'ambiguous resources wait for explicit selection and confirmation',
    (tester) async {
      await start(tester, packages: 2);
      expect(manager.requests, isEmpty);
      await tester.tap(find.text('安装包 1'));
      await tester.pump();
      expect(manager.requests, isEmpty);
      await tester.tap(find.text('确认下载'));
      await tester.pump();
      expect(manager.requests.single.link.url, endsWith('update-1.zip'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'completed download asks to exit once and cancellation keeps package',
    (tester) async {
      await start(tester);
      manager.complete();
      await tester.pumpAndSettle();
      expect(find.text('退出并安装'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      manager.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('退出并安装'), findsNothing);
      expect(manager.tasks.single.state, DownloadState.downloaded);
      expect(find.text('安装更新'), findsOneWidget);
      await tester.tap(find.text('安装更新'));
      await tester.pumpAndSettle();
      expect(find.text('退出并安装'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('background completion never opens an installation dialog', (
    tester,
  ) async {
    await start(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    manager.complete();
    await tester.pumpAndSettle();
    expect(find.text('更新入口'), findsOneWidget);
    expect(find.text('退出并安装'), findsNothing);
    expect(manager.tasks.single.state, DownloadState.downloaded);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
