import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/download_platform.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/mac_downloads.dart';
import 'package:huarunwin/services/installed_apps.dart';
import 'package:huarunwin/services/linux_installer.dart';
import 'package:huarunwin/ui/app_download_button.dart';

import 'mac_downloads_test.dart' show ReleaseAdapter;

const app = CatalogApp(
  id: 'example',
  name: 'Example',
  url: 'https://huarun.win/apps/example',
  platforms: ['Windows', 'macOS', 'Linux'],
);
const mac = DownloadLink(
  url: 'https://example.com/app-macos-arm64.dmg',
  label: 'Mac ARM64',
  platform: 'macOS',
  kind: 'dmg',
  architecture: 'arm64',
);
const windows = DownloadLink(
  url: 'https://example.com/app-windows-x64.zip',
  label: 'Windows x64',
  platform: 'Windows',
  kind: 'zip',
  architecture: 'x64',
);
const android = DownloadLink(
  url: 'https://github.com/example/app/releases/download/v1/app-arm64.apk',
  label: 'Android ARM64',
  platform: 'Android',
  kind: 'apk',
  architecture: 'arm64',
);

class TestResolver extends MacDownloadResolver {
  final requested = <String>[];
  List<DownloadLink> windowsPackages = const [windows];
  List<DownloadLink> androidPackages = const [android];
  List<DownloadLink> linuxPackages = const [];
  @override
  Future<MacDownloadOptions> resolve(AppDetails detail) async {
    requested.add('macOS');
    return const MacDownloadOptions(packages: [mac]);
  }

  @override
  Future<List<DownloadLink>> resolvePackages(
    AppDetails detail,
    String platform,
  ) async {
    requested.add(platform);
    return switch (platform) {
      'Windows' => windowsPackages,
      'Android' => androidPackages,
      'Linux' => linuxPackages,
      _ => [],
    };
  }
}

class TestInstaller extends NativeInstaller {
  List<InstalledApplication> apps = [];
  bool failLookup = false;
  int lookups = 0;

  @override
  Future<List<InstalledApplication>> installedApplications() async {
    lookups++;
    if (failLookup) throw PlatformException(code: 'fixture');
    return apps;
  }

  @override
  Future<String?> architecture() async => 'arm64';
  @override
  Future<LinuxSystemInfo> linuxSystemInfo() async => const LinuxSystemInfo(
    architecture: 'arm64',
    packageKind: 'deb',
    distribution: 'Ubuntu Fixture',
  );
}

class TestDownloads extends DownloadManager {
  TestDownloads(super.directory, TestResolver resolver)
    : super(macResolver: resolver, installer: TestInstaller());
  final requested = <DownloadLink>[];
  @override
  Future<DownloadTask> download(
    CatalogApp app,
    DownloadLink link, {
    AndroidSigningKey? resignKey,
    String? resignPackageName,
  }) async {
    requested.add(link);
    return DownloadTask(
      id: 'test',
      appName: app.name,
      url: link.url,
      filePath: '${directory.path}/package.${link.kind}',
      kind: link.kind!,
      platform: link.platform,
      createdAt: DateTime.now(),
    );
  }
}

class TestRepository extends CatalogRepository {
  TestRepository(super.directory);
  @override
  Future<DetailSnapshot> detail(
    CatalogApp summary, {
    bool refresh = false,
  }) async => DetailSnapshot(const AppDetails(app: app), DateTime.now());
}

Matcher packageLike(DownloadLink expected) => isA<DownloadLink>()
    .having((value) => value.url, 'url', expected.url)
    .having((value) => value.label, 'label', expected.label)
    .having((value) => value.platform, 'platform', expected.platform)
    .having(
      (value) => value.architecture,
      'architecture',
      expected.architecture,
    )
    .having((value) => value.kind, 'kind', expected.kind)
    .having((value) => value.sha256, 'sha256', expected.sha256)
    .having(
      (value) => value.checksumSource,
      'checksumSource',
      expected.checksumSource,
    )
    .having((value) => value.releaseUrl, 'releaseUrl', expected.releaseUrl);

void main() {
  test(
    'matching or all platforms use the device; mismatches require selection',
    () {
      for (final selected in ['macOS', '全部']) {
        expect(
          directDownloadPlatform(
            selected: selected,
            running: 'macOS',
            supported: app.platforms,
          ),
          'macOS',
        );
      }
      for (final selected in ['Windows', 'Android', 'Linux']) {
        expect(
          directDownloadPlatform(
            selected: selected,
            running: 'macOS',
            supported: app.platforms,
          ),
          isNull,
        );
      }
      expect(
        directDownloadPlatform(
          selected: '全部',
          running: 'macOS',
          supported: ['Windows'],
        ),
        isNull,
      );
      expect(
        directDownloadPlatform(
          selected: '全部',
          running: null,
          supported: app.platforms,
        ),
        isNull,
      );
    },
  );

  late Directory directory;
  late TestResolver resolver;
  late TestDownloads downloads;
  setUp(() async {
    PackageInfo.setMockInitialValues(
      appName: 'Fixture',
      packageName: 'win.huarun.fixture',
      version: '1.2.3',
      buildNumber: '1',
      buildSignature: '',
    );
    directory = await Directory.systemTemp.createTemp('huarun-download-ui');
    resolver = TestResolver();
    downloads = TestDownloads(directory, resolver);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    downloads.client.close(force: true);
    resolver.client.close(force: true);
    downloads.dispose();
    await directory.delete(recursive: true);
  });

  for (final platform in ['macOS', 'Android', 'Windows', 'Linux']) {
    final kind = switch (platform) {
      'macOS' => 'dmg',
      'Android' => 'apk',
      'Windows' => 'exe',
      _ => 'deb',
    };
    final target = switch (platform) {
      'macOS' => TargetPlatform.macOS,
      'Android' => TargetPlatform.android,
      'Windows' => TargetPlatform.windows,
      _ => TargetPlatform.linux,
    };
    testWidgets(
      '$platform GitHub download confirms version and resource before entering manager',
      (tester) async {
        final packageApp = CatalogApp(
          id: 'example',
          name: 'Example',
          url: app.url,
          platforms: [platform],
        );
        final adapter = ReleaseAdapter({
          'https://github.com/owner/repo/releases': '''
          <section data-release-anchor="v2"><div>
            <span class="f1"><a href="/owner/repo/releases/tag/v2">v2</a></span><span class="Label">Latest</span>
          </div><include-fragment src="/owner/repo/releases/expanded_assets/v2"></include-fragment></section>
          <section data-release-anchor="v1"><div><span class="f1"><a href="/owner/repo/releases/tag/v1">v1</a></span></div></section>
        ''',
          'https://github.com/owner/repo/releases/expanded_assets/v2':
              '''
          <li><a href="/owner/repo/releases/download/v2/app-${platform.toLowerCase()}-arm64.$kind">ARM64</a></li>
          <li><a href="/owner/repo/releases/download/v2/app-${platform.toLowerCase()}-x64.$kind">x64</a></li>
        ''',
        });
        resolver.client.httpClientAdapter = adapter;
        var started = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppDownloadButton(
                app: packageApp,
                loadDetails: () async => AppDetails(
                  app: packageApp,
                  releaseUrl: 'https://github.com/owner/repo/releases',
                ),
                manager: downloads,
                onStarted: () => started = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final cancel in [true, false]) {
          await tester.tap(find.text('下载'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('v2 · 稳定版'), findsOneWidget);
          expect(downloads.requested, isEmpty);
          expect(started, isFalse);
          await tester.tap(find.text(cancel ? '取消' : '确认下载'));
          await tester.pumpAndSettle();
          if (cancel) {
            expect(downloads.requested, isEmpty);
          } else {
            expect(downloads.requested.single.platform, platform);
            expect(downloads.requested.single.architecture, 'arm64');
            expect(downloads.requested.single.version, 'v2');
            expect(started, isTrue);
          }
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(target),
    );
  }

  testWidgets(
    'mixed Mac Store and GitHub sources retain version selection after source confirmation',
    (tester) async {
      final adapter = ReleaseAdapter({
        'https://github.com/owner/repo/releases': '''
        <section data-release-anchor="v1"><div><span class="f1"><a href="/owner/repo/releases/tag/v1">v1</a></span><span class="Label">Latest</span></div>
        <li><a href="/owner/repo/releases/download/v1/app-arm64.dmg">DMG</a></li></section>
      ''',
      });
      resolver.client.httpClientAdapter = adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppDownloadButton(
              app: app,
              loadDetails: () async => const AppDetails(
                app: app,
                downloads: [
                  DownloadLink(
                    url: 'https://apps.apple.com/app/id123456',
                    label: 'Store',
                    platform: 'macOS',
                  ),
                  DownloadLink(
                    url: 'https://github.com/owner/repo/releases/download/v1/app-arm64.dmg',
                    label: 'DMG',
                    platform: 'macOS',
                    kind: 'dmg',
                  ),
                ],
              ),
              manager: downloads,
              onStarted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择下载来源'), findsOneWidget);
      expect(adapter.requests, isEmpty);
      await tester.tap(find.widgetWithText(ListTile, 'GitHub'));
      await tester.pump();
      expect(adapter.requests, isEmpty);
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('v1 · 稳定版'), findsOneWidget);
      expect(downloads.requested, isEmpty);
      await tester.tap(find.text('确认下载'));
      await tester.pumpAndSettle();
      expect(downloads.requested.single.version, 'v1');
      expect(downloads.requested.single.kind, 'dmg');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final selected in ['macOS', '全部']) {
    testWidgets(
      '$selected starts a native Mac download without a platform dialog',
      (tester) async {
        var started = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AppDownloadButton(
                app: app,
                selectedPlatform: selected,
                loadDetails: () async => const AppDetails(app: app),
                manager: downloads,
                onStarted: () => started = true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载'));
        await tester.pumpAndSettle();
        expect(find.text('选择下载平台'), findsNothing);
        expect(resolver.requested, ['macOS']);
        expect(downloads.requested, [packageLike(mac)]);
        expect(started, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  const androidApp = CatalogApp(
    id: 'android-example',
    name: 'Android Example',
    url: 'https://huarun.win/apps/android-example',
    platforms: ['Android'],
  );
  for (final selected in ['Android', '全部']) {
    testWidgets('$selected on Android downloads the APK inside the app', (
      tester,
    ) async {
      var started = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppDownloadButton(
              app: androidApp,
              selectedPlatform: selected,
              loadDetails: () async => const AppDetails(app: androidApp),
              manager: downloads,
              onStarted: () => started = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();
      expect(resolver.requested, ['Android']);
      expect(downloads.requested, [packageLike(android)]);
      expect(started, isTrue);
      expect(find.text('选择下载平台'), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('Android architecture selection starts only after confirmation', (
    tester,
  ) async {
    const x64 = DownloadLink(
      url: 'https://github.com/example/app/releases/download/v1/app-x64.apk',
      label: 'Android x64',
      platform: 'Android',
      kind: 'apk',
      architecture: 'x64',
    );
    resolver.androidPackages = [android, x64];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDownloadButton(
            app: androidApp,
            loadDetails: () async => const AppDetails(app: androidApp),
            manager: downloads,
            onStarted: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final cancel in [true, false]) {
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ListTile, 'APK · x64'));
      await tester.pump();
      expect(downloads.requested, isEmpty);
      await tester.tap(find.text(cancel ? '取消' : '确认'));
      await tester.pumpAndSettle();
      expect(downloads.requested, cancel ? isEmpty : [packageLike(x64)]);
    }
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets(
    'Windows recommends native architecture but waits for confirmation',
    (tester) async {
      const arm = DownloadLink(
        url: 'https://example.com/windows-arm64.exe',
        label: 'Windows ARM64',
        platform: 'Windows',
        kind: 'exe',
        architecture: 'arm64',
      );
      resolver.windowsPackages = [windows, arm];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppDownloadButton(
              app: app,
              loadDetails: () async => const AppDetails(app: app),
              manager: downloads,
              onStarted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.widgetWithText(ListTile, 'EXE · arm64 · 适合当前设备'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, 'EXE · arm64 · 适合当前设备'),
            )
            .selected,
        isTrue,
      );
      expect(downloads.requested, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(downloads.requested, isEmpty);
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(downloads.requested, [packageLike(arm)]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Linux preselects its package family and ABI and requires confirmation',
    (tester) async {
      const rpm = DownloadLink(
        url: 'https://example.com/linux-arm64.rpm',
        label: 'Linux RPM',
        platform: 'Linux',
        kind: 'rpm',
        architecture: 'arm64',
      );
      const deb = DownloadLink(
        url: 'https://example.com/linux-arm64.deb',
        label: 'Linux DEB',
        platform: 'Linux',
        kind: 'deb',
        architecture: 'arm64',
      );
      resolver.linuxPackages = [rpm, deb];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppDownloadButton(
              app: app,
              loadDetails: () async => const AppDetails(app: app),
              manager: downloads,
              onStarted: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Ubuntu Fixture'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, 'DEB · arm64 · 适合当前设备'),
            )
            .selected,
        isTrue,
      );
      expect(downloads.requested, isEmpty);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(downloads.requested, [packageLike(deb)]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  for (final fromDetail in [false, true]) {
    testWidgets(
      'Windows filter asks for a platform from ${fromDetail ? 'details' : 'the catalog'}',
      (tester) async {
        tester.view.physicalSize = const Size(1240, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repository = TestRepository(directory);
        final controller = AppController(
          repository,
          await SharedPreferences.getInstance(),
        );
        controller.snapshot = CatalogSnapshot([app], DateTime.now());
        addTearDown(() {
          controller.dispose();
          repository.client.close(force: true);
        });
        await tester.pumpWidget(
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('platform-option-Windows')));
        await tester.pumpAndSettle();
        if (fromDetail) {
          await tester.tap(find.text(app.name));
          await tester.pumpAndSettle();
        }
        final button = find.descendant(
          of: find.byType(AppDownloadButton),
          matching: find.byType(FilledButton),
        );
        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('选择下载平台'), findsOneWidget);
        expect(resolver.requested, isEmpty);
        expect(downloads.requested, isEmpty);
        final windowsRow = find.widgetWithText(ListTile, 'Windows');
        final macRow = find.widgetWithText(ListTile, 'Mac');
        expect(tester.widget<ListTile>(windowsRow).selected, isTrue);
        await tester.tap(macRow);
        await tester.pump();
        expect(tester.widget<ListTile>(windowsRow).selected, isFalse);
        expect(tester.widget<ListTile>(macRow).selected, isTrue);
        expect(find.text('选择下载平台'), findsOneWidget);
        expect(resolver.requested, isEmpty);
        expect(downloads.requested, isEmpty);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(resolver.requested, isEmpty);
        expect(downloads.requested, isEmpty);

        await tester.tap(button);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.widget<ListTile>(windowsRow).selected, isTrue);
        await tester.tap(macRow);
        await tester.pump();
        await tester.tap(windowsRow);
        await tester.pump();
        expect(tester.widget<ListTile>(windowsRow).selected, isTrue);
        expect(tester.widget<ListTile>(macRow).selected, isFalse);
        expect(resolver.requested, isEmpty);
        expect(downloads.requested, isEmpty);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(resolver.requested, ['Windows']);
        expect(downloads.requested, [packageLike(windows)]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'package selection waits for confirmation and cancellation discards it',
    (tester) async {
      const windowsArm = DownloadLink(
        url: 'https://example.com/app-windows-arm64.zip',
        label: 'Windows ARM64',
        platform: 'Windows',
        kind: 'zip',
        architecture: 'arm64',
      );
      resolver.windowsPackages = [windows, windowsArm];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppDownloadButton(
              app: app,
              selectedPlatform: 'Windows',
              loadDetails: () async => const AppDetails(app: app),
              manager: downloads,
              onStarted: () {},
            ),
          ),
        ),
      );
      for (final cancel in [true, false]) {
        await tester.tap(find.text('下载'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('确认'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final x64Row = find.widgetWithText(ListTile, 'ZIP · x64');
        final armRow = find.widgetWithText(ListTile, 'ZIP · arm64');
        expect(tester.widget<ListTile>(x64Row).selected, isTrue);
        await tester.tap(armRow);
        await tester.pump();
        expect(tester.widget<ListTile>(x64Row).selected, isFalse);
        expect(tester.widget<ListTile>(armRow).selected, isTrue);
        expect(downloads.requested, isEmpty);
        await tester.tap(find.text(cancel ? '取消' : '确认'));
        await tester.pumpAndSettle();
        expect(
          downloads.requested,
          cancel ? isEmpty : [packageLike(windowsArm)],
        );
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  test('foreign ZIP tasks never expose Mac installation', () {
    final task = DownloadTask(
      id: 'foreign',
      appName: app.name,
      url: windows.url,
      filePath: '${directory.path}/windows.zip',
      kind: 'zip',
      platform: 'Windows',
      createdAt: DateTime.now(),
      state: DownloadState.downloaded,
    );
    expect(task.canInstall, isFalse);
  });

  InstalledApplication localVersion(String version) => InstalledApplication(
    path: '/Applications/Example.app',
    bundleIdentifier: 'win.huarun.example',
    version: version,
    names: const ['Example'],
  );

  Future<void> showButton(
    WidgetTester tester, {
    AppDetails details = const AppDetails(app: app, version: 'v0.9.1'),
    String selected = '全部',
    bool primary = true,
    VoidCallback? onStarted,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AppDownloadButton(
          app: app,
          details: primary ? details : null,
          primary: primary,
          selectedPlatform: selected,
          loadDetails: () async => details,
          manager: downloads,
          onStarted: onStarted ?? () {},
        ),
      ),
    ),
  );

  for (final primary in [true, false]) {
    testWidgets(
      'old installed app offers update through existing ${primary ? 'detail' : 'catalog'} download flow',
      (tester) async {
        (downloads.installer as TestInstaller).apps = [localVersion('0.9.0')];
        var started = false;
        await showButton(
          tester,
          primary: primary,
          onStarted: () => started = true,
        );
        await tester.pumpAndSettle();
        expect(find.text('更新'), findsOneWidget);
        expect(find.byTooltip('本机 0.9.0，可更新至 v0.9.1'), findsOneWidget);
        expect(resolver.requested, isEmpty);
        expect(downloads.requested, isEmpty);
        await tester.tap(find.text('更新'));
        await tester.pumpAndSettle();
        expect(resolver.requested, ['macOS']);
        expect(downloads.requested, [packageLike(mac)]);
        expect(started, isTrue);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  for (final version in ['0.9.1', '0.10.0', 'unknown']) {
    testWidgets(
      'installed $version never offers a downgrade or unknown update',
      (tester) async {
        (downloads.installer as TestInstaller).apps = [localVersion(version)];
        await showButton(tester);
        await tester.pumpAndSettle();
        expect(find.text('更新'), findsNothing);
        expect(find.text('打开'), findsOneWidget);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'other platform and platform-specific versions do not use the Mac update label',
    (tester) async {
      final installer = downloads.installer as TestInstaller;
      installer.apps = [localVersion('0.9.0')];
      await showButton(tester, selected: 'Windows');
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsNothing);
      expect(installer.lookups, 0);
      await showButton(
        tester,
        details: const AppDetails(
          app: app,
          version: '2.0.0',
          platformVersions: {'macOS': '0.9.0', 'Windows': '2.0.0'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'successful install invalidation or external removal clears update label',
    (tester) async {
      final installer = downloads.installer as TestInstaller;
      installer.apps = [localVersion('0.9.0')];
      await showButton(tester);
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      installer.apps = [localVersion('0.9.1')];
      downloads.installedApps.invalidate();
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsNothing);
      installer.apps = [localVersion('0.9.0')];
      downloads.installedApps.invalidate();
      await tester.pumpAndSettle();
      expect(find.text('更新'), findsOneWidget);
      installer.apps = [];
      downloads.installedApps.invalidate();
      await tester.pumpAndSettle();
      expect(find.text('下载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('failed local lookup leaves ordinary downloads available', (
    tester,
  ) async {
    (downloads.installer as TestInstaller).failLookup = true;
    await showButton(tester);
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsOneWidget);
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(downloads.requested, [packageLike(mac)]);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('late version lookup cannot apply to another selected platform', (
    tester,
  ) async {
    (downloads.installer as TestInstaller).apps = [localVersion('0.9.0')];
    final pending = Completer<AppDetails>();
    Future<void> render(String selected) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDownloadButton(
            app: app,
            selectedPlatform: selected,
            loadDetails: () => pending.future,
            manager: downloads,
            onStarted: () {},
          ),
        ),
      ),
    );
    await render('macOS');
    await tester.pump();
    await render('Windows');
    pending.complete(const AppDetails(app: app, version: 'v0.9.1'));
    await tester.pumpAndSettle();
    expect(find.text('更新'), findsNothing);
    expect(find.text('下载'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
