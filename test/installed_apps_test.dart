import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/installed_apps.dart';

const app = CatalogApp(
  id: 'example',
  name: 'Example',
  url: 'https://huarun.win/apps/example',
  platforms: ['macOS', 'Windows'],
);
const installed = InstalledApplication(
  path: '/Applications/Renamed.app',
  bundleIdentifier: 'win.huarun.fixture',
  version: '0.9.0',
  names: ['Example', 'Renamed'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'numeric releases, prefixes, missing components and prereleases compare',
    () {
      for (final (current, latest, newer) in [
        ('0.9.0', 'v0.9.1', true),
        ('0.9.9', '0.9.10', true),
        ('1.9', '1.10', true),
        ('2.0', '1.9.99', false),
        ('1.2.0', 'V1.2', false),
        ('1.2', '1.2.0.0', false),
        ('1.2.0-rc.1', '1.2.0', true),
        ('1.2.0', '1.2.0-beta.1', false),
        ('1.2.0-rc.2', '1.2.0-rc.10', true),
        ('1.2.0-beta.1', '1.2.0-rc.1', true),
        ('1.2.0+123', '1.2.0+456', false),
        ('unknown', '1.2.0', false),
        ('1.2.0', '待核实', false),
        ('1.2.0', '1.3.0 / Mac 1.1.0', false),
        ('', '1.2.0', false),
      ]) {
        expect(
          hasNewerVersion(current, latest),
          newer,
          reason: '$current -> $latest',
        );
      }
    },
  );

  test('local application metadata comes through the native channel', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativeInstaller.channel, (call) async {
      expect(call.method, 'installedApplications');
      return [
        {
          'path': installed.path,
          'bundleIdentifier': installed.bundleIdentifier,
          'version': installed.version,
          'names': installed.names,
        },
      ];
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(NativeInstaller.channel, null),
    );
    final apps = await NativeInstaller().installedApplications();
    expect(apps.single.path, installed.path);
    expect(apps.single.bundleIdentifier, installed.bundleIdentifier);
    expect(apps.single.version, '0.9.0');
    expect(apps.single.names, contains('Example'));
  });

  test('matching uses exact bundle names and shares one local scan', () async {
    var calls = 0;
    final request = Completer<List<InstalledApplication>>();
    final apps = InstalledApplications(() {
      calls++;
      return request.future;
    });
    addTearDown(apps.dispose);
    final first = apps.find(app);
    final second = apps.find(app);
    request.complete([installed]);
    expect(await first, installed);
    expect(await second, installed);
    expect(await apps.find(app), installed);
    expect(calls, 1);
    expect(
      await apps.find(
        const CatalogApp(
          id: 'partial',
          name: 'Exam',
          url: 'https://huarun.win/apps/partial',
          platforms: ['macOS'],
        ),
      ),
      isNull,
    );
    expect(
      await apps.find(
        const CatalogApp(
          id: 'case',
          name: 'example',
          url: 'https://huarun.win/apps/case',
          platforms: ['macOS'],
        ),
      ),
      installed,
    );
  });

  test(
    'same name conflicts and multiple installed copies stay unknown',
    () async {
      for (final id in ['win.huarun.other', installed.bundleIdentifier]) {
        final apps = InstalledApplications(
          () async => [
            installed,
            InstalledApplication(
              path: '/Users/fixture/Applications/Example.app',
              bundleIdentifier: id,
              version: '0.8.0',
              names: const ['Example'],
            ),
          ],
        );
        expect(await apps.find(app), isNull);
        apps.dispose();
      }
    },
  );

  test('nonclient resources do not inspect local applications', () async {
    var calls = 0;
    final apps = InstalledApplications(() async {
      calls++;
      return [installed];
    });
    addTearDown(apps.dispose);
    expect(
      await apps.find(
        const CatalogApp(
          id: 'example',
          name: 'Example',
          url: 'https://huarun.win/servers/example',
          type: ApplicationType.server,
        ),
      ),
      isNull,
    );
    expect(calls, 0);
  });

  test('invalidated scans cannot overwrite a new snapshot', () async {
    final pending = <Completer<List<InstalledApplication>>>[];
    final apps = InstalledApplications(() {
      final request = Completer<List<InstalledApplication>>();
      pending.add(request);
      return request.future;
    });
    addTearDown(apps.dispose);
    final first = apps.find(app);
    apps.invalidate();
    final second = apps.find(app);
    pending[1].complete([]);
    expect(await second, isNull);
    pending[0].complete([installed]);
    await first;
    expect(await apps.find(app), isNull);
    expect(pending, hasLength(2));
  });

  test(
    'explicit refresh observes an external update and failure can retry',
    () async {
      var calls = 0;
      final apps = InstalledApplications(() async {
        calls++;
        if (calls == 2) throw PlatformException(code: 'fixture');
        return calls == 1 ? [installed] : [];
      });
      addTearDown(apps.dispose);
      expect(await apps.find(app), installed);
      await expectLater(
        apps.find(app, refresh: true),
        throwsA(isA<PlatformException>()),
      );
      expect(await apps.find(app), installed);
      expect(await apps.find(app, refresh: true), isNull);
    },
  );

  test(
    'platform versions override generic release and missing Mac is unknown',
    () {
      const source = '''
      <article class="detail-page">
      <h1 id="detail-title">Example</h1>
      <script type="application/ld+json">{"@type":"SoftwareApplication","softwareVersion":"2.0.0"}</script>
      <dl class="detail-release-list"><dt>Mac 版本</dt><dd>1.2.0</dd>
      <dt>Windows 版本</dt><dd>2.0.0</dd></dl>
      </article>
    ''';
      final detail = SiteHtmlParser().detail(source, app);
      expect(detail.version, '2.0.0');
      expect(detail.versionForPlatform('macOS'), '1.2.0');
      expect(detail.versionForPlatform('Android'), isNull);
      expect(
        const AppDetails(
          app: app,
          version: 'v0.9.1',
        ).versionForPlatform('macOS'),
        'v0.9.1',
      );
      expect(
        const AppDetails(
          app: app,
          version: '2.0.0',
          platformVersions: {'Windows': '2.0.0'},
        ).versionForPlatform('macOS'),
        isNull,
      );
    },
  );
}
