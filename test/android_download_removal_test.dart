import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';

class RemovalDownloads extends DownloadManager {
  RemovalDownloads(super.directory);

  Future<void>? removal;

  @override
  Future<void> refresh() async {}

  @override
  Future<AndroidApkDetails> readApkDetails(
    DownloadTask task,
    DownloadPackage package,
  ) async => AndroidApkDetails(
    info: AndroidPackageInfo.fromMap({
      'packageName': 'win.huarun.fixture',
      'version': '1.2',
      'certificateSha256': [
        (package == DownloadPackage.original ? 'a' : 'b') * 64,
      ],
    }),
    bytes: package == DownloadPackage.original ? 1024 : 2048,
  );

  @override
  Future<void> remove(DownloadTask task, {Set<DownloadPackage>? packages}) =>
      removal = TestWidgetsFlutterBinding.ensureInitialized().runAsync<void>(
        () => super.remove(task, packages: packages),
      );
}

void main() {
  late Directory directory;
  late RemovalDownloads manager;
  late DownloadTask task;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-removal');
    manager = RemovalDownloads(directory);
    task = DownloadTask(
      id: 'fixture',
      appName: 'Fixture',
      url: 'https://example.com/fixture.apk',
      filePath: '${directory.path}/fixture/fixture.apk',
      platform: 'Android',
      kind: 'apk',
      createdAt: DateTime(2026, 10, 18),
      state: DownloadState.downloaded,
      resignedSha256: 'a' * 64,
      resignKey: const AndroidSigningKey(
        id: 'key',
        label: '个人密钥',
        certificateSha256: 'cert',
      ),
    );
    manager.tasks.add(task);
    await File(task.filePath).parent.create(recursive: true);
    await File(task.filePath).writeAsBytes([1, 2, 3]);
    await File(task.resignedFilePath).writeAsBytes([4, 5, 6]);
  });

  tearDown(() async {
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> showDownloads(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadsPage(manager: manager)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openRemoval(WidgetTester tester, DownloadPackage package) async {
    final button = find.descendant(
      of: find.byKey(ValueKey('${task.id}:${package.name}')),
      matching: find.widgetWithText(OutlinedButton, '删除'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> confirmRemoval(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await manager.removal;
    await tester.pumpAndSettle();
  }

  testWidgets(
    'APK entries show their own metadata and expandable certificates',
    (tester) async {
      await showDownloads(tester);
      expect(find.text('原始包'), findsOneWidget);
      expect(find.text('重签包'), findsOneWidget);
      expect(find.text('fixture.apk'), findsOneWidget);
      expect(find.text('fixture-huarun-sign.apk'), findsOneWidget);
      expect(find.text('包名：win.huarun.fixture'), findsNWidgets(2));
      expect(find.textContaining('1 KB'), findsOneWidget);
      expect(find.textContaining('2 KB'), findsOneWidget);
      expect(find.text('aaaaaaaaaaaa…aaaaaaaaaaaa'), findsOneWidget);
      expect(find.text('bbbbbbbbbbbb…bbbbbbbbbbbb'), findsOneWidget);
      final signed = find.byKey(ValueKey('${task.id}:resigned'));
      final signature = find.descendant(
        of: signed,
        matching: find.byType(ExpansionTile),
      );
      await tester.ensureVisible(signature);
      await tester.tap(signature);
      await tester.pumpAndSettle();
      expect(find.text('b' * 64), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final package in DownloadPackage.values) {
    testWidgets('deleting ${package.name} preserves the other entry and file', (
      tester,
    ) async {
      final other = package == DownloadPackage.original
          ? DownloadPackage.resigned
          : DownloadPackage.original;
      await showDownloads(tester);
      await openRemoval(tester, package);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.widgetWithText(FilledButton, '取消'), findsOneWidget);
      await confirmRemoval(tester);
      expect(manager.tasks, [task]);
      expect(
        await tester.runAsync(() => File(task.packagePath(package)).exists()),
        isFalse,
      );
      expect(
        await tester.runAsync(() => File(task.packagePath(other)).exists()),
        isTrue,
      );
      expect(find.byKey(ValueKey('${task.id}:${package.name}')), findsNothing);
      expect(find.byKey(ValueKey('${task.id}:${other.name}')), findsOneWidget);
      final restored = DownloadTask.fromJson(task.toJson());
      expect(restored.androidPackages, [other]);
      expect(restored.canInstallPackageOn('Android', other), isTrue);
      await openRemoval(tester, other);
      await confirmRemoval(tester);
      expect(manager.tasks, isEmpty);
      expect(
        await tester.runAsync(() => File(task.filePath).parent.exists()),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('canceling deletion preserves both entries and files', (
    tester,
  ) async {
    await showDownloads(tester);
    await openRemoval(tester, DownloadPackage.resigned);
    await tester.tap(find.widgetWithText(FilledButton, '取消'));
    await tester.pumpAndSettle();
    expect(manager.removal, isNull);
    expect(manager.tasks, [task]);
    expect(task.androidPackages, DownloadPackage.values);
    expect(await tester.runAsync(() => File(task.filePath).exists()), isTrue);
    expect(
      await tester.runAsync(() => File(task.resignedFilePath).exists()),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
