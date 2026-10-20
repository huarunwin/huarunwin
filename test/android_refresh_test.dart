import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/ui/detail.dart';
import 'package:huarunwin/ui/downloads_page.dart';
import 'package:huarunwin/ui/licenses_page.dart';
import 'package:huarunwin/ui/page_components.dart';
import 'package:huarunwin/ui/settings.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_page_test.dart' show RefreshableDownloads;

const app = CatalogApp(
  id: 'refresh',
  name: '下拉刷新应用',
  url: 'https://huarun.win/apps/refresh',
  platforms: ['Android'],
);

class RefreshPages extends CatalogRepository {
  RefreshPages(super.directory);

  Completer<void>? pending;
  bool fail = false;
  int refreshes = 0;
  bool directoryPage = false;

  Future<void> _fetch(bool refresh) async {
    if (refresh) refreshes++;
    await pending?.future;
    if (fail) throw const SocketException('offline');
  }

  @override
  Future<CatalogSnapshot> catalog({String? core, bool refresh = false}) async {
    await _fetch(refresh);
    return CatalogSnapshot(const [app], DateTime.now());
  }

  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    await _fetch(refresh);
    return DetailSnapshot(
      AppDetails(app: app, description: '详情内容 $refreshes'),
      DateTime.now(),
    );
  }

  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    await _fetch(refresh);
    final service = url.contains('/vps/example/');
    return SiteSnapshot(
      SiteDocument(
        url: url,
        title: '公开页面',
        directory: directoryPage,
        items: [
          if (directoryPage)
            SiteItem(title: '公开条目 $refreshes', url: '$url/example'),
        ],
        service: service
            ? const SiteServiceDetails(
                kind: SiteServiceKind.vps,
                title: '公开套餐',
                overview: SiteBlock(runs: [SiteText('套餐介绍')]),
              )
            : null,
        blocks: [
          if (!directoryPage) SiteBlock(runs: [SiteText('公开正文 $refreshes')]),
        ],
      ),
      DateTime.now(),
    );
  }
}

Future<void> pull(WidgetTester tester) async {
  await tester.dragFrom(const Offset(180, 270), const Offset(0, 420));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late Directory folder;
  late RefreshPages repository;
  late AppController controller;
  late RefreshableDownloads downloads;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('huarun-android-refresh');
    repository = RefreshPages(folder);
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    )..snapshot = CatalogSnapshot(const [app], DateTime.now());
    downloads = RefreshableDownloads();
  });

  tearDown(() {
    controller.dispose();
    repository.client.close(force: true);
    downloads.dispose();
    folder.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PageSafeArea(child: page)),
      ),
    );
    await tester.pump();
  }

  void expectScrollingTop(WidgetTester tester) {
    final viewport = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    expect(tester.getTopLeft(viewport.first).dy, 0);
    expect(
      tester.getTopLeft(find.byType(PageHeader)).dy,
      greaterThanOrEqualTo(32),
    );
    expect(
      tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).edgeOffset,
      32,
    );
  }

  testWidgets('catalog pulls once and preserves its query while refreshing', (
    tester,
  ) async {
    await show(tester, HuarunApp(controller: controller, downloads: downloads));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    await tester.enterText(find.byType(TextField), '下拉');
    expect(tester.testTextInput.isVisible, isTrue);
    repository.pending = Completer<void>();
    await pull(tester);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(repository.refreshes, 1);
    expect(find.text(app.name), findsOneWidget);
    await pull(tester);
    expect(repository.refreshes, 1);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '下拉',
    );
    expect(find.text(app.name), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final path in [
    '/vps',
    '/jichang',
    '/feed',
    '/history/apps',
    '/servers',
    '/about',
    '/articles/example',
    '/vps/example/basic',
  ]) {
    testWidgets(
      'Android page $path refreshes short content and retains failures',
      (tester) async {
        repository.directoryPage = [
          '/vps',
          '/jichang',
          '/feed',
          '/history/apps',
          '/servers',
        ].contains(path);
        await show(
          tester,
          SitePage(
            url: 'https://huarun.win$path',
            controller: controller,
            downloads: downloads,
          ),
        );
        await tester.pumpAndSettle();
        expectScrollingTop(tester);
        expect(find.byIcon(Icons.refresh_rounded), findsNothing);
        expect(find.byType(RefreshIndicator), findsOneWidget);
        final text = repository.directoryPage ? '公开条目' : '公开正文';
        repository.pending = Completer<void>();
        await pull(tester);
        expect(repository.refreshes, 1);
        expect(find.text('$text 0'), findsOneWidget);
        await pull(tester);
        expect(repository.refreshes, 1);
        repository.pending!.complete();
        await tester.pumpAndSettle();
        expect(find.text('$text 1'), findsOneWidget);
        repository.fail = true;
        await pull(tester);
        await tester.pumpAndSettle();
        expect(repository.refreshes, 2);
        expect(find.text('$text 1'), findsOneWidget);
        repository.fail = false;
        await pull(tester);
        await tester.pumpAndSettle();
        expect(repository.refreshes, 3);
        expect(find.text('$text 3'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'detail keeps its content while pending and after refresh failure',
    (tester) async {
      await show(
        tester,
        DetailPage(app: app, controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      expectScrollingTop(tester);
      expect(find.byTooltip('刷新详情'), findsNothing);
      expect(find.byTooltip('在网站查看'), findsOneWidget);
      repository.pending = Completer<void>();
      await pull(tester);
      expect(repository.refreshes, 1);
      expect(find.text('详情内容 0'), findsOneWidget);
      await pull(tester);
      expect(repository.refreshes, 1);
      repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('详情内容 1'), findsOneWidget);
      repository.fail = true;
      await pull(tester);
      await tester.pumpAndSettle();
      expect(find.text('详情内容 1'), findsOneWidget);
      expect(find.textContaining('刷新失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed and empty pages can be retried by pulling', (
    tester,
  ) async {
    repository.fail = true;
    await show(
      tester,
      SitePage(
        url: 'https://huarun.win/about',
        controller: controller,
        downloads: downloads,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载'), findsOneWidget);
    expectScrollingTop(tester);
    repository.fail = false;
    await pull(tester);
    await tester.pumpAndSettle();
    expect(find.text('公开正文 1'), findsOneWidget);

    await show(tester, DownloadsPage(manager: downloads));
    downloads.finish();
    await tester.pumpAndSettle();
    expect(find.byTooltip('刷新下载状态'), findsNothing);
    expect(find.text('下载准备就绪'), findsOneWidget);
    expectScrollingTop(tester);
    await pull(tester);
    expect(downloads.refreshCalls, 2);
    await pull(tester);
    expect(downloads.refreshCalls, 2);
    downloads.finish();
    await tester.pumpAndSettle();
    expect(find.text('下载准备就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local settings reload without resetting filters', (
    tester,
  ) async {
    await show(
      tester,
      SettingsPage(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
    await controller.preferences.setString('theme', 'dark');
    await pull(tester);
    await tester.pumpAndSettle();
    expect(controller.themeMode, ThemeMode.dark);
    expect(controller.catalogPlatform, '全部');
    expect(repository.refreshes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'license list reloads bundled licenses and license text supports pulling',
    (tester) async {
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(['refresh_fixture'], '本地许可正文');
      });
      await show(tester, const LicensesPage());
      await tester.pumpAndSettle();
      LicenseRegistry.addLicense(() async* {
        yield const LicenseEntryWithLineBreaks(['new_fixture'], '新增本地许可');
      });
      expect(find.text('new_fixture'), findsNothing);
      expectScrollingTop(tester);
      await pull(tester);
      await tester.pumpAndSettle();
      expect(find.text('new_fixture'), findsOneWidget);
      await tester.tap(find.text('new_fixture'));
      await tester.pumpAndSettle();
      expect(find.byType(ContentPage), findsOneWidget);
      expectScrollingTop(tester);
      await pull(tester);
      await tester.pumpAndSettle();
      expect(find.text('新增本地许可'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
