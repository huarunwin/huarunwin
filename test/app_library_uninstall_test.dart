import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/installed_apps.dart';
import 'package:huarunwin/ui/app_library_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const application = CatalogApp(
  id: 'fixture',
  name: 'Fixture App',
  url: 'https://huarun.win/apps/fixture',
  platforms: ['macOS'],
);
const installation = InstalledApplication(
  path: '/Applications/Fixture.app',
  bundleIdentifier: 'org.example.fixture',
  version: '1.0',
  names: ['Fixture App'],
);
const approvalSnapshot = {
  'path': '/Applications/Fixture.app',
  'bundleIdentifier': 'org.example.fixture',
  'version': '1.0',
  'device': '1',
  'inode': '2',
};

class UninstallInstaller extends NativeInstaller {
  final applications = [installation];
  final calls = <Map<String, String>?>[];
  bool requireAuthorization = false;
  bool removeApplication = false;
  Completer<void>? authorization;
  PlatformException? uninstallError, settingsError;
  int settingsRequests = 0;

  @override
  Future<List<InstalledApplication>> installedApplications() async =>
      List.of(applications);

  @override
  Future<void> uninstallApplication(
    InstalledApplication selected, {
    Map<String, String>? authorizationTarget,
  }) async {
    expect(selected.path, installation.path);
    expect(selected.bundleIdentifier, installation.bundleIdentifier);
    expect(selected.version, installation.version);
    calls.add(authorizationTarget);
    if (requireAuthorization && authorizationTarget == null) {
      throw PlatformException(
        code: 'permission_required',
        details: Map.of(approvalSnapshot),
      );
    }
    if (authorization != null) await authorization!.future;
    if (uninstallError case final error?) throw error;
    if (removeApplication) applications.clear();
  }

  @override
  Future<void> openApplicationSettings() async {
    settingsRequests++;
    if (settingsError case final error?) throw error;
  }
}

class UninstallDownloads extends DownloadManager {
  UninstallDownloads(NativeInstaller installer)
    : super(Directory.systemTemp, installer: installer);

  int refreshes = 0;

  @override
  Future<void> refresh() async {
    refreshes++;
  }
}

class UninstallRepository extends CatalogRepository {
  UninstallRepository() : super(Directory.systemTemp);

  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async =>
      DetailSnapshot(AppDetails(app: app, version: '1.0'), DateTime(2026));
}

class PackageFile extends Fake implements File {
  @override
  Future<bool> exists() async => true;
}

final class PackageFiles extends IOOverrides {
  @override
  File createFile(String path) =>
      path == '/fixture/package.zip' ? PackageFile() : super.createFile(path);
}

void main() {
  late UninstallInstaller installer;
  late UninstallDownloads downloads;
  late UninstallRepository repository;
  late AppController controller;
  late DownloadTask package;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    installer = UninstallInstaller();
    downloads = UninstallDownloads(installer);
    repository = UninstallRepository();
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    )..snapshot = CatalogSnapshot(const [application], DateTime(2026));
    package = DownloadTask(
      id: 'fixture',
      appName: application.name,
      appKey: application.key,
      url: '',
      filePath: '/fixture/package.zip',
      platform: 'macOS',
      kind: 'zip',
      state: DownloadState.downloaded,
      createdAt: DateTime(2026),
    );
    downloads.tasks.add(package);
  });

  tearDown(() {
    controller.dispose();
    repository.client.close(force: true);
    downloads.client.close(force: true);
    downloads.macResolver.client.close(force: true);
    downloads.dispose();
  });

  Future<void> openManagement(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1240, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: AppLibraryPage(controller: controller, manager: downloads),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(application.name));
    await tester.pumpAndSettle();
    expect(find.text('应用管理'), findsOneWidget);
  }

  Future<void> confirmUninstall(WidgetTester tester) async {
    await tester.tap(find.text('卸载应用'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('卸载应用？'), findsOneWidget);
    expect(find.text(installation.bundleIdentifier), findsOneWidget);
    expect(find.text('已下载的安装包和下载记录会保留。'), findsOneWidget);
    await tester.tap(find.text('移到废纸篓'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  void expectPackagePreserved() {
    expect(downloads.tasks, [package]);
    expect(package.state, DownloadState.downloaded);
    expect(package.filePath, '/fixture/package.zip');
  }

  testWidgets('canceling uninstall never calls the native uninstaller', (
    tester,
  ) async {
    await openManagement(tester);
    await tester.tap(find.text('卸载应用'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(installer.calls, isEmpty);
    expect(find.text('卸载应用'), findsOneWidget);
    expectPackagePreserved();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('canceling elevation preserves the identity and permits retry', (
    tester,
  ) async {
    installer.requireAuthorization = true;
    await openManagement(tester);
    await confirmUninstall(tester);
    expect(find.text('需要管理员授权'), findsOneWidget);
    expect(find.text(installation.bundleIdentifier), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(installer.calls, [null]);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '卸载应用'))
          .onPressed,
      isNotNull,
    );
    expectPackagePreserved();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('system cancellation clears waiting state without losing files', (
    tester,
  ) async {
    installer.requireAuthorization = true;
    installer.authorization = Completer<void>();
    await openManagement(tester);
    await confirmUninstall(tester);
    await tester.tap(find.text('授权并卸载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('等待系统授权并移到废纸篓…'), findsOneWidget);
    final button = find.widgetWithText(TextButton, '卸载应用');
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(installer.calls, [null, approvalSnapshot]);
    installer.authorization!.completeError(
      PlatformException(code: 'cancelled', message: '已取消管理员授权。'),
    );
    await tester.pumpAndSettle();
    expect(find.text('等待系统授权并移到废纸篓…'), findsNothing);
    expect(find.text('已取消管理员授权。'), findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expectPackagePreserved();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('canceling App Management guidance keeps uninstall retryable', (
    tester,
  ) async {
    installer.requireAuthorization = true;
    installer.uninstallError = PlatformException(
      code: 'app_management_permission',
      message: 'macOS 拒绝移动所选应用。',
    );
    await openManagement(tester);
    await confirmUninstall(tester);
    await tester.tap(find.text('授权并卸载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('需要 App 管理权限'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(installer.calls, [null, approvalSnapshot]);
    expect(installer.settingsRequests, 0);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '卸载应用'))
          .onPressed,
      isNotNull,
    );
    expectPackagePreserved();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('opening App Management settings never retries uninstall', (
    tester,
  ) async {
    installer.requireAuthorization = true;
    installer.uninstallError = PlatformException(
      code: 'app_management_permission',
    );
    await openManagement(tester);
    await confirmUninstall(tester);
    await tester.tap(find.text('授权并卸载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('打开系统设置'));
    await tester.pumpAndSettle();
    expect(installer.settingsRequests, 1);
    expect(installer.calls, [null, approvalSnapshot]);
    expect(find.text('卸载应用'), findsOneWidget);
    expectPackagePreserved();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('settings launch failure explains the manual permissions path', (
    tester,
  ) async {
    installer.uninstallError = PlatformException(
      code: 'app_management_permission',
    );
    installer.settingsError = PlatformException(code: 'settings');
    await openManagement(tester);
    await confirmUninstall(tester);
    await tester.tap(find.text('打开系统设置'));
    await tester.pumpAndSettle();
    expect(installer.settingsRequests, 1);
    expect(find.textContaining('请从系统设置进入'), findsOneWidget);
    expect(installer.calls, [null]);
    expectPackagePreserved();
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'native completion rechecks actual installation and keeps files',
    (tester) async {
      await IOOverrides.runWithIOOverrides(() async {
        await openManagement(tester);
        final refreshes = downloads.refreshes;
        await confirmUninstall(tester);
        expect(installer.calls, [null]);
        expect(downloads.refreshes, greaterThan(refreshes));
        expect(find.text('卸载应用'), findsOneWidget);
        installer.removeApplication = true;
        await confirmUninstall(tester);
        expect(find.text('卸载应用'), findsNothing);
        expectPackagePreserved();
        expect(tester.takeException(), isNull);
      }, PackageFiles());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
