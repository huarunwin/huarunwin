import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/app_download_status.dart';
import 'package:huarunwin/services/app_library.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/installed_apps.dart';

const app = CatalogApp(
  id: 'example',
  name: 'Example',
  url: 'https://huarun.win/apps/example',
  platforms: ['Android', 'macOS', 'Windows'],
);
const signingKey = AndroidSigningKey(
  id: 'fixture',
  label: 'Fixture key',
  certificateSha256: 'fixture',
);

DownloadTask task(
  String id, {
  String platform = 'Android',
  DownloadState state = DownloadState.downloaded,
  String? packageName,
  String? source,
  bool resigned = false,
}) => DownloadTask(
  id: id,
  appName: app.name,
  appKey: app.key,
  url: 'https://example.com/$id',
  filePath: '/fixture/$id/package.${platform == 'Android' ? 'apk' : 'exe'}',
  kind: platform == 'Android' ? 'apk' : 'exe',
  platform: platform,
  state: state,
  installedPackage: packageName,
  sourceTaskId: source,
  resignKey: resigned ? signingKey : null,
  resignedSha256: resigned ? 'fixture-digest' : null,
  originalPackageName: 'org.example.app',
  resignPackageName: resigned ? 'org.example.app.copy' : null,
  createdAt: DateTime(2026, 10, 20),
);

class LibraryInstaller extends NativeInstaller {
  int reads = 0;
  @override
  Future<List<InstalledApplication>> installedApplications() async {
    reads++;
    return [
      for (var index = 0; index < 6; index++)
        InstalledApplication(
          path: '/Applications/Fixture$index.app',
          bundleIdentifier: 'org.example.app$index',
          version: '1.0',
          names: ['Fixture $index'],
        ),
    ];
  }
}

class LibraryRepository extends CatalogRepository {
  LibraryRepository({this.refreshFailed = false}) : super(Directory.systemTemp);
  final bool refreshFailed;
  final requested = <String>[];
  int active = 0, maximum = 0;
  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    requested.add(app.key);
    active++;
    if (active > maximum) maximum = active;
    await Future<void>.delayed(Duration.zero);
    active--;
    return DetailSnapshot(
      AppDetails(app: app, version: '2.0'),
      DateTime(2026, 10, 20),
      cached: refreshFailed,
      refreshFailed: refreshFailed,
    );
  }
}

void main() {
  late DownloadManager manager;
  setUp(() => manager = DownloadManager(Directory.systemTemp));
  tearDown(() {
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    manager.dispose();
  });
  List<LibraryItem> items({
    String platform = 'Android',
    Map<String, LibraryAppStatus> statuses = const {},
    Map<String, AppDownloadStatus?> androidPackages = const {},
  }) => libraryItems(
    apps: [app],
    manager: manager,
    statuses: statuses,
    platform: platform,
    androidPackages: androidPackages,
  );

  test('renamed APK stays pending beside an installed original at the same version', () {
    final original = task('original', resigned: true);
    original.apkIdentities.addAll({
      DownloadPackage.original: const AndroidApkIdentity(
        packageName: 'org.example.app',
        version: '1.0',
        versionCode: 1,
      ),
      DownloadPackage.resigned: const AndroidApkIdentity(
        packageName: 'org.example.app.copy',
        version: '1.0',
        versionCode: 1,
      ),
    });
    manager.tasks.add(original);
    final item = items(
      androidPackages: {
        'org.example.app': const AppDownloadStatus(
          installedPackage: 'org.example.app',
          version: '1.0',
          versionCode: 1,
        ),
        'org.example.app.copy': null,
      },
    ).single;
    expect(item.isInstalled, isTrue);
    expect(item.pendingPackages, [
      (task: original, package: DownloadPackage.resigned),
    ]);
    expect(item.matches(LibrarySection.pending), isTrue);
  });

  test(
    'pending APKs use actual long version codes rather than release labels',
    () {
      final original = task('original');
      original.apkIdentities[DownloadPackage.original] =
          const AndroidApkIdentity(
            packageName: 'org.example.app',
            version: 'same-label',
            versionCode: 4294967300,
          );
      manager.tasks.add(original);
      final item = items(
        androidPackages: {
          'org.example.app': const AppDownloadStatus(
            installedPackage: 'org.example.app',
            version: 'same-label',
            versionCode: 4294967299,
          ),
        },
      ).single;
      expect(item.pendingPackages, hasLength(1));
    },
  );

  test('imported versions group by actual package while names and signatures stay independent', () {
    DownloadTask imported(String id, String name, String certificate) =>
        DownloadTask(
          id: id,
          appName: '$id.apk',
          url: '',
          filePath: '/fixture/$id.apk',
          kind: 'apk',
          platform: 'Android',
          createdAt: DateTime(2026),
          state: DownloadState.downloaded,
          apkIdentities: {
            DownloadPackage.original: AndroidApkIdentity(
              packageName: name,
              label: 'Example',
              version: id,
              certificates: [certificate],
            ),
          },
        );
    final first = imported('one', 'org.example.app', 'first');
    final second = imported('two', 'org.example.app', 'second');
    manager.tasks.addAll([
      first,
      second,
      imported('other', 'org.example.other', 'third'),
    ]);
    final groups = items();
    expect(groups, hasLength(2));
    final combined = groups.singleWhere(
      (item) => item.id == 'apk:org.example.app',
    );
    expect(combined.name, 'Example');
    expect(combined.files.map((file) => file.task.id), ['one', 'two']);
    final restored = DownloadTask.fromJson(first.toJson());
    expect(restored.apkIdentities[DownloadPackage.original]!.certificates, [
      'first',
    ]);
    expect(restored.libraryPackageName, 'org.example.app');
  });

  test('same-version APK with a different certificate remains pending', () {
    final original = task('signed', resigned: true);
    original.apkIdentities.addAll({
      DownloadPackage.original: const AndroidApkIdentity(
        packageName: 'org.example.app',
        versionCode: 7,
        certificates: ['original'],
      ),
      DownloadPackage.resigned: const AndroidApkIdentity(
        packageName: 'org.example.app',
        versionCode: 7,
        certificates: ['personal'],
      ),
    });
    manager.tasks.add(original);
    final item = items(
      androidPackages: {
        'org.example.app': const AppDownloadStatus(
          installedPackage: 'org.example.app',
          versionCode: 7,
          certificates: ['original'],
        ),
      },
    ).single;
    expect(item.pendingPackages, [
      (task: original, package: DownloadPackage.resigned),
    ]);
  });

  test(
    'a cached detail fallback still reports a failed library update check',
    () async {
      final downloads = DownloadManager(
        Directory.systemTemp,
        installer: LibraryInstaller(),
      );
      final repository = LibraryRepository(refreshFailed: true);
      addTearDown(() {
        downloads.client.close(force: true);
        downloads.macResolver.client.close(force: true);
        downloads.dispose();
        repository.client.close(force: true);
      });
      const fixture = CatalogApp(
        id: 'fixture-0',
        name: 'Fixture 0',
        url: 'https://huarun.win/apps/fixture-0',
        platforms: ['macOS'],
      );
      final result = await readLibraryStatus(
        apps: [fixture],
        repository: repository,
        manager: downloads,
        platform: 'macOS',
        isCurrent: () => true,
        refresh: true,
      );
      expect(result.updateCheckFailed, isTrue);
      expect(result.apps[fixture.key]!.updateCheckFailed, isTrue);
      expect(result.apps[fixture.key]!.details!.version, '2.0');
    },
  );

  test('application grouping preserves independent APKs and file order', () {
    final original = task('first', resigned: true)
      ..originalModifiedAt = DateTime(2026, 10, 18)
      ..resignedModifiedAt = DateTime(2026, 10, 19);
    final derived = task('second', source: 'first', resigned: true)
      ..resignedModifiedAt = DateTime(2026, 10, 20);
    manager.tasks.addAll([original, derived]);
    final item = items().single;
    expect(item.files, [
      (task: derived, package: DownloadPackage.resigned),
      (task: original, package: DownloadPackage.resigned),
      (task: original, package: DownloadPackage.original),
    ]);
    expect(item.modifiedAt, DateTime(2026, 10, 20));
    expect(item.pendingPackages, hasLength(3));
    manager.tasks.remove(original);
    expect(items().single.files.single.task, derived);
    expect(items().single.files.single.package, DownloadPackage.resigned);
  });

  test('system handoff is pending, while foreign packages are downloads', () {
    manager.tasks.add(
      task('windows', platform: 'Windows', state: DownloadState.handedOff),
    );
    final local = items(platform: 'Windows').single;
    expect(local.matches(LibrarySection.installed), isFalse);
    expect(local.matches(LibrarySection.updates), isFalse);
    expect(local.matches(LibrarySection.pending), isTrue);
    final foreign = items().single;
    expect(foreign.matches(LibrarySection.pending), isFalse);
    expect(foreign.matches(LibrarySection.downloads), isTrue);
  });

  test('updates require a confirmed local version and unique identity', () {
    final available = AppDetails(
      app: app,
      platformVersions: {'Android': '2.0'},
    );
    final local = LibraryAppStatus(
      const AppDownloadStatus(
        version: '1.0',
        installedPackage: 'org.example.app',
      ),
      details: available,
    );
    expect(items(statuses: {app.key: local}).single.updateVersion, '2.0');
    expect(
      items(
        statuses: {
          app.key: LibraryAppStatus(
            const AppDownloadStatus(installedPackage: 'org.example.app'),
            details: available,
          ),
        },
      ).single.updateVersion,
      isNull,
    );
    manager.tasks.add(
      task(
        'copy',
        state: DownloadState.installed,
        packageName: 'org.example.app.copy',
      ),
    );
    final ambiguous = items(statuses: {app.key: local}).single;
    expect(ambiguous.installations, hasLength(2));
    expect(ambiguous.updateVersion, isNull);
  });

  test(
    'only installed clients fetch detail HTML with bounded concurrency',
    () async {
      final installer = LibraryInstaller();
      final downloads = DownloadManager(
        Directory.systemTemp,
        installer: installer,
      );
      final repository = LibraryRepository();
      addTearDown(() {
        downloads.client.close(force: true);
        downloads.macResolver.client.close(force: true);
        downloads.dispose();
        repository.client.close(force: true);
      });
      final apps = [
        for (var index = 0; index < 30; index++)
          CatalogApp(
            id: 'fixture-$index',
            name: 'Fixture $index',
            url: 'https://huarun.win/apps/fixture-$index',
            platforms: ['macOS'],
          ),
      ];
      final result = await readLibraryStatus(
        apps: apps,
        repository: repository,
        manager: downloads,
        platform: 'macOS',
        isCurrent: () => true,
      );
      expect(installer.reads, 1);
      expect(
        repository.requested.toSet(),
        apps.take(6).map((app) => app.key).toSet(),
      );
      expect(repository.maximum, lessThanOrEqualTo(4));
      expect(result.apps, hasLength(6));
      expect(result.updateCheckFailed, isFalse);
    },
  );
}
