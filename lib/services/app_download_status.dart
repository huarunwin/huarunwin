import 'dart:io';

import '../data/models.dart';
import 'downloads.dart';
import 'installed_apps.dart';

/// A local application or a completed package, never a system handoff result.
class AppDownloadStatus {
  const AppDownloadStatus({
    this.version,
    this.versionCode,
    this.installedPath,
    this.installedPackage,
    this.certificates = const [],
  });

  final String? version, installedPath, installedPackage;
  final int? versionCode;
  final List<String> certificates;
  bool get canOpenApplication =>
      installedPath != null || installedPackage != null;
}

String appDownloadLabel(CatalogApp app) {
  final price = app.price.trim();
  if (app.priceCategory == '免费' || app.priceCategory == '待核实') return '下载';
  // Keep the published currency and billing period; do not turn an unknown
  // fee or a free download with optional purchases into an invented price.
  final hasAmount = RegExp(
    r'^(?:(?:(?:US|HK|NT|CA|AU|NZ)?\$|[¥￥€£₩₹]|USD|CNY|RMB|EUR|GBP|HKD|TWD|JPY)\s*\d|\d+(?:\.\d+)?\s*(?:元|美元|港元|欧元|人民币))',
    caseSensitive: false,
  ).hasMatch(price);
  return hasAmount ? price : '下载';
}

List<DownloadTask> appDownloadTasks(
  DownloadManager manager,
  CatalogApp app,
  String platform,
) => manager.tasks
    .where(
      (task) =>
          task.platform == platform &&
          task.kind != 'resource' &&
          (task.appKey == app.key ||
              task.appKey == null &&
                  task.url.isNotEmpty &&
                  app.isClient &&
                  task.appName == app.name),
    )
    .toList();

Future<AppDownloadStatus?> readAppDownloadStatus(
  DownloadManager manager,
  CatalogApp app,
  String platform, {
  bool refresh = false,
  Map<String, AppDownloadStatus?>? androidPackages,
}) async {
  if (!app.isClient || app.withdrawn) return null;
  if (platform == 'macOS') {
    try {
      final installed = await manager.installedApps.find(app, refresh: refresh);
      if (installed != null) {
        return AppDownloadStatus(
          version: installed.version,
          installedPath: installed.path,
        );
      }
    } catch (_) {
      // A failed system query must not hide an already downloaded package.
    }
  }

  final downloads = <AppDownloadStatus>[];
  final installed = <String, AppDownloadStatus>{};
  for (final task in appDownloadTasks(manager, app, platform)) {
    if (task.deleting ||
        ![
          DownloadState.downloaded,
          DownloadState.installed,
          DownloadState.handedOff,
          DownloadState.installing,
        ].contains(task.state)) {
      continue;
    }
    final packagePath = task.resignReady
        ? task.installationFilePath
        : task.filePath;
    var packageExists = false;
    try {
      packageExists = await File(packagePath).exists();
    } on FileSystemException {
      // Preserve the download-manager entry so the user can retry its check.
    }
    var version = task.version;
    if (!task.busy && platform == 'Android' && task.kind == 'apk') {
      if (androidPackages != null) {
        for (final name in {
          task.installedPackage,
          for (final package in task.androidPackages) task.packageName(package),
        }) {
          if (androidPackages[name] case final current?) {
            installed[name!] = current;
          }
        }
      }
      try {
        final packageName = task.installedPackage;
        if (androidPackages == null &&
            (packageName != null || packageExists && task.resignReady)) {
          final info = await manager.installer.androidAppStatus(
            packageName: packageName,
            path: packageName == null ? packagePath : null,
          );
          version = info.version ?? version;
          if (info.installedVersionCode != null) {
            installed[info.packageName] = AppDownloadStatus(
              version: info.installedVersion,
              versionCode: info.installedVersionCode,
              installedPackage: info.packageName,
              certificates: info.installedCertificateSha256,
            );
          }
        }
      } catch (_) {
        // Package visibility or metadata errors do not prove installation.
      }
    } else if (!task.busy &&
        platform == 'Linux' &&
        task.kind == 'appimage' &&
        task.state == DownloadState.installed &&
        task.installedPath != null) {
      try {
        if (await File(task.installedPath!).exists()) {
          installed[task.installedPath!] = AppDownloadStatus(
            version: version,
            installedPath: task.installedPath,
          );
        }
      } on FileSystemException {
        // The source package may remain usable even if the app is unavailable.
      }
    }
    if (packageExists) {
      downloads.add(AppDownloadStatus(version: version));
    }
  }
  // Different Android variants can have separate package identities. Do not
  // silently pick which installed application to launch in that case.
  if (installed.length == 1) return installed.values.single;
  if (platform == 'Android' && installed.isEmpty) {
    try {
      // Prefer a package identity read from the APK or installation record.
      // Without one, match a unique real launcher label, never a guessed ID.
      final application = await manager.installedApps.find(
        app,
        platform: platform,
        refresh: refresh,
      );
      if (application != null) {
        return AppDownloadStatus(
          version: application.version.isEmpty ? null : application.version,
          installedPackage: application.packageName,
        );
      }
    } catch (_) {
      // A failed system query must not hide an already downloaded package.
    }
  }
  if (downloads.isEmpty) return null;
  var latest = downloads.first;
  for (final candidate in downloads.skip(1)) {
    if (candidate.version != null &&
        latest.version != null &&
        hasNewerVersion(latest.version!, candidate.version!)) {
      latest = candidate;
    }
  }
  return latest;
}
