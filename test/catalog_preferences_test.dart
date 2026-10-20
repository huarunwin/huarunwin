import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/app_download_button.dart';
import 'package:huarunwin/ui/catalog_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _platforms = {
  TargetPlatform.macOS: 'macOS',
  TargetPlatform.windows: 'Windows',
  TargetPlatform.linux: 'Linux',
  TargetPlatform.android: 'Android',
  TargetPlatform.iOS: 'iOS',
};
final _apps = [
  for (final platform in _platforms.values)
    CatalogApp(
      id: platform,
      name: 'Example $platform',
      url: 'https://huarun.win/apps/$platform',
      platforms: [platform],
    ),
  const CatalogApp(
    id: 'deck',
    name: 'Deck Plugin',
    url: 'https://huarun.win/apps/deck',
    platforms: ['Linux'],
  ),
  const CatalogApp(
    id: 'server',
    name: 'Server Example',
    url: 'https://huarun.win/servers/server',
    type: ApplicationType.server,
  ),
];

class _PreferenceRepository extends CatalogRepository {
  _PreferenceRepository(super.directory);
  final deviceRequests = <CatalogDevice>[];

  @override
  Future<CatalogSnapshot> deviceCatalog(
    CatalogDevice device, {
    bool refresh = false,
  }) async {
    deviceRequests.add(device);
    return CatalogSnapshot(
      _apps.where((app) => app.id == 'deck').toList(),
      DateTime.now(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences preferences;
  late _PreferenceRepository repository;
  late DownloadManager downloads;
  AppController? controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    directory = Directory.systemTemp.createTempSync('catalog-preferences');
    repository = _PreferenceRepository(directory);
    downloads = DownloadManager(directory);
  });
  tearDown(() {
    controller?.dispose();
    controller = null;
    repository.client.close(force: true);
    downloads.dispose();
    downloads.client.close(force: true);
    downloads.macResolver.client.close(force: true);
    directory.deleteSync(recursive: true);
  });

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller?.dispose();
    await preferences.reload();
    controller = AppController(repository, preferences)
      ..snapshot = CatalogSnapshot(_apps, DateTime.now());
    await tester.pumpWidget(
      HuarunApp(controller: controller!, downloads: downloads),
    );
    await tester.pumpAndSettle();
  }

  String selection(WidgetTester tester) =>
      find.byType(CompactCatalogFilters).evaluate().isNotEmpty
      ? tester
            .widget<CompactCatalogFilters>(find.byType(CompactCatalogFilters))
            .platform
      : tester
            .widget<CatalogFilterControls>(find.byType(CatalogFilterControls))
            .platform;

  testWidgets(
    'first launch filters the catalog for the running platform without saving a choice',
    (tester) async {
      viewport(tester, const Size(1240, 900));
      await launch(tester);
      final expected = _platforms[defaultTargetPlatform]!;
      expect(selection(tester), expected);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('catalog-platform-menu')),
          matching: find.text(expected == 'macOS' ? 'Mac' : expected),
        ),
        findsOneWidget,
      );
      expect(find.text('Example $expected'), findsOneWidget);
      expect(find.text('Server Example'), findsNothing);
      expect(preferences.containsKey('catalogPlatform'), isFalse);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant(_platforms.keys.toSet()),
  );

  testWidgets(
    'global search preserves the remembered device and restores it when cleared',
    (tester) async {
      viewport(tester, const Size(800, 900));
      await preferences.setString('catalogPlatform', 'Steam Deck');
      await launch(tester);
      expect(find.text('Deck Plugin'), findsOneWidget);
      expect(find.text('Server Example'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Server');
      await tester.pumpAndSettle();
      expect(find.text('Server Example'), findsOneWidget);
      expect(find.text('搜索范围：所有类型与平台'), findsNothing);
      expect(find.byKey(const ValueKey('catalog-platform-menu')), findsNothing);
      expect(preferences.getString('catalogPlatform'), 'Steam Deck');
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(selection(tester), 'Steam Deck');
      expect(find.text('Deck Plugin'), findsOneWidget);
      expect(find.text('Server Example'), findsNothing);
      expect(repository.deviceRequests, [CatalogDevice.steamDeck]);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.macOS}),
  );

  testWidgets(
    'explicit platform choices including the default and all survive relaunch and type navigation',
    (tester) async {
      viewport(tester, const Size(1240, 900));
      await launch(tester);
      for (final value in ['macOS', 'Windows', '全部']) {
        await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('platform-option-$value')));
        await tester.pumpAndSettle();
        expect(preferences.getString('catalogPlatform'), value);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('catalog-platform-menu')),
            matching: find.text(
              value == '全部'
                  ? '平台'
                  : value == 'macOS'
                  ? 'Mac'
                  : value,
            ),
          ),
          findsOneWidget,
        );
        if (value == 'Windows') {
          await tester.tap(find.byKey(const ValueKey('nav-type-server')));
          await tester.pumpAndSettle();
          expect(find.text('Server Example'), findsOneWidget);
          expect(preferences.getString('catalogPlatform'), 'Windows');
          await tester.tap(find.byKey(const ValueKey('nav-applications')));
          await tester.pumpAndSettle();
          expect(selection(tester), 'Windows');
        }
        await launch(tester);
        expect(selection(tester), value);
        if (value != '全部') {
          expect(find.text('Example $value'), findsOneWidget);
          expect(find.text('Server Example'), findsNothing);
        } else {
          expect(find.text('7 款应用'), findsOneWidget);
        }
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'saved device selection loads its category on the first frame and keeps download platforms separate',
    (tester) async {
      viewport(tester, const Size(1240, 900));
      await preferences.setString('catalogPlatform', 'Steam Deck');
      await launch(tester);
      expect(selection(tester), 'Steam Deck');
      expect(repository.deviceRequests, [CatalogDevice.steamDeck]);
      expect(find.text('Deck Plugin'), findsOneWidget);
      expect(find.text('Example Linux'), findsNothing);
      expect(
        tester
            .widget<AppDownloadButton>(find.byType(AppDownloadButton))
            .selectedPlatform,
        '全部',
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  for (final size in [const Size(1240, 900), const Size(390, 844)]) {
    testWidgets(
      'settings reset deletes the saved filter and restores the platform immediately and after relaunch at $size',
      (tester) async {
        viewport(tester, size);
        await preferences.setString('catalogPlatform', 'Windows');
        await preferences.setString('theme', 'dark');
        await preferences.setBool('catalogGrid', false);
        await launch(tester);
        expect(selection(tester), 'Windows');
        await tester.tap(find.text(size.width >= 900 ? '偏好设置' : '设置'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('重置为默认值'));
        await tester.tap(find.text('重置为默认值'));
        await tester.pumpAndSettle();
        expect(preferences.containsKey('catalogPlatform'), isFalse);
        expect(preferences.getString('theme'), 'dark');
        expect(preferences.getBool('catalogGrid'), isFalse);
        await tester.tap(
          size.width >= 900
              ? find.byKey(const ValueKey('nav-applications'))
              : find.descendant(
                  of: find.byKey(const ValueKey('android-navigation-bar')),
                  matching: find.text('发现'),
                ),
        );
        await tester.pumpAndSettle();
        expect(selection(tester), 'macOS');
        expect(find.text('Example macOS'), findsOneWidget);
        await launch(tester);
        expect(selection(tester), 'macOS');
        expect(preferences.containsKey('catalogPlatform'), isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }

  testWidgets(
    'unrecognized and malformed saved choices fall back to the running platform',
    (tester) async {
      viewport(tester, const Size(1240, 900));
      await preferences.setString('catalogPlatform', 'retired-platform');
      await launch(tester);
      expect(selection(tester), 'macOS');
      await preferences.setBool('catalogPlatform', false);
      await launch(tester);
      expect(selection(tester), 'macOS');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
