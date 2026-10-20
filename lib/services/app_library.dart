import 'package:flutter/foundation.dart';

import '../data/models.dart';
import '../data/repository.dart';
import 'app_download_status.dart';
import 'downloads.dart';
import 'installed_apps.dart';

enum LibrarySection {
  all('全部'),
  updates('可更新'),
  installed('已安装'),
  pending('待安装'),
  downloads('下载任务');

  const LibrarySection(this.label);
  final String label;
}

class LibraryAppStatus {
  const LibraryAppStatus(
    this.local, {
    this.details,
    this.updateCheckFailed = false,
  });
  final AppDownloadStatus local;
  final AppDetails? details;
  final bool updateCheckFailed;
}

class LibraryStatusResult {
  const LibraryStatusResult(
    this.apps, {
    this.updateCheckFailed = false,
    this.androidPackages = const {},
  });
  final Map<String, LibraryAppStatus> apps;
  final bool updateCheckFailed;
  final Map<String, AppDownloadStatus?> androidPackages;
}

/// Check local identities first. Only confirmed local applications need detail
/// HTML, with at most four checks in flight and no release-history prefetch.
Future<LibraryStatusResult> readLibraryStatus({
  required List<CatalogApp> apps,
  required CatalogRepository repository,
  required DownloadManager manager,
  required String? platform,
  required bool Function() isCurrent,
  bool refresh = false,
}) async {
  final candidates = apps
      .where(
        (app) =>
            app.isClient && !app.withdrawn && app.platforms.contains(platform),
      )
      .toList();
  if (candidates.isNotEmpty && ['macOS', 'Android'].contains(platform)) {
    // Share one native snapshot. A failed system query retains the previous
    // library instead of treating every application as uninstalled.
    await manager.installedApps.read();
  }
  final statuses = <String, LibraryAppStatus>{};
  final packages = <String, AppDownloadStatus?>{};
  if (platform == 'Android') {
    final names = {
      for (final task in manager.tasks.where(
        (task) => task.platform == platform && !task.isSelfUpdate,
      )) ...[
        task.installedPackage,
        for (final package in task.androidPackages) task.packageName(package),
      ],
    }..remove(null);
    for (final name in names) {
      if (!isCurrent()) return LibraryStatusResult(statuses);
      // Include known non-launcher packages without querying all system apps.
      final info = await manager.installer.androidAppStatus(packageName: name);
      packages[name!] = info.installedVersionCode == null
          ? null
          : AppDownloadStatus(
              installedPackage: info.packageName,
              version: info.installedVersion,
              versionCode: info.installedVersionCode,
              certificates: info.installedCertificateSha256,
            );
    }
  }
  var next = 0;
  var failed = false;
  Future<void> worker() async {
    while (isCurrent() && next < candidates.length) {
      final app = candidates[next++];
      final local = await readAppDownloadStatus(
        manager,
        app,
        platform!,
        androidPackages: platform == 'Android' ? packages : null,
      );
      if (!isCurrent()) return;
      if (local == null || !local.canOpenApplication) continue;
      AppDetails? details;
      var checkFailed = false;
      if (local.version != null) {
        try {
          final snapshot = await repository.detail(app, refresh: refresh);
          details = snapshot.details;
          failed = failed || snapshot.refreshFailed;
          checkFailed = snapshot.refreshFailed;
        } catch (_) {
          failed = true;
          checkFailed = true;
        }
      }
      if (isCurrent()) {
        statuses[app.key] = LibraryAppStatus(
          local,
          details: details,
          updateCheckFailed: checkFailed,
        );
      }
    }
  }

  await Future.wait([for (var index = 0; index < 4; index++) worker()]);
  return LibraryStatusResult(
    statuses,
    updateCheckFailed: failed,
    androidPackages: packages,
  );
}

class LibraryItem {
  LibraryItem({
    required this.id,
    required this.name,
    required this.platform,
    this.app,
    this.status,
    this.androidPackages = const {},
  });

  final String id, name;
  final String? platform;
  final CatalogApp? app;
  final LibraryAppStatus? status;
  final Map<String, AppDownloadStatus?> androidPackages;
  final List<DownloadEntry> files = [];

  List<DownloadTask> get tasks =>
      files.map((file) => file.task).toSet().toList();
  Set<String> get taskIds => tasks.map((task) => task.id).toSet();
  List<DownloadTask> get activeTasks =>
      tasks.where((task) => task.busy).toList();
  DateTime get modifiedAt => files.isEmpty
      ? DateTime.fromMillisecondsSinceEpoch(0)
      : files.first.task.packageSortTime(
          files.first.package ?? files.first.task.defaultPackage,
        );

  List<AppDownloadStatus> get installations {
    final installed = <String, AppDownloadStatus>{};
    void add(AppDownloadStatus value) {
      final identity = value.installedPackage ?? value.installedPath;
      if (identity != null) installed[identity] = value;
    }

    for (final task in tasks) {
      if (platform == 'Android' &&
          task.platform == platform &&
          !task.isSelfUpdate) {
        for (final package in task.androidPackages) {
          if (androidPackages[task.packageName(package)] case final current?) {
            add(current);
          }
        }
      }
      if (task.platform != platform ||
          task.isSelfUpdate ||
          task.state != DownloadState.installed) {
        continue;
      }
      if (platform == 'Android' &&
          androidPackages.containsKey(task.installedPackage)) {
        if (androidPackages[task.installedPackage] case final current?) {
          add(current);
        }
        continue;
      }
      add(
        AppDownloadStatus(
          installedPackage: task.installedPackage,
          installedPath: task.installedPath,
          // Android and Mac package versions are not the current local version.
          version: platform == 'Linux' ? task.version : null,
        ),
      );
    }
    if (status case final current?) add(current.local);
    return installed.values.toList();
  }

  bool get isInstalled => installations.isNotEmpty;
  String? get updateVersion {
    if (installations.length != 1) return null;
    final local = status?.local.version;
    final detail = status?.details;
    final available = platform == null
        ? null
        : detail?.versionForPlatform(platform!);
    return detail?.app.key == app?.key &&
            detail?.app.withdrawn == false &&
            local != null &&
            available != null &&
            hasNewerVersion(local, available)
        ? available
        : null;
  }

  List<DownloadEntry> get pendingPackages => files.where((file) {
    final task = file.task;
    if (task.isSelfUpdate ||
        task.platform != platform ||
        task.kind == 'resource' ||
        task.busy ||
        task.deleting ||
        ![
          DownloadState.downloaded,
          DownloadState.handedOff,
          DownloadState.installed,
        ].contains(task.state)) {
      return false;
    }
    final available = file.package == null
        ? task.packageAvailable
        : task.hasPackage(file.package!);
    if (!available) return false;
    if (platform == 'Android' && file.package != null) {
      final package = file.package!;
      final name = task.packageName(package);
      final local = androidPackages.containsKey(name)
          ? androidPackages[name]
          : installations
                .where((item) => item.installedPackage == name)
                .firstOrNull;
      // A renamed APK is a separate install target, even at the same version.
      if (local == null) {
        return !(task.state == DownloadState.installed &&
            (task.installedApkPackage ?? task.defaultPackage) == package &&
            (name == null || task.installedPackage == name) &&
            !androidPackages.containsKey(name));
      }
      final identity = task.apkIdentities[package];
      if (identity != null &&
          identity.certificates.isNotEmpty &&
          local.certificates.isNotEmpty &&
          !setEquals(
            identity.certificates.toSet(),
            local.certificates.toSet(),
          )) {
        return true;
      }
      final code = identity?.versionCode;
      if (code != null && local.versionCode != null) {
        return code > local.versionCode!;
      }
      final version = task.packageVersion(package);
      return version != null &&
          local.version != null &&
          hasNewerVersion(local.version!, version);
    }
    if (!isInstalled) return task.state != DownloadState.installed;
    final local = status?.local.version;
    return local != null &&
        task.version != null &&
        hasNewerVersion(local, task.version!);
  }).toList();

  bool get hasPendingPackage => pendingPackages.isNotEmpty;

  bool matches(LibrarySection section) => switch (section) {
    LibrarySection.all => true,
    LibrarySection.updates => updateVersion != null,
    LibrarySection.installed => isInstalled,
    LibrarySection.pending => hasPendingPackage,
    LibrarySection.downloads => files.isNotEmpty,
  };
}

List<LibraryItem> libraryItems({
  required List<CatalogApp> apps,
  required DownloadManager manager,
  required Map<String, LibraryAppStatus> statuses,
  required String? platform,
  Map<String, AppDownloadStatus?> androidPackages = const {},
}) {
  final catalog = {for (final app in apps) app.key: app};
  final byName = <String, List<CatalogApp>>{};
  for (final app in apps.where((app) => app.isClient)) {
    byName.putIfAbsent(app.name, () => []).add(app);
  }
  final tasks = {for (final task in manager.tasks) task.id: task};
  final knownPackages = <String, Set<String>>{};
  if (platform == 'Android') {
    for (final entry in statuses.entries) {
      if (entry.value.local.installedPackage case final name?) {
        knownPackages.putIfAbsent(name, () => {}).add(entry.key);
      }
    }
  }
  for (final task in manager.tasks) {
    final name = task.libraryPackageName;
    final app = catalog[task.appKey];
    if (name != null &&
        app?.isClient == true &&
        task.platform == 'Android' &&
        !task.isSelfUpdate) {
      knownPackages.putIfAbsent(name, () => {}).add(app!.key);
    }
  }
  final groups = <String, LibraryItem>{};
  for (final file in manager.entries) {
    final task = file.task;
    final legacy = task.appKey == null && task.url.isNotEmpty
        ? byName[task.appName]
        : null;
    final packageApp = knownPackages[task.libraryPackageName];
    final app = task.kind == 'resource' || task.isSelfUpdate
        ? null
        : catalog[task.appKey] ??
              (task.platform == 'Android' && packageApp?.length == 1
                  ? catalog[packageApp!.single]
                  : null) ??
              (legacy?.length == 1 ? legacy!.single : null);
    var root = task;
    final visited = <String>{};
    while (visited.add(root.id) && tasks.containsKey(root.sourceTaskId)) {
      root = tasks[root.sourceTaskId]!;
    }
    final id =
        app?.key ??
        (task.isSelfUpdate
            ? 'update:${task.selfUpdateChannel}'
            : task.platform == 'Android' &&
                  task.kind == 'apk' &&
                  task.libraryPackageName != null
            ? 'apk:${task.libraryPackageName}'
            : 'task:${root.id}');
    final item = groups.putIfAbsent(
      id,
      () => LibraryItem(
        id: id,
        name:
            app?.name ??
            task.apkIdentities[DownloadPackage.original]?.label ??
            task.appName,
        app: app,
        platform: platform,
        status: statuses[app?.key],
        androidPackages: androidPackages,
      ),
    );
    item.files.add(file);
  }
  for (final entry in statuses.entries) {
    final app = catalog[entry.key];
    if (app == null) continue;
    groups.putIfAbsent(
      entry.key,
      () => LibraryItem(
        id: entry.key,
        name: app.name,
        app: app,
        platform: platform,
        status: entry.value,
        androidPackages: androidPackages,
      ),
    );
  }
  return groups.values.toList();
}
