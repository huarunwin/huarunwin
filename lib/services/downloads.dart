import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/models.dart';
import 'android_package.dart';
import 'download_locations.dart';
import 'download_foreground.dart';
import 'download_platform.dart';
import 'github_acceleration.dart';
import 'installed_apps.dart';
import 'linux_installer.dart';
import 'mac_downloads.dart';
import 'package_integrity.dart';
import 'resumable_download.dart';

enum DownloadState {
  queued,
  downloading,
  verifying,
  resigning,
  downloaded,
  cancelled,
  failed,
  installing,
  installed,
  handedOff,
}

enum DownloadPackage { original, resigned }

typedef DownloadEntry = ({DownloadTask task, DownloadPackage? package});

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.appName,
    required this.url,
    required this.filePath,
    required this.kind,
    required this.createdAt,
    this.appKey,
    this.selfUpdateChannel,
    this.selfUpdateJob,
    this.platform,
    this.state = DownloadState.queued,
    this.received = 0,
    this.total = 0,
    this.error,
    this.installedPath,
    this.installedPackage,
    this.packageAvailable = true,
    this.sha256,
    this.checksumSource,
    this.version,
    this.releaseUrl,
    this.verifiedSha256,
    this.signingInfo = const {},
    this.androidInstallErrorDetails = const {},
    this.resignKey,
    this.resignPackageName,
    this.originalPackageName,
    this.sourceTaskId,
    this.rootPackageName,
    this.resignedSha256,
    this.originalAvailable = true,
    this.androidOperationPackage,
    this.installedApkPackage,
    this.removedPackages = const {},
    this.originalModifiedAt,
    this.resignedModifiedAt,
    Map<DownloadPackage, AndroidApkIdentity>? apkIdentities,
  }) : apkIdentities = Map.of(apkIdentities ?? const {});
  final String id, appName, url, filePath, kind;
  final String? appKey;
  final String? platform;
  final String? sha256, checksumSource;
  final String? version, releaseUrl;
  AndroidSigningKey? resignKey;
  String? resignPackageName, originalPackageName;
  // Derived tasks keep a private input snapshot for retry, without listing it
  // again as an original APK. The visible source task is never overwritten.
  final String? sourceTaskId, rootPackageName;
  bool get isDerivedApk => sourceTaskId != null;
  String? get resignedPackageName => resignPackageName ?? originalPackageName;
  bool isRenamedPackage(DownloadPackage package) {
    if (package == DownloadPackage.original) return false;
    final outputName = resignedPackageName;
    final rootName = rootPackageName ?? originalPackageName;
    return outputName != null && rootName != null
        ? outputName != rootName
        : resignPackageName != null;
  }

  String packageLabel(DownloadPackage package) =>
      package == DownloadPackage.original
      ? '原始包'
      : isRenamedPackage(package)
      ? '改包重签'
      : '重签包';
  String? resignedSha256;
  bool originalAvailable;
  DownloadPackage? androidOperationPackage;
  DownloadPackage? installedApkPackage, androidCheckingPackage;
  Set<DownloadPackage> removedPackages;
  DateTime? originalModifiedAt, resignedModifiedAt;
  final Map<DownloadPackage, AndroidApkIdentity> apkIdentities;
  final _apkDetails =
      <
        DownloadPackage,
        ({
          AndroidApkDetails details,
          String path,
          String? sha256,
          DateTime modifiedAt,
        })
      >{};
  String? packageName(DownloadPackage package) =>
      apkIdentities[package]?.packageName ??
      (package == DownloadPackage.original
          ? originalPackageName
          : resignedPackageName);
  String? packageVersion(DownloadPackage package) =>
      apkIdentities[package]?.version ?? version;
  String? get libraryPackageName =>
      rootPackageName ?? packageName(DownloadPackage.original);
  DateTime packageSortTime(DownloadPackage package) =>
      (package == DownloadPackage.original
          ? originalModifiedAt
          : resignedModifiedAt) ??
      createdAt;
  DownloadPackage get defaultPackage =>
      wantsResign ? DownloadPackage.resigned : DownloadPackage.original;
  DownloadPackage get operationPackage =>
      androidOperationPackage ??
      (wantsResign &&
              !originalAvailable &&
              [
                DownloadState.queued,
                DownloadState.downloading,
                DownloadState.verifying,
                DownloadState.failed,
                DownloadState.cancelled,
              ].contains(state)
          ? DownloadPackage.original
          : defaultPackage);
  String packagePath(DownloadPackage package) =>
      package == DownloadPackage.original ? filePath : resignedFilePath;
  bool hasPackage(DownloadPackage package) =>
      !removedPackages.contains(package) &&
      (package == DownloadPackage.original
          ? originalAvailable && (wantsResign || packageAvailable)
          : wantsResign && resignedSha256 != null && packageAvailable);
  Iterable<DownloadPackage> get androidPackages => [
    if (!isDerivedApk && !removedPackages.contains(DownloadPackage.original))
      DownloadPackage.original,
    if (wantsResign && !removedPackages.contains(DownloadPackage.resigned))
      DownloadPackage.resigned,
  ];
  bool canInstallPackageOn(String? running, DownloadPackage package) =>
      running == 'Android' &&
      platform == running &&
      kind == 'apk' &&
      !busy &&
      !deleting &&
      hasPackage(package);
  bool get wantsResign => resignKey != null;
  bool _legacyResignedPath = false;
  String get resignedFilePath => _legacyResignedPath
      ? p.join(p.dirname(filePath), 'resigned', p.basename(filePath))
      : p.join(
          p.dirname(filePath),
          '${p.basenameWithoutExtension(filePath)}-huarun-sign.apk',
        );
  String _resignedDirectory(String originalParent) =>
      _legacyResignedPath ? p.join(originalParent, 'resigned') : originalParent;
  String get installationFilePath => wantsResign ? resignedFilePath : filePath;
  bool get resignReady => !wantsResign || resignedSha256 != null;
  String? verifiedSha256, installPhase;
  Map<String, String> signingInfo;
  Map<String, String> androidInstallErrorDetails;
  final DateTime createdAt;
  DownloadState state;
  int received, total;
  String? error, installedPath, installedPackage;
  CancelToken? cancelToken;
  bool deleting = false;
  bool checking = false;
  String? _androidInspectionSha256;
  DownloadPackage? _androidInspectionPackage;
  bool packageAvailable;
  int _operation = 0;
  double? get progress => total > 0 ? (received / total).clamp(0, 1) : null;
  final String? selfUpdateChannel;
  String? selfUpdateJob;
  bool get isSelfUpdate => selfUpdateChannel != null;
  bool get busy =>
      checking ||
      [
        DownloadState.queued,
        DownloadState.downloading,
        DownloadState.verifying,
        DownloadState.resigning,
        DownloadState.installing,
      ].contains(state);
  bool get canInstall => canInstallOn(
    Platform.isMacOS
        ? 'macOS'
        : Platform.isAndroid
        ? 'Android'
        : Platform.isLinux
        ? 'Linux'
        : null,
  );
  bool canInstallOn(String? running) => isSelfUpdate
      ? platform == running &&
            packageAvailable &&
            !busy &&
            [DownloadState.downloaded, DownloadState.handedOff].contains(state)
      : packageAvailable &&
            resignReady &&
            !checking &&
            platform == running &&
            (running == 'macOS' &&
                    [
                      DownloadState.downloaded,
                      DownloadState.handedOff,
                    ].contains(state) &&
                    ['dmg', 'zip'].contains(kind) ||
                running == 'Android' &&
                    [
                      DownloadState.downloaded,
                      DownloadState.handedOff,
                    ].contains(state) &&
                    kind == 'apk' ||
                running == 'Linux' &&
                    [
                      DownloadState.downloaded,
                      DownloadState.handedOff,
                    ].contains(state) &&
                    kind == 'appimage');
  bool get canHandOff =>
      packageAvailable &&
      resignReady &&
      !checking &&
      (platform == 'macOS' && ['dmg', 'zip', 'pkg'].contains(kind) ||
          platform == 'Android' && kind == 'apk' ||
          platform == 'Windows' &&
              ['exe', 'msi', 'msix', 'zip'].contains(kind) ||
          platform == 'Linux' &&
              ['deb', 'rpm', 'pkg.tar.zst', 'zip'].contains(kind)) &&
      [DownloadState.downloaded, DownloadState.handedOff].contains(state);
  bool get checksumVerified => sha256 != null && sha256 == verifiedSha256;
  Map<String, dynamic> toJson() => {
    'id': id,
    'appName': appName,
    'appKey': appKey,
    'selfUpdateChannel': selfUpdateChannel,
    'selfUpdateJob': selfUpdateJob,
    'url': url,
    'filePath': filePath,
    'kind': kind,
    'platform': platform,
    'createdAt': createdAt.toIso8601String(),
    'state': state.name,
    'received': received,
    'total': total,
    'installedPath': installedPath,
    'installedPackage': installedPackage,
    'error': error,
    'packageAvailable': packageAvailable,
    'sha256': sha256,
    'checksumSource': checksumSource,
    'version': version,
    'releaseUrl': releaseUrl,
    'verifiedSha256': verifiedSha256,
    'signingInfo': signingInfo,
    'androidInstallErrorDetails': androidInstallErrorDetails,
    'resignKey': resignKey?.toJson(),
    'resignPackageName': resignPackageName,
    'originalPackageName': originalPackageName,
    'sourceTaskId': sourceTaskId,
    'rootPackageName': rootPackageName,
    'apkIdentities': {
      for (final entry in apkIdentities.entries)
        entry.key.name: entry.value.toJson(),
    },
    'resignedSha256': resignedSha256,
    'resignedFileLayout': _legacyResignedPath ? 'subdirectory' : 'sibling',
    'originalAvailable': originalAvailable,
    'androidOperationPackage': androidOperationPackage?.name,
    'installedApkPackage': installedApkPackage?.name,
    'removedPackages': removedPackages.map((package) => package.name).toList(),
    'originalModifiedAt': originalModifiedAt?.toUtc().toIso8601String(),
    'resignedModifiedAt': resignedModifiedAt?.toUtc().toIso8601String(),
  };
  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final task = DownloadTask(
      id: json['id'] as String,
      appName: json['appName'] as String,
      appKey: json['appKey'] as String?,
      selfUpdateChannel: json['selfUpdateChannel'] as String?,
      selfUpdateJob: json['selfUpdateJob'] as String?,
      url: json['url'] as String,
      filePath: json['filePath'] as String,
      kind: json['kind'] as String,
      platform: json['platform'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      state: DownloadState.values.byName(json['state'] as String),
      received: json['received'] as int? ?? 0,
      total: json['total'] as int? ?? 0,
      installedPath: json['installedPath'] as String?,
      installedPackage: json['installedPackage'] as String?,
      error: json['error'] as String?,
      packageAvailable:
          json['packageAvailable'] as bool? ?? json['error'] != '下载文件已被移动或删除。',
      sha256: normalizeSha256(json['sha256'] as String?),
      checksumSource: json['checksumSource'] as String?,
      version: json['version'] as String?,
      releaseUrl: json['releaseUrl'] as String?,
      verifiedSha256: normalizeSha256(json['verifiedSha256'] as String?),
      signingInfo: Map<String, String>.from(
        json['signingInfo'] as Map? ?? const {},
      ),
      androidInstallErrorDetails: Map<String, String>.from(
        json['androidInstallErrorDetails'] as Map? ?? const {},
      ),
      resignKey:
          json['resignKey'] is Map &&
              json['platform'] == 'Android' &&
              json['kind'] == 'apk'
          ? AndroidSigningKey.fromMap(json['resignKey'] as Map)
          : null,
      resignedSha256: normalizeSha256(json['resignedSha256'] as String?),
      resignPackageName: json['resignPackageName'] as String?,
      originalPackageName: json['originalPackageName'] as String?,
      sourceTaskId: json['sourceTaskId'] as String?,
      rootPackageName: json['rootPackageName'] as String?,
      apkIdentities: {
        for (final package in DownloadPackage.values)
          if ((json['apkIdentities'] as Map?)?[package.name]
              case final Map value)
            package: AndroidApkIdentity.fromMap(value),
      },
      originalAvailable: json['originalAvailable'] as bool? ?? true,
      originalModifiedAt: DateTime.tryParse(
        json['originalModifiedAt'] as String? ?? '',
      ),
      resignedModifiedAt: DateTime.tryParse(
        json['resignedModifiedAt'] as String? ?? '',
      ),
      androidOperationPackage: DownloadPackage.values
          .where((package) => package.name == json['androidOperationPackage'])
          .firstOrNull,
      installedApkPackage: DownloadPackage.values
          .where((package) => package.name == json['installedApkPackage'])
          .firstOrNull,
      removedPackages: {
        for (final package in DownloadPackage.values)
          if ((json['removedPackages'] as List?)?.contains(package.name) ==
              true)
            package,
      },
    );
    task._legacyResignedPath =
        task.wantsResign && json['resignedFileLayout'] != 'sibling';
    if (json['removedPackages'] == null && task.wantsResign) {
      // Older histories only recorded availability after selective deletion.
      if (!task.originalAvailable &&
          task.packageAvailable &&
          task.resignReady) {
        task.removedPackages.add(DownloadPackage.original);
      } else if (task.originalAvailable &&
          !task.packageAvailable &&
          task.resignedSha256 != null) {
        task.removedPackages.add(DownloadPackage.resigned);
      }
    }
    return task;
  }
}

class NativeInstaller {
  NativeInstaller({LinuxInstaller? linuxInstaller})
    : linux = linuxInstaller ?? LinuxInstaller();
  final LinuxInstaller linux;
  static const channel = MethodChannel('win.huarun/installer');
  static final _progressListeners =
      <
        Object,
        ({String package, void Function(Map<String, String>) callback})
      >{};

  static Future<void> _progress(MethodCall call) async {
    if (call.method != 'installProgress' || call.arguments is! Map) return;
    final event = <String, String>{
      for (final entry in (call.arguments as Map).entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
    for (final listener in List.of(_progressListeners.values)) {
      if (listener.package == event['package']) listener.callback(event);
    }
  }

  Future<List<InstalledApplication>> installedApplications() async {
    if (Platform.isLinux) return linux.installedApplications();
    final result = await channel.invokeListMethod<Object?>(
      'installedApplications',
    );
    return [
      for (final item in result ?? const [])
        InstalledApplication.fromMap(Map<Object?, Object?>.from(item as Map)),
    ];
  }

  Future<String?> architecture() async => Platform.isLinux
      ? (await linux.systemInfo()).architecture
      : channel.invokeMethod<String>('architecture');
  Future<LinuxSystemInfo> linuxSystemInfo() => linux.systemInfo();
  Future<String> installAppImage(String path, {String? expectedSha256}) =>
      linux.installAppImage(path, expectedSha256: expectedSha256);
  Future<void> openLinuxPackage(String path) => linux.openPackage(path);
  Future<void> openAppImage(String path) => linux.openAppImage(path);
  Future<void> revealLinux(String path) => linux.reveal(path);
  Future<String> install(
    String package, {
    required bool removeQuarantine,
    bool authorize = false,
    Map<String, String>? quitApplication,
    Map<String, String>? signerApproval,
    void Function(Map<String, String>)? onProgress,
  }) async {
    final token = Object();
    if (onProgress != null) {
      _progressListeners[token] = (package: package, callback: onProgress);
      channel.setMethodCallHandler(_progress);
    }
    try {
      final result = await channel.invokeMethod<String>('install', {
        'package': package,
        'removeQuarantine': removeQuarantine,
        'authorize': authorize,
        'quitApplication': ?quitApplication,
        'signerApproval': ?signerApproval,
      });
      if (result == null) {
        throw PlatformException(code: 'installation', message: '安装未返回结果。');
      }
      return result;
    } finally {
      _progressListeners.remove(token);
    }
  }

  Future<void> openPackage(String file, {String? expectedSha256}) async {
    final opened = await channel.invokeMethod<bool>('openPackage', {
      'path': file,
      'expectedSha256': ?expectedSha256,
    });
    if (opened != true) {
      throw PlatformException(
        code: 'open_package',
        message: '无法打开安装包，请使用“查看文件”手动打开。',
      );
    }
  }

  Future<void> reveal(String file) async =>
      channel.invokeMethod<void>('reveal', {'path': file});
  Future<void> openApp(String file) async =>
      channel.invokeMethod<void>('openApp', {'path': file});

  Future<String> installApk(
    String file, {
    String? expectedSha256,
    AndroidInstallMethod method = AndroidInstallMethod.huarun,
    void Function(Map<String, String>)? onProgress,
  }) async {
    final token = Object();
    if (onProgress != null) {
      _progressListeners[token] = (package: file, callback: onProgress);
      channel.setMethodCallHandler(_progress);
    }
    try {
      final result = await channel.invokeMethod<String>('installApk', {
        'path': file,
        'expectedSha256': ?expectedSha256,
        if (method != AndroidInstallMethod.huarun) 'method': method.name,
      });
      if (result == null || result.isEmpty) {
        throw PlatformException(code: 'installation', message: '安装未返回结果。');
      }
      return result;
    } finally {
      _progressListeners.remove(token);
    }
  }

  Future<AndroidPackageInfo> inspectApk(String file) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'inspectApk',
      {'path': file},
    );
    if (result == null || result['packageName'] is! String) {
      throw PlatformException(code: 'package', message: '无法读取 APK 信息。');
    }
    return AndroidPackageInfo.fromMap(result);
  }

  Future<AndroidApkIdentity> apkIdentity(String file) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'apkIdentity',
      {'path': file},
    );
    if (result == null) throw const FormatException('无法读取 APK 信息。');
    return AndroidApkIdentity.fromMap(result);
  }

  Future<List<AndroidSigningKey>> apkSigningKeys() async => [
    for (final value
        in await channel.invokeListMethod<Object?>('apkSigningKeys') ??
            const [])
      AndroidSigningKey.fromMap(value as Map),
  ];

  Future<AndroidSigningKey> createApkSigningKey() async =>
      AndroidSigningKey.fromMap(
        (await channel.invokeMapMethod<Object?, Object?>(
          'createApkSigningKey',
        ))!,
      );

  Future<({AndroidSigningKey key, bool created})> resolveApkSigningKey({
    AndroidSigningKey? selected,
  }) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'resolveApkSigningKey',
      {
        if (selected != null) ...{
          'keyId': selected.id,
          'expectedCertificateSha256': selected.certificateSha256,
        },
      },
    );
    if (result == null) {
      throw PlatformException(code: 'signing_key', message: '无法取得签名密钥，请重试。');
    }
    return (
      key: AndroidSigningKey.fromMap(result),
      created: result['created'] == true,
    );
  }

  Future<AndroidSigningKey?> exportApkSigningKey(
    AndroidSigningKey key, {
    required String password,
  }) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'exportApkSigningKey',
      {
        'keyId': key.id,
        'expectedCertificateSha256': key.certificateSha256,
        'password': password,
      },
    );
    return result == null ? null : AndroidSigningKey.fromMap(result);
  }

  Future<AndroidSigningKey?> importApkSigningKey({
    required String password,
  }) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'importApkSigningKey',
      {'password': password},
    );
    return result == null ? null : AndroidSigningKey.fromMap(result);
  }

  Future<AndroidResignResult> resignApk(
    String file, {
    required AndroidSigningKey key,
    required String expectedSourceSha256,
    String? packageName,
  }) async => AndroidResignResult.fromMap(
    (await channel.invokeMapMethod<Object?, Object?>('resignApk', {
      'path': file,
      'keyId': key.id,
      'expectedSourceSha256': expectedSourceSha256,
      'expectedCertificateSha256': key.certificateSha256,
      'packageName': ?packageName,
    }))!,
  );

  Future<bool> isAndroidPackageInstalled(String packageName) async {
    final result = await channel.invokeMethod<bool>('isPackageInstalled', {
      'packageName': packageName,
    });
    if (result == null) {
      throw PlatformException(code: 'package_status', message: '无法检查应用安装状态。');
    }
    return result;
  }

  Future<AndroidPackageInfo> androidAppStatus({
    String? packageName,
    String? path,
  }) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'androidAppStatus',
      {'packageName': ?packageName, 'path': ?path},
    );
    if (result == null || result['packageName'] is! String) {
      throw PlatformException(code: 'package_status', message: '无法读取应用版本。');
    }
    return AndroidPackageInfo.fromMap(result);
  }

  Future<void> openAndroidApp(String packageName) async => channel
      .invokeMethod<void>('openAndroidApp', {'packageName': packageName});

  /// Returns when the system UI closes, without implying uninstallation.
  Future<void> uninstallAndroidApp(String packageName) async => channel
      .invokeMethod<void>('uninstallAndroidApp', {'packageName': packageName});

  Future<void> uninstallApplication(
    InstalledApplication application, {
    Map<String, String>? authorizationTarget,
  }) async {
    if (Platform.isLinux) {
      if (application.path.isNotEmpty) {
        await linux.uninstallAppImage(application.path);
      } else {
        await linux.uninstallPackage(
          application.uninstallId!,
          application.version,
        );
      }
      return;
    }
    await channel.invokeMethod<void>('uninstallApplication', {
      'path': application.path,
      'bundleIdentifier': application.bundleIdentifier,
      'uninstallId': application.uninstallId,
      'version': application.version,
      'name': application.names.firstOrNull ?? '',
      'authorizationTarget': ?authorizationTarget,
    });
  }

  Future<void> openApplicationSettings() =>
      channel.invokeMethod<void>('openApplicationSettings');
}

class DownloadManager extends ChangeNotifier {
  DownloadManager(
    this.directory, {
    Dio? client,
    NativeInstaller? installer,
    MacDownloadResolver? macResolver,
    this.maxConcurrentDownloads = 3,
    this.writeHistory,
    this.locations,
    this.foreground,
    this.github,
    bool? readAndroidMetadata,
  }) : assert(maxConcurrentDownloads > 0),
       readAndroidMetadata = readAndroidMetadata ?? Platform.isAndroid,
       client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               receiveTimeout: const Duration(seconds: 60),
             ),
           ),
       installer = installer ?? NativeInstaller(),
       macResolver = macResolver ?? MacDownloadResolver() {
    locations?.addListener(notifyListeners);
    foreground?.onStopped = (reason) {
      downloadWarning = reason;
      for (final task in List.of(tasks)) {
        if (task.cancelToken != null) cancel(task);
      }
      notifyListeners();
    };
  }
  // The original directory remains the fixed home for tasks.json and Android
  // private files. Desktop package locations can change independently.
  final Directory directory;
  final DownloadLocations? locations;
  final AndroidDownloadForeground? foreground;
  final GitHubAcceleration? github;
  String? downloadWarning;
  Map<String, Object> get _foregroundProgress {
    final active = tasks
        .where(
          (task) => [
            DownloadState.queued,
            DownloadState.downloading,
            DownloadState.verifying,
            DownloadState.resigning,
          ].contains(task.state),
        )
        .toList();
    return {
      'count': active.length,
      'name': active.firstOrNull?.appName ?? '下载应用',
      'received': active.fold<int>(0, (sum, task) => sum + task.received),
      'total': active.every((task) => task.total > 0)
          ? active.fold<int>(0, (sum, task) => sum + task.total)
          : 0,
    };
  }

  Directory get downloadDirectory => locations?.directory ?? directory;
  final Dio client;
  final NativeInstaller installer;
  final MacDownloadResolver macResolver;
  final int maxConcurrentDownloads;
  final bool readAndroidMetadata;
  final Future<void> Function(String snapshot)? writeHistory;
  final List<_QueuedDownload> _queued = [];
  int _activeDownloads = 0;
  late final installedApps = InstalledApplications(
    installer.installedApplications,
  );
  final Map<String, Future<void>> _running = {};
  final List<DownloadTask> tasks = [];
  List<DownloadEntry> get entries {
    final entries = <DownloadEntry>[
      for (final task in tasks)
        if (task.platform == 'Android' && task.kind == 'apk')
          for (final package in task.androidPackages)
            (task: task, package: package)
        else
          (task: task, package: null),
    ];
    final positions = {
      for (var index = 0; index < entries.length; index++)
        entries[index]: index,
    };
    entries.sort((a, b) {
      final order = b.task
          .packageSortTime(b.package ?? b.task.defaultPackage)
          .compareTo(
            a.task.packageSortTime(a.package ?? a.task.defaultPackage),
          );
      return order != 0 ? order : positions[a]!.compareTo(positions[b]!);
    });
    return entries;
  }

  Future<void> _persistence = Future.value();
  Object? _historyError;
  Future<void>? _restoring;
  bool _restored = false;
  bool _historyReadFailed = false;
  bool _historyRecovered = false;
  bool _restoreCheckFailed = false;
  List<int>? _pendingHistoryBackup;
  String? get historyWarning => _historyReadFailed
      ? '暂时无法读取下载历史，原记录已保留，请刷新重试。'
      : _pendingHistoryBackup != null
      ? '部分下载记录损坏，原历史尚未完成备份，已暂停保存，请刷新重试。'
      : _historyError != null
      ? '下载记录尚未保存，请刷新重试。'
      : _restoreCheckFailed
      ? '部分文件暂时无法检查，已保留记录，请刷新重试。'
      : _historyRecovered
      ? '部分下载记录无法读取，完整原历史已在本机单独备份，其他记录已恢复。'
      : null;
  Future<void>? _refreshing;
  bool get refreshing => _refreshing != null;
  int apkMetadataRevision = 0;
  static const maxBytes = 4 * 1024 * 1024 * 1024;
  File get _index => File(p.join(directory.path, 'tasks.json'));

  Future<void> flushHistory() => _persistence;

  @override
  void dispose() {
    foreground?.dispose();
    locations?.removeListener(notifyListeners);
    installedApps.dispose();
    super.dispose();
  }

  Future<void> restore() {
    if (_restored) return Future.value();
    return _restoring ??= _restore().whenComplete(() => _restoring = null);
  }

  Future<void> _restore() async {
    await directory.create(recursive: true);
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    var modifiedTimesChanged = false;
    List<int> original;
    try {
      original = await _index.readAsBytes();
      _historyReadFailed = false;
    } on FileSystemException catch (error) {
      final missingCodes = Platform.isWindows ? [2, 3] : [2, 20];
      _historyReadFailed = !missingCodes.contains(error.osError?.errorCode);
      _restored = !_historyReadFailed;
      notifyListeners();
      return;
    }
    List<Object?> saved;
    try {
      final decoded = jsonDecode(utf8.decode(original));
      if (decoded is! List) throw const FormatException('下载历史不是列表。');
      saved = decoded;
    } on FormatException {
      _pendingHistoryBackup = original;
      _historyRecovered = true;
      _restored = true;
      _emit();
      return;
    }
    var invalidItems = false;
    final savedIds = <String>{};
    for (final item in saved) {
      DownloadTask task;
      try {
        if (item is! Map) throw const FormatException('下载记录格式无效。');
        task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
        // Android exposes app files through both /data/user/0 and /data/data.
        // Derived snapshots use the canonical root, while path_provider may
        // return its alias. Both are managed paths and must survive a restart.
        if ((!p.isWithin(directory.path, task.filePath) &&
                !p.isWithin(canonicalDirectory, task.filePath) &&
                locations?.managedRoot(task.filePath) == null) ||
            !savedIds.add(task.id)) {
          throw const FormatException('下载记录的路径或标识无效。');
        }
      } catch (_) {
        // Only decoding failures belong to recovery. Temporary file access
        // failures below must never discard an otherwise valid record.
        invalidItems = true;
        continue;
      }
      if (tasks.any((existing) => existing.id == task.id)) continue;
      tasks.add(task);
      final previousState = task.state;
      final interrupted = task.busy;
      final operationPackage = task.operationPackage;
      if (interrupted) {
        if (task.platform == 'Android' && task.kind == 'apk') {
          task.androidOperationPackage = operationPackage;
        }
        task.state = DownloadState.cancelled;
        task.error = '上次下载或安装已中断，请重试。';
        modifiedTimesChanged = true;
      }
      try {
        if (task.wantsResign) {
          task.originalAvailable = await _pathExists(
            task.filePath,
            FileSystemEntityType.file,
          );
        }
        if (interrupted) {
          task.state =
              (previousState == DownloadState.resigning &&
                      task.originalAvailable) ||
                  previousState == DownloadState.installing &&
                      [
                        'Android',
                        'macOS',
                        'Windows',
                        'Linux',
                      ].contains(task.platform) &&
                      await _pathExists(
                        task.platform == 'Android'
                            ? task.packagePath(operationPackage)
                            : task.installationFilePath,
                        FileSystemEntityType.file,
                      )
              ? DownloadState.downloaded
              : DownloadState.cancelled;
          task.error = task.state == DownloadState.downloaded
              ? task.wantsResign &&
                        !task.resignReady &&
                        task.operationPackage == DownloadPackage.resigned
                    ? '上次重签已中断，原始 APK 已保留，可以重试重签。'
                    : '上次安装已中断，结果尚未确认。安装包已保留，可以重试安装。'
              : '上次下载或安装已中断，请重试。';
        }
        if (task.state == DownloadState.downloaded &&
            !await _pathExists(
              task.resignReady ? task.installationFilePath : task.filePath,
              FileSystemEntityType.file,
            )) {
          task.packageAvailable = false;
          if (task.platform != 'Android' ||
              !task.wantsResign ||
              task.operationPackage != DownloadPackage.original ||
              !task.originalAvailable) {
            task.state = DownloadState.failed;
            task.error = '下载文件已被移动或删除。';
          }
        }
        if (task.isSelfUpdate && await _refreshSelfUpdate(task)) {
          modifiedTimesChanged = true;
        }
        for (final package in DownloadPackage.values) {
          if (await _updatePackageModifiedTime(task, package)) {
            modifiedTimesChanged = true;
          }
        }
      } on FileSystemException {
        _restoreCheckFailed = true;
      }
    }
    _restored = true;
    if (invalidItems) {
      _pendingHistoryBackup = original;
      _historyRecovered = true;
    }
    if (modifiedTimesChanged || invalidItems || _historyError != null) {
      _emit();
    } else {
      notifyListeners();
    }
  }

  Future<void> _preserveHistory() async {
    if (_historyReadFailed) {
      throw const FileSystemException('下载历史尚未读取，暂不覆盖原记录。');
    }
    final original = _pendingHistoryBackup;
    if (original == null) return;
    final recovery = await Directory(p.join(directory.path, 'history-recovery'))
        .create(recursive: true);
    final folder = await recovery.createTemp('recovery-');
    await File(p.join(folder.path, 'tasks.json'))
        .writeAsBytes(original, flush: true);
    _pendingHistoryBackup = null;
  }

  Future<void> refresh() {
    final pending = _refreshing;
    if (pending != null) return pending;
    if (Platform.isAndroid) installedApps.invalidate();
    final future =
        (() async {
          if (_historyReadFailed) await restore();
          if (_pendingHistoryBackup != null || _historyError != null) {
            _emit();
            await flushHistory();
          }
          await _refreshTasks();
          await _refreshPackageModifiedTimes();
          await _refreshApkIdentities();
          _restoreCheckFailed = false;
        })().whenComplete(() {
          _refreshing = null;
          apkMetadataRevision++;
          notifyListeners();
        });
    _refreshing = future;
    notifyListeners();
    return future;
  }

  Future<bool> _updatePackageModifiedTime(
    DownloadTask task,
    DownloadPackage package, {
    bool allowBusy = false,
  }) async {
    if (task.deleting ||
        !allowBusy && task.busy ||
        task.removedPackages.contains(package) ||
        package == DownloadPackage.resigned && !task.wantsResign) {
      return false;
    }
    final operation = task._operation;
    final path = task.packagePath(package);
    try {
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file ||
          !tasks.contains(task) ||
          task._operation != operation ||
          task.deleting ||
          !allowBusy && task.busy ||
          task.packagePath(package) != path) {
        return false;
      }
      final modified = stat.modified.toUtc();
      if (package == DownloadPackage.original) {
        if (task.originalModifiedAt == modified) return false;
        task.originalModifiedAt = modified;
      } else {
        if (task.resignedModifiedAt == modified) return false;
        task.resignedModifiedAt = modified;
      }
      return true;
    } on FileSystemException {
      // Preserve the last observed timestamp when the file cannot be read.
      return false;
    }
  }

  Future<void> _refreshPackageModifiedTimes() async {
    var changed = false;
    for (final task in List.of(tasks)) {
      for (final package in DownloadPackage.values) {
        if (await _updatePackageModifiedTime(task, package)) changed = true;
      }
    }
    if (changed) _emit();
  }

  Future<bool> _readApkIdentity(
    DownloadTask task,
    DownloadPackage package, {
    bool allowBusy = false,
  }) async {
    if (!readAndroidMetadata ||
        task.platform != 'Android' ||
        task.kind != 'apk' ||
        task.deleting ||
        !allowBusy && task.busy ||
        !task.hasPackage(package)) {
      return false;
    }
    final operation = task._operation;
    final file = File(task.packagePath(package));
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file) return false;
    final identity = await installer.apkIdentity(file.path);
    final after = await file.stat();
    if (!tasks.contains(task) ||
        task.deleting ||
        task._operation != operation ||
        !allowBusy && task.busy ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed) {
      return false;
    }
    _cacheApkDetails(
      task,
      package,
      AndroidApkDetails(
        info: AndroidPackageInfo.fromMap(identity.toJson()),
        bytes: after.size,
      ),
      after,
    );
    if (jsonEncode(task.apkIdentities[package]?.toJson()) ==
        jsonEncode(identity.toJson())) {
      return false;
    }
    task.apkIdentities[package] = identity;
    if (package == DownloadPackage.original) {
      task.originalPackageName = identity.packageName;
    }
    apkMetadataRevision++;
    return true;
  }

  Future<void> _refreshApkIdentities() async {
    if (!readAndroidMetadata) return;
    var changed = false;
    Object? failure;
    for (final file in List.of(entries)) {
      if (file.package == null) continue;
      try {
        changed = await _readApkIdentity(file.task, file.package!) || changed;
      } catch (error) {
        failure ??= error;
      }
    }
    if (changed) _emit();
    if (failure != null) throw const FileSystemException('部分 APK 信息未能读取，请重试。');
  }

  Future<void> _captureApkIdentity(
    DownloadTask task,
    DownloadPackage package,
  ) async {
    try {
      await _readApkIdentity(task, package, allowBusy: true);
    } catch (_) {
      // Metadata failure does not discard a downloaded file. Refresh retries,
      // and the independent install inspection remains mandatory.
    }
  }

  Future<void> _refreshTasks() async {
    var changed = false;
    Exception? failure;
    for (final task in List.of(tasks)) {
      if (task.busy || task.deleting) continue;
      if (task.isSelfUpdate) {
        changed = await _refreshSelfUpdate(task) || changed;
        continue;
      }
      final state = task.state;
      if (state != DownloadState.downloaded &&
          state != DownloadState.installed &&
          state != DownloadState.handedOff &&
          !(state == DownloadState.failed && !task.packageAvailable)) {
        continue;
      }
      final operation = task._operation;
      final installedPath = task.installedPath;
      final installedPackage = task.installedPackage;
      final error = task.error;
      try {
        final packageAvailable = await _pathExists(
          task.resignReady ? task.installationFilePath : task.filePath,
          FileSystemEntityType.file,
        );
        final originalAvailable = task.wantsResign
            ? await _pathExists(task.filePath, FileSystemEntityType.file)
            : packageAvailable;
        final appAvailable =
            state == DownloadState.installed &&
            (task.platform == 'Android'
                ? installedPackage != null &&
                      await installer.isAndroidPackageInstalled(
                        installedPackage,
                      )
                : installedPath != null &&
                      await _pathExists(
                        installedPath,
                        task.platform == 'Linux'
                            ? FileSystemEntityType.file
                            : FileSystemEntityType.directory,
                      ));
        // A download, installation or deletion may finish during the checks.
        if (!tasks.contains(task) ||
            task.deleting ||
            task._operation != operation ||
            task.state != state ||
            task.installedPath != installedPath ||
            task.installedPackage != installedPackage ||
            task.error != error) {
          continue;
        }
        final nextState = appAvailable
            ? DownloadState.installed
            : packageAvailable
            ? state == DownloadState.handedOff
                  ? DownloadState.handedOff
                  : DownloadState.downloaded
            : DownloadState.failed;
        final nextPath = appAvailable ? installedPath : null;
        final nextPackage = appAvailable ? installedPackage : null;
        var nextError = error;
        var nextOperationPackage = task.androidOperationPackage;
        if (state == DownloadState.installed && !appAvailable) {
          nextError = task.platform == 'Android'
              ? packageAvailable || originalAvailable
                    ? '应用已卸载，可以重新安装。'
                    : '应用已卸载且安装包已丢失，请重新下载。'
              : packageAvailable
              ? '已安装的应用已被移动或删除，可以重新安装。'
              : '应用和安装包已被移动或删除，请重新下载或导入。';
        } else if (!packageAvailable && !appAvailable) {
          nextError ??= '下载文件已被移动或删除。';
          if (error == null && task.platform == 'Android') {
            nextOperationPackage = task.defaultPackage;
          }
        } else if (state == DownloadState.failed) {
          nextError = null;
        }
        if (task.packageAvailable != packageAvailable ||
            task.originalAvailable != originalAvailable ||
            task.state != nextState ||
            task.installedPath != nextPath ||
            task.installedPackage != nextPackage ||
            task.androidOperationPackage != nextOperationPackage ||
            task.error != nextError) {
          task.packageAvailable = packageAvailable;
          task.originalAvailable = originalAvailable;
          task.state = nextState;
          task.installedPath = nextPath;
          task.installedPackage = nextPackage;
          task.androidOperationPackage = nextOperationPackage;
          task.error = nextError;
          changed = true;
        }
      } on Exception catch (error) {
        // Preserve this record if its paths could not be checked.
        failure ??= error;
      }
    }
    if (changed) _emit();
    if (failure != null) throw failure;
  }

  Future<bool> _refreshSelfUpdate(DownloadTask task) async {
    final operation = task._operation;
    final available = await File(task.filePath).exists();
    String? error, result;
    final job = task.selfUpdateJob;
    if (job != null) {
      Future<String?> read(String name) async {
        final file = File(p.join(job, name));
        try {
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              await file.length() > 16 * 1024) {
            return null;
          }
          return (await file.readAsString()).trim();
        } on FileSystemException {
          return null;
        }
      }

      error = await read('error.txt');
      result = await read('result');
    }
    if (task.busy || task.deleting || task._operation != operation) {
      return false;
    }
    final state = error != null
        ? (available ? DownloadState.downloaded : DownloadState.failed)
        : result == 'installed'
        ? DownloadState.installed
        : !available &&
              [
                DownloadState.downloaded,
                DownloadState.handedOff,
              ].contains(task.state)
        ? DownloadState.failed
        : task.state;
    final nextError =
        error ??
        (state == DownloadState.installed
            ? null
            : !available && state == DownloadState.failed
            ? '更新安装包已被移动或删除，请重新下载。'
            : task.error);
    if (task.packageAvailable == available &&
        task.state == state &&
        task.error == nextError) {
      return false;
    }
    task.packageAvailable = available;
    task.state = state;
    task.error = nextError;
    return true;
  }

  Future<bool> _pathExists(String path, FileSystemEntityType type) async {
    try {
      // Unlike exists/type alone, resolving reports permission and I/O errors.
      await File(path).resolveSymbolicLinks();
      return await FileSystemEntity.type(path) == type;
    } on FileSystemException catch (error) {
      final missingCodes = Platform.isWindows ? [2, 3] : [2, 20];
      if (missingCodes.contains(error.osError?.errorCode)) return false;
      rethrow;
    }
  }

  Future<DownloadTask> download(
    CatalogApp app,
    DownloadLink link, {
    AndroidSigningKey? resignKey,
    String? resignPackageName,
  }) => _download(
    app.name,
    link,
    appKey: app.key,
    resignKey: resignKey,
    resignPackageName: resignPackageName,
  );

  Future<DownloadTask> downloadVersion(
    DownloadTask task,
    DownloadLink link, {
    AndroidSigningKey? resignKey,
    String? resignPackageName,
  }) => _download(
    task.appName,
    link,
    appKey: task.appKey,
    resignKey: resignKey,
    resignPackageName: resignPackageName,
  );

  Future<DownloadTask> downloadSelfUpdate(DownloadLink link, String channel) =>
      _download(
        '华润赢更新',
        link,
        appKey: 'self-update:$channel',
        selfUpdateChannel: channel,
      );

  Future<void> installSelfUpdate(
    DownloadTask task,
    Future<void> Function(String digest) install,
  ) async {
    if (!task.isSelfUpdate ||
        !task.canInstallOn(runningDownloadPlatform) ||
        task.wantsResign ||
        task.deleting ||
        !tasks.contains(task) ||
        tasks.any((other) => other.state == DownloadState.installing)) {
      throw StateError('更新任务暂时不可安装。');
    }
    task._operation++;
    task.state = DownloadState.installing;
    task.installPhase = 'validating';
    task.error = null;
    task.selfUpdateJob = null;
    _emit();
    try {
      await _verifyForInstallation(task);
      final digest = await compute(packageSha256, task.filePath);
      task.verifiedSha256 = digest;
      _emit();
      await flushHistory();
      if (_historyError != null) {
        throw const FormatException('更新记录尚未保存，请检查存储空间后重试。');
      }
      await install(digest);
      task.state = task.platform == 'Android'
          ? DownloadState.installed
          : DownloadState.handedOff;
      task.installPhase = null;
      _emit();
      await flushHistory();
      if (_historyError != null) {
        throw const FormatException('更新记录尚未保存，已取消退出，请检查存储空间后重试。');
      }
    } catch (error) {
      final job = task.selfUpdateJob;
      if (job != null) {
        try {
          await File(p.join(job, 'cancel'))
              .writeAsString('cancel', flush: true);
        } on FileSystemException {
          // Without exiting the current app, the updater cannot replace it.
        }
      }
      task.state = DownloadState.downloaded;
      task.error = error is PlatformException
          ? error.message
          : error is FormatException
          ? error.message
          : '更新安装未完成，安装包已保留。';
      rethrow;
    } finally {
      task.installPhase = null;
      _emit();
      await flushHistory();
    }
  }

  DownloadTask? resigningPreferenceFor({
    String? appKey,
    required String appName,
  }) {
    final matches =
        tasks
            .where(
              (task) =>
                  task.wantsResign &&
                  task.isRenamedPackage(DownloadPackage.resigned) &&
                  (task.appKey == appKey && appKey != null ||
                      task.appKey == null && task.appName == appName),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return matches.firstOrNull;
  }

  Future<DownloadTask> _download(
    String appName,
    DownloadLink link, {
    String? appKey,
    String? selfUpdateChannel,
    AndroidSigningKey? resignKey,
    String? resignPackageName,
  }) async {
    if (!link.isDownloadable || Uri.parse(link.url).scheme != 'https') {
      throw const FormatException('此入口需要在官方页面打开。');
    }
    if (resignKey != null &&
        (link.platform != 'Android' || link.kind != 'apk')) {
      throw const FormatException('仅支持重签 Android APK。');
    }
    if (resignPackageName != null) {
      final error = androidPackageNameError(resignPackageName);
      if (resignKey == null || error != null) {
        throw FormatException(error ?? '修改包名需同时选择重签密钥。');
      }
    }
    final expectedSha256 = normalizeSha256(link.sha256);
    final existing = tasks
        .where(
          (t) =>
              !t.deleting &&
              (t.appKey == appKey ||
                  t.appKey == null && t.appName == appName) &&
              t.url == link.url &&
              t.selfUpdateChannel == selfUpdateChannel &&
              (selfUpdateChannel == null || t.version == link.version) &&
              t.resignKey?.id == resignKey?.id &&
              t.resignPackageName == resignPackageName &&
              (expectedSha256 == null || t.sha256 == expectedSha256) &&
              (t.busy ||
                  t.state == DownloadState.downloaded ||
                  t.state == DownloadState.handedOff ||
                  t.state == DownloadState.installed),
        )
        .firstOrNull;
    if (existing != null &&
        (selfUpdateChannel == null ||
            existing.busy ||
            await File(existing.filePath).exists())) {
      return existing;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    var fileName = p
        .basename(Uri.parse(link.url).path)
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (selfUpdateChannel != null &&
        !fileName.toLowerCase().endsWith('.${link.kind}')) {
      fileName = '${fileName.isEmpty ? 'huarunwin' : fileName}.${link.kind}';
    }
    final root = await locations?.prepareDirectory() ?? directory;
    final folder = Directory(p.join(root.path, id));
    await folder.create(recursive: true);
    final task = DownloadTask(
      id: id,
      appName: appName,
      appKey: appKey,
      selfUpdateChannel: selfUpdateChannel,
      url: link.url,
      filePath: p.join(folder.path, fileName),
      kind: link.kind!,
      platform: link.platform,
      createdAt: DateTime.now(),
      sha256: expectedSha256,
      checksumSource: link.checksumSource,
      version: link.version,
      releaseUrl: link.releaseUrl,
      resignKey: resignKey,
      resignPackageName: resignPackageName,
      originalAvailable: false,
      androidOperationPackage: DownloadPackage.original,
    );
    tasks.insert(0, task);
    _emit();
    unawaited(_start(task));
    return task;
  }

  Future<void> retry(DownloadTask task) async {
    if (task.busy || task.deleting || !tasks.contains(task)) return;
    // The terminal state is emitted before the queue releases its slot.
    // A fast retry must wait for that cleanup before starting a new operation.
    await _running[task.id];
    if (task.busy || task.deleting || !tasks.contains(task)) return;
    task.state = DownloadState.queued;
    task.error = null;
    if (!task.wantsResign ||
        !task.originalAvailable ||
        task.verifiedSha256 == null) {
      task.received = 0;
      task.total = 0;
      task.verifiedSha256 = null;
      if (GitHubAcceleration.supports(
        Uri.parse(task.url),
        GitHubTraffic.download,
      )) {
        github?.retryPrimary(GitHubTraffic.download);
      }
    }
    task.resignedSha256 = null;
    task._androidInspectionSha256 = null;
    task._androidInspectionPackage = null;
    task.removedPackages = {...task.removedPackages}
      ..remove(DownloadPackage.resigned);
    if (task.verifiedSha256 == null) task.removedPackages = {};
    task.androidOperationPackage =
        task.wantsResign &&
            task.originalAvailable &&
            task.verifiedSha256 != null
        ? DownloadPackage.resigned
        : DownloadPackage.original;
    _emit();
    await _start(task);
  }

  Future<void> importFile(File file, {String? platform}) async {
    final target = platform ?? runningDownloadPlatform;
    final kinds = switch (target) {
      'macOS' => ['dmg', 'zip', 'pkg'],
      'Android' => ['apk'],
      'Windows' => ['exe', 'msi', 'msix', 'zip'],
      'Linux' => ['deb', 'rpm', 'pkg.tar.zst', 'appimage', 'zip'],
      _ => <String>[],
    };
    final kind = LinuxInstaller.kind(file.path);
    if (!kinds.contains(kind)) {
      throw FormatException(
        '请选择 ${kinds.map((v) => v.toUpperCase()).join(' / ')} 安装包。',
      );
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final root = await locations?.prepareDirectory() ?? directory;
    final folder = await Directory(p.join(root.path, id))
        .create(recursive: true);
    final copied = await file.copy(p.join(folder.path, p.basename(file.path)));
    final task = DownloadTask(
      id: id,
      appName: p.basenameWithoutExtension(file.path),
      url: '',
      filePath: copied.path,
      kind: kind,
      platform: target,
      createdAt: DateTime.now(),
      state: DownloadState.downloaded,
      received: await copied.length(),
      total: await copied.length(),
    );
    tasks.insert(0, task);
    await _updatePackageModifiedTime(task, DownloadPackage.original);
    await _captureApkIdentity(task, DownloadPackage.original);
    _emit();
  }

  Future<DownloadTask> adoptAndroidApk(Map<Object?, Object?> entry) async {
    final id = entry['id'] as String;
    final path = entry['path'] as String;
    final file = File(path);
    final root = await directory.resolveSymbolicLinks();
    final canonical = await file.resolveSymbolicLinks();
    if (!id.startsWith('incoming-') ||
        !p.isWithin(root, canonical) ||
        p.dirname(p.dirname(canonical)) != root ||
        p.basename(p.dirname(canonical)) != id ||
        p.extension(canonical).toLowerCase() != '.apk') {
      throw const FormatException('导入的 APK 路径无效，请重新打开文件。');
    }
    final existing = tasks.where((task) => task.id == id).firstOrNull;
    if (existing != null) {
      await _persistIncomingApk(existing);
      return existing;
    }
    final bytes = await file.length();
    if (bytes <= 0 || bytes > maxBytes) {
      throw const FormatException('APK 文件大小无效。');
    }
    final task = DownloadTask(
      id: id,
      appName: p.basenameWithoutExtension(canonical),
      url: '',
      filePath: p.join(directory.path, id, p.basename(canonical)),
      kind: 'apk',
      platform: 'Android',
      createdAt: DateTime.now(),
      state: DownloadState.downloaded,
      received: bytes,
      total: bytes,
    );
    tasks.insert(0, task);
    await _updatePackageModifiedTime(task, DownloadPackage.original);
    await _captureApkIdentity(task, DownloadPackage.original);
    await _persistIncomingApk(task);
    return task;
  }

  Future<void> _persistIncomingApk(DownloadTask task) async {
    _emit();
    await flushHistory();
    if (_historyError != null) {
      throw const FileSystemException('APK 导入记录尚未保存，请重试。');
    }
    if (writeHistory != null) return;
    final saved = jsonDecode(await _index.readAsString()) as List;
    if (!saved.any(
      (entry) =>
          entry is Map &&
          entry['id'] == task.id &&
          entry['filePath'] == task.filePath,
    )) {
      throw const FileSystemException('APK 导入记录尚未保存，请重试。');
    }
  }

  Future<DownloadTask> resignForInstallation(
    DownloadTask task,
    AndroidSigningKey key, {
    String? packageName,
    DownloadPackage? package,
  }) async {
    if (task.isSelfUpdate) throw StateError('客户端更新不能改包或重签。');
    final selected = package ?? task.defaultPackage;
    if (!task.canInstallPackageOn('Android', selected) ||
        task.deleting ||
        !tasks.contains(task)) {
      throw StateError('安装包当前不可重签。');
    }
    if (_running[task.id] case final pending?) {
      await pending;
      if (!task.canInstallPackageOn('Android', selected) ||
          !tasks.contains(task)) {
        throw StateError('安装包当前不可重签。');
      }
    }
    final sourceName = selected == DownloadPackage.original
        ? task.originalPackageName
        : task.resignedPackageName;
    if (packageName != null) {
      final error = androidPackageNameError(packageName, original: sourceName);
      if (error != null) throw FormatException(error);
    }
    task.checking = true;
    task.androidCheckingPackage = selected;
    task._operation++;
    notifyListeners();
    DownloadTask result = task;
    Directory? snapshotFolder;
    var registered = false;
    try {
      final path = task.packagePath(selected);
      final digest = await compute(packageSha256, path);
      if (task._androidInspectionSha256 != digest ||
          task._androidInspectionPackage != selected) {
        throw const FormatException('所选 APK 在确认后已变化，请重新检查后重签。');
      }
      await _verifyForInstallation(task, package: selected);
      if (task.wantsResign || task.state == DownloadState.installed) {
        final root = await directory.resolveSymbolicLinks();
        final canonical = await File(path).resolveSymbolicLinks();
        if (!p.isWithin(root, canonical)) {
          throw const FormatException('所选 APK 的位置无效。');
        }
        snapshotFolder = await Directory(root).createTemp('derived-');
        final name = p
            .basenameWithoutExtension(path)
            .replaceFirst(RegExp(r'(-huarun-sign)+$'), '');
        final snapshot = await File(path)
            .copy(p.join(snapshotFolder.path, '$name.apk'));
        if (await compute(packageSha256, snapshot.path) != digest) {
          throw const FormatException('所选 APK 在复制时已变化，请重新检查后重签。');
        }
        final bytes = await snapshot.length();
        result = DownloadTask(
          id: p.basename(snapshotFolder.path),
          appName: task.appName,
          appKey: task.appKey,
          url: '',
          filePath: snapshot.path,
          kind: 'apk',
          platform: 'Android',
          createdAt: DateTime.now(),
          version: task.version,
          releaseUrl: task.releaseUrl,
          received: bytes,
          total: bytes,
          sha256: digest,
          verifiedSha256: digest,
          resignKey: key,
          resignPackageName: packageName,
          originalPackageName: sourceName,
          sourceTaskId: task.id,
          rootPackageName: task.rootPackageName ?? task.originalPackageName,
          apkIdentities: {
            DownloadPackage.original: ?task.apkIdentities[selected],
          },
          packageAvailable: false,
          androidOperationPackage: DownloadPackage.resigned,
        );
        tasks.insert(0, result);
        registered = true;
      } else {
        task.resignKey = key;
        task.resignPackageName = packageName;
        task.verifiedSha256 = digest;
        task.resignedSha256 = null;
        task._androidInspectionSha256 = null;
        task._androidInspectionPackage = null;
        task.originalAvailable = true;
      }
    } catch (_) {
      if (!registered && snapshotFolder != null) {
        await snapshotFolder.delete(recursive: true);
      }
      rethrow;
    } finally {
      task.checking = false;
      task.androidCheckingPackage = null;
      _emit();
    }
    await _start(result);
    if (!result.resignReady || result.state != DownloadState.downloaded) {
      throw PlatformException(
        code: 'resign',
        message: result.error ?? '重签未完成，所选 APK 已保留。',
      );
    }
    return result;
  }

  Future<void> _start(DownloadTask task) {
    if (_running[task.id] case final running?) return running;
    final job = _QueuedDownload(task);
    task.cancelToken = CancelToken();
    _queued.add(job);
    _running[task.id] = job.done.future;
    _drain();
    return job.done.future;
  }

  void _drain() {
    while (_activeDownloads < maxConcurrentDownloads && _queued.isNotEmpty) {
      final job = _queued.removeAt(0);
      _activeDownloads++;
      unawaited(
        _run(job.task).whenComplete(() {
          _activeDownloads--;
          _running.remove(job.task.id);
          job.done.complete();
          _drain();
        }),
      );
    }
  }

  Iterable<String> _packagePaths(DownloadTask task, DownloadPackage package) {
    final path = package == DownloadPackage.original
        ? task.filePath
        : task.resignedFilePath;
    return [
      path,
      '$path.part',
      '$path.part.json',
      '$path.part.json.tmp',
      if (package == DownloadPackage.resigned) '$path.unsigned',
    ];
  }

  Future<Set<DownloadPackage>> packagesForRemoval(DownloadTask task) async {
    final packages = <DownloadPackage>{};
    for (final package in DownloadPackage.values) {
      if (package == DownloadPackage.resigned && !task.wantsResign) continue;
      for (final path in _packagePaths(task, package)) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          packages.add(package);
          break;
        }
      }
    }
    if (task.busy) {
      packages.add(DownloadPackage.original);
      if (task.state == DownloadState.resigning) {
        packages.add(DownloadPackage.resigned);
      }
    }
    return packages;
  }

  Future<void> remove(
    DownloadTask task, {
    Set<DownloadPackage>? packages,
  }) async {
    final selected = Set.of(packages ?? DownloadPackage.values);
    if (task.isDerivedApk && selected.contains(DownloadPackage.resigned)) {
      selected.add(DownloadPackage.original);
    }
    if (selected.isEmpty) return;
    if (task.state == DownloadState.installing || task.checking) {
      throw StateError('检查或安装中暂时不能删除。');
    }
    if (task.deleting || !tasks.contains(task)) return;
    task._operation++;
    task.deleting = true;
    notifyListeners();
    try {
      cancel(task);
      await _running[task.id];
      final taskDirectory = locations?.managedRoot(task.filePath) ?? directory;
      final root = p.normalize(
        await taskDirectory.exists()
            ? await taskDirectory.resolveSymbolicLinks()
            : taskDirectory.absolute.path,
      );
      final folder = File(task.filePath).parent;
      if ((!p.isWithin(
                p.normalize(taskDirectory.absolute.path),
                p.normalize(task.filePath),
              ) &&
              !p.isWithin(root, p.normalize(task.filePath))) ||
          (await folder.exists() &&
              !p.isWithin(
                root,
                p.normalize(await folder.resolveSymbolicLinks()),
              ))) {
        throw const FileSystemException('下载文件位置无效，无法删除。');
      }
      final signedFolder = Directory(p.dirname(task.resignedFilePath));
      if (task.wantsResign &&
          await signedFolder.exists() &&
          p.normalize(await signedFolder.resolveSymbolicLinks()) !=
              task._resignedDirectory(await folder.resolveSymbolicLinks())) {
        throw const FileSystemException('重签文件位置无效，无法删除。');
      }
      for (final path in [
        for (final package in selected)
          if (package == DownloadPackage.original || task.wantsResign)
            ..._packagePaths(task, package),
      ]) {
        // Never follow a tampered child directory when removing a derived APK.
        final parent = File(path).parent;
        if (await parent.exists() &&
            !p.isWithin(
              root,
              p.normalize(await parent.resolveSymbolicLinks()),
            )) {
          throw const FileSystemException('重签文件位置无效，无法删除。');
        }
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await File(path).delete();
        }
      }
      if (task.wantsResign &&
          task._legacyResignedPath &&
          await signedFolder.exists() &&
          await signedFolder.list().isEmpty) {
        await signedFolder.delete();
      }
      if (await folder.exists() &&
          p.normalize(folder.path) != p.normalize(taskDirectory.path) &&
          await folder.list().isEmpty) {
        await folder.delete();
      }
      final remaining = await packagesForRemoval(task);
      task.removedPackages = {...task.removedPackages, ...selected};
      if (remaining.isEmpty) {
        tasks.remove(task);
      } else {
        task.originalAvailable = await _pathExists(
          task.filePath,
          FileSystemEntityType.file,
        );
        task.packageAvailable = task.wantsResign
            ? await _pathExists(
                task.resignedFilePath,
                FileSystemEntityType.file,
              )
            : task.originalAvailable;
        task._androidInspectionSha256 = null;
        task._androidInspectionPackage = null;
        if (!task.packageAvailable) {
          if (task.state != DownloadState.installed) {
            task.state = DownloadState.failed;
          }
          task.error = task.wantsResign && task.originalAvailable
              ? '重签包已删除，原始包已保留，可重试重签。'
              : '安装包不可用，请重新下载或导入。';
        } else if (task.state == DownloadState.failed ||
            task.state == DownloadState.cancelled) {
          task.state = DownloadState.downloaded;
          task.error = null;
        }
      }
    } finally {
      task.deleting = false;
      _emit();
      await flushHistory();
    }
  }

  Future<void> _run(DownloadTask task) async {
    task._operation++;
    if (task.isSelfUpdate) task.selfUpdateJob = null;
    task.androidInstallErrorDetails = const {};
    final resumeResign =
        task.wantsResign &&
        task.originalAvailable &&
        task.verifiedSha256 != null;
    task.androidOperationPackage = resumeResign
        ? DownloadPackage.resigned
        : DownloadPackage.original;
    task.state = resumeResign
        ? DownloadState.resigning
        : DownloadState.downloading;
    if (!resumeResign) {
      task.packageAvailable = false;
      task.originalAvailable = false;
    }
    final cancelToken = task.cancelToken ?? CancelToken();
    task.cancelToken = cancelToken;
    final partial = File('${task.filePath}.part');
    var outcome = DownloadState.downloaded;
    var lastUpdate = DateTime.now();
    _emit();
    try {
      await foreground?.start(_foregroundProgress);
      downloadWarning = null;
      if (!resumeResign) {
        await ResumableDownload(client, github: github).receive(
          url: task.url,
          partial: partial,
          cancelToken: cancelToken,
          maxBytes: maxBytes,
          resource: task.kind == 'resource',
          sha256: task.sha256,
          verify: () async {
            if (task.sha256 == null) return;
            task.state = DownloadState.verifying;
            _emit();
            final digest = await compute(packageSha256, partial.path);
            if (cancelToken.isCancelled) throw cancelToken.cancelError!;
            if (digest != task.sha256) {
              task.verifiedSha256 = null;
              task.packageAvailable = false;
              throw const FormatException('SHA-256 校验不一致，安装包已丢弃，请重新下载。');
            }
            task.verifiedSha256 = digest;
          },
          onProgress: (received, total) {
            task.received = received;
            task.total = total;
            if (DateTime.now().difference(lastUpdate).inMilliseconds > 150) {
              notifyListeners();
              foreground?.update(_foregroundProgress);
              lastUpdate = DateTime.now();
            }
          },
        );
        await partial.rename(task.filePath);
        await ResumableDownload.discard(partial);
        task.packageAvailable = true;
        task.originalAvailable = true;
        await _captureApkIdentity(task, DownloadPackage.original);
        await _updatePackageModifiedTime(
          task,
          DownloadPackage.original,
          allowBusy: true,
        );
      }
      if (task.wantsResign) {
        task.androidOperationPackage = DownloadPackage.resigned;
        task.state = DownloadState.resigning;
        _emit();
        await _resignDownloaded(task, cancelToken);
        await _captureApkIdentity(task, DownloadPackage.resigned);
      }
    } catch (error) {
      outcome = cancelToken.isCancelled
          ? DownloadState.cancelled
          : task.wantsResign &&
                task.originalAvailable &&
                task.verifiedSha256 != null
          ? DownloadState.downloaded
          : DownloadState.failed;
      task.error = cancelToken.isCancelled
          ? null
          : error is FormatException
          ? error.message
          : error is HttpException
          ? '下载的文件不完整，请重试。'
          : error is PlatformException
          ? error.message ?? '重签失败，原始 APK 已保留，可以重试。'
          : task.state == DownloadState.resigning
          ? '重签失败，原始 APK 已保留，可以重试。'
          : '下载失败，请检查网络后重试。';
    } finally {
      if (task.wantsResign && cancelToken.isCancelled) {
        task.resignedSha256 = null;
        outcome = DownloadState.cancelled;
        task.error = null;
        try {
          final signed = File(task.resignedFilePath);
          if (await signed.parent.exists() &&
              p.normalize(await signed.parent.resolveSymbolicLinks()) !=
                  task._resignedDirectory(
                    await File(task.filePath).parent.resolveSymbolicLinks(),
                  )) {
            throw const FileSystemException('重签目录无效。');
          }
          if (await signed.exists()) await signed.delete();
        } on FileSystemException {
          task.error = '重签已取消，未发布的副本未能清理，请删除下载记录。';
        }
      }
      task.cancelToken = null;
      task.state = outcome;
      _emit();
    }
  }

  Future<void> _resignDownloaded(DownloadTask task, CancelToken token) async {
    final key = task.resignKey!;
    final original = await compute(packageSha256, task.filePath);
    if (token.isCancelled) throw const FormatException('重签已取消。');
    if ((task.sha256 != null && original != task.sha256) ||
        (task.verifiedSha256 != null && original != task.verifiedSha256)) {
      task.verifiedSha256 = null;
      throw const FormatException('原始 APK 的 SHA-256 已变化，请重新下载后重签。');
    }
    task.verifiedSha256 = original;
    _emit();
    var output = File(task.resignedFilePath);
    // A previous interrupted operation may have left an unpublished output.
    // Validate the parent before cleanup; the native bridge checks it again.
    final folder = output.parent;
    if (await folder.exists() &&
        p.normalize(await folder.resolveSymbolicLinks()) !=
            task._resignedDirectory(
              await File(task.filePath).parent.resolveSymbolicLinks(),
            )) {
      throw const FormatException('重签目录无效。');
    }
    if (task._legacyResignedPath) {
      for (final path in [output.path, '${output.path}.part']) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          await File(path).delete();
        }
      }
      if (await folder.exists() && await folder.list().isEmpty) {
        await folder.delete();
      }
      task._legacyResignedPath = false;
      output = File(task.resignedFilePath);
      _emit();
    }
    try {
      if (await output.exists()) await output.delete();
      if (token.isCancelled) throw const FormatException('重签已取消。');
      final result = await installer.resignApk(
        task.filePath,
        key: key,
        expectedSourceSha256: original,
        packageName: task.resignPackageName,
      );
      if (token.isCancelled) throw const FormatException('重签已取消。');
      final digest = await compute(packageSha256, output.path);
      if (token.isCancelled) throw const FormatException('重签已取消。');
      if (normalizeSha256(result.sha256) != digest ||
          result.certificateSha256 != key.certificateSha256 ||
          task.resignPackageName != null &&
              result.packageName != task.resignPackageName) {
        throw const FormatException('重签副本验证失败，原始 APK 已保留。');
      }
      task.resignedSha256 = digest;
      task.originalPackageName =
          result.sourcePackageName ?? task.originalPackageName;
      task.packageAvailable = true;
      await _updatePackageModifiedTime(
        task,
        DownloadPackage.resigned,
        allowBusy: true,
      );
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    }
  }

  void cancel(DownloadTask task) {
    task.cancelToken?.cancel('用户取消');
    final queued = _queued
        .where((job) => identical(job.task, task))
        .firstOrNull;
    if (queued != null) {
      _queued.remove(queued);
      _running.remove(task.id);
      task.cancelToken = null;
      task.state = DownloadState.cancelled;
      task.error = null;
      queued.done.complete();
      _emit();
    }
  }

  Future<void> handOff(DownloadTask task, {DownloadPackage? package}) async {
    if (task.isSelfUpdate) throw StateError('请使用客户端更新安装入口。');
    final selected = package ?? task.defaultPackage;
    final eligible = package == null
        ? task.canHandOff
        : task.canInstallPackageOn(runningDownloadPlatform, selected);
    if (!eligible || task.deleting || !tasks.contains(task)) return;
    final previousInstalled =
        task.platform == 'Android' &&
        task.state == DownloadState.installed &&
        task.installedPackage != null;
    final path = task.packagePath(selected);
    task.androidOperationPackage = selected;
    task._operation++;
    task.state = DownloadState.installing;
    task.installPhase = 'opening_system';
    task.error = null;
    task.androidInstallErrorDetails = const {};
    _emit();
    try {
      if (task.platform == 'Android' && package != null) {
        _requireAndroidInspection(task, selected);
      }
      await _verifyForInstallation(task, package: selected);
      if (task.platform == 'Linux') {
        await installer.openLinuxPackage(path);
      } else {
        await installer.openPackage(
          path,
          expectedSha256: task.platform == 'Android'
              ? _androidExpectedSha256(task, selected)
              : null,
        );
      }
      task.state = DownloadState.handedOff;
    } catch (error) {
      task.state = previousInstalled
          ? DownloadState.installed
          : DownloadState.downloaded;
      task.error = error is PlatformException
          ? error.message
          : '无法打开安装包，请查看文件后重试。';
      _recordAndroidInstallError(task, error);
    } finally {
      task.installPhase = null;
      _emit();
    }
  }

  Future<void> _verifyForInstallation(
    DownloadTask task, {
    DownloadPackage? package,
  }) async {
    final selected = package ?? task.defaultPackage;
    final resigned = selected == DownloadPackage.resigned;
    final expected = resigned
        ? task.resignedSha256
        : task.sha256 ?? task.verifiedSha256;
    if (expected == null) {
      if (resigned) {
        throw PlatformException(code: 'resign', message: '请先完成重签。');
      }
      return;
    }
    final digest = await compute(packageSha256, task.packagePath(selected));
    if (digest != expected) {
      if (!resigned) task.verifiedSha256 = null;
      throw PlatformException(
        code: 'checksum',
        message: '安装包的 SHA-256 已变化，请删除后重新下载。',
      );
    }
    if (!resigned) task.verifiedSha256 = digest;
  }

  String? _androidExpectedSha256(DownloadTask task, DownloadPackage package) =>
      (task._androidInspectionPackage == package
          ? task._androidInspectionSha256
          : null) ??
      (package == DownloadPackage.resigned
          ? task.resignedSha256
          : task.sha256 ?? task.verifiedSha256);

  void _requireAndroidInspection(DownloadTask task, DownloadPackage package) {
    if (task._androidInspectionPackage != package ||
        task._androidInspectionSha256 == null) {
      throw PlatformException(
        code: 'package_changed',
        message: '请重新检查并确认所选安装包。',
      );
    }
  }

  // Display snapshots keep the UI stable while the file is checked again.
  // They never authorize installation or replace its independent inspection.
  AndroidApkDetails? cachedApkDetails(
    DownloadTask task,
    DownloadPackage package,
  ) {
    final cached = task._apkDetails[package];
    final modifiedAt = package == DownloadPackage.original
        ? task.originalModifiedAt
        : task.resignedModifiedAt;
    final sha256 = package == DownloadPackage.original
        ? task.verifiedSha256
        : task.resignedSha256;
    if (!tasks.contains(task) ||
        !task.hasPackage(package) ||
        cached == null ||
        cached.path != task.packagePath(package) ||
        cached.sha256 != sha256 ||
        modifiedAt != null && modifiedAt.toUtc() != cached.modifiedAt) {
      return null;
    }
    return cached.details;
  }

  void _cacheApkDetails(
    DownloadTask task,
    DownloadPackage package,
    AndroidApkDetails details,
    FileStat stat,
  ) {
    task._apkDetails[package] = (
      details: details,
      path: task.packagePath(package),
      sha256: package == DownloadPackage.original
          ? task.verifiedSha256
          : task.resignedSha256,
      modifiedAt: stat.modified.toUtc(),
    );
  }

  // Display reads never authorize installation or change the task result.
  Future<AndroidApkDetails> readApkDetails(
    DownloadTask task,
    DownloadPackage package,
  ) async {
    final operation = task._operation;
    final path = task.packagePath(package);
    if (!task.hasPackage(package) || task.busy || task.deleting) {
      throw StateError('安装包当前不可读取。');
    }
    final before = await File(path).stat();
    if (before.type != FileSystemEntityType.file) {
      throw const FileSystemException('安装包不在本地。');
    }
    AndroidPackageInfo? info;
    String? error;
    if (runningDownloadPlatform == 'Android') {
      try {
        info = await installer.inspectApk(path);
      } on Exception {
        error = '包信息读取失败，点击重试';
      }
    }
    final after = await File(path).stat();
    if (!tasks.contains(task) ||
        operation != task._operation ||
        path != task.packagePath(package) ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed) {
      throw StateError('安装包已变化，请重新读取。');
    }
    final details = AndroidApkDetails(
      info: info,
      bytes: after.size,
      error: error,
    );
    if (error == null) _cacheApkDetails(task, package, details, after);
    return details;
  }

  Future<void> shareApk(DownloadTask task, DownloadPackage package) async {
    if (!tasks.contains(task) ||
        task.busy ||
        task.deleting ||
        !task.hasPackage(package)) {
      throw StateError('安装包当前不可分享。');
    }
    task.checking = true;
    task.androidCheckingPackage = package;
    task._operation++;
    notifyListeners();
    try {
      await _verifyForInstallation(task, package: package);
      await installer.reveal(task.packagePath(package));
    } finally {
      task.checking = false;
      task.androidCheckingPackage = null;
      notifyListeners();
    }
  }

  Future<AndroidPackageInfo> inspectApk(
    DownloadTask task, {
    DownloadPackage? package,
  }) async {
    final selected = package ?? task.defaultPackage;
    final eligible = package == null
        ? task.canInstallOn('Android')
        : task.canInstallPackageOn('Android', selected);
    if (!eligible || task.deleting || !tasks.contains(task)) {
      throw StateError('安装包当前不可检查。');
    }
    task.checking = true;
    task.androidCheckingPackage = selected;
    task._androidInspectionSha256 = null;
    task._androidInspectionPackage = null;
    task.androidOperationPackage = selected;
    task._operation++;
    notifyListeners();
    try {
      await _verifyForInstallation(task, package: selected);
      final info = await installer.inspectApk(task.packagePath(selected));
      if (selected == DownloadPackage.original) {
        task.originalPackageName = info.packageName;
      }
      if (selected == DownloadPackage.resigned &&
          task.resignPackageName != null &&
          info.packageName != task.resignPackageName) {
        throw PlatformException(code: 'resign', message: '重签副本的包名已变化，请重新重签。');
      }
      if (selected == DownloadPackage.resigned &&
          (info.certificateSha256.length != 1 ||
              info.certificateSha256.single !=
                  task.resignKey!.certificateSha256)) {
        throw PlatformException(code: 'resign', message: '重签副本的证书已变化，请重新重签。');
      }
      task._androidInspectionSha256 = info.fileSha256;
      task._androidInspectionPackage = selected;
      task.error = info.isDowngrade ? info.downgradeMessage : null;
      task.androidInstallErrorDetails = info.isDowngrade
          ? {
              'code': 'version_downgrade',
              'versionCode': '${info.versionCode}',
              'installedVersionCode': '${info.installedVersionCode}',
            }
          : const {};
      return info;
    } catch (error) {
      task.error = error is PlatformException
          ? error.message ?? '无法检查安装包。'
          : '无法检查安装包。';
      _recordAndroidInstallError(task, error);
      rethrow;
    } finally {
      task.checking = false;
      task.androidCheckingPackage = null;
      _emit();
    }
  }

  void _recordAndroidInstallError(DownloadTask task, Object error) {
    if (task.platform != 'Android') return;
    task.androidInstallErrorDetails = error is PlatformException
        ? {
            if (error.details case final Map details)
              for (final entry in details.entries)
                if (entry.key is String && entry.value != null)
                  entry.key as String: entry.value.toString(),
            'code': error.code,
          }
        : const {};
  }

  Future<void> install(
    DownloadTask task, {
    bool authorize = false,
    Map<String, String>? quitApplication,
    Map<String, String>? signerApproval,
    AndroidInstallMethod androidMethod = AndroidInstallMethod.huarun,
    DownloadPackage? package,
  }) async {
    if (task.isSelfUpdate) throw StateError('请使用客户端更新安装入口。');
    final selected = package ?? task.defaultPackage;
    final eligible = package == null
        ? task.canInstall
        : task.canInstallPackageOn(runningDownloadPlatform, selected);
    if (!eligible || task.deleting || !tasks.contains(task)) return;
    if (task.platform == 'Android' &&
        androidMethod == AndroidInstallMethod.other) {
      throw ArgumentError('其他安装器须通过交接流程打开。');
    }
    final previousInstalled =
        task.platform == 'Android' &&
        task.state == DownloadState.installed &&
        task.installedPackage != null;
    task._operation++;
    task.androidOperationPackage = selected;
    task.state = DownloadState.installing;
    task.error = null;
    task.installPhase = 'preparing';
    task.signingInfo = {};
    task.androidInstallErrorDetails = const {};
    _emit();
    try {
      if (task.platform == 'Android' && package != null) {
        _requireAndroidInspection(task, selected);
      }
      await _verifyForInstallation(task, package: selected);
      if (task.platform == 'Android') {
        task.installPhase = 'opening_system';
        task.installedPackage = await installer.installApk(
          task.packagePath(selected),
          expectedSha256: _androidExpectedSha256(task, selected),
          method: androidMethod,
          onProgress: (event) {
            if (task.state != DownloadState.installing ||
                !tasks.contains(task)) {
              return;
            }
            task.installPhase = event['stage'];
            notifyListeners();
          },
        );
      } else if (task.platform == 'Linux') {
        task.installPhase = 'copying';
        notifyListeners();
        task.installedPath = await installer.installAppImage(
          task.filePath,
          expectedSha256: task.sha256,
        );
      } else {
        task.installedPath = await installer.install(
          task.filePath,
          removeQuarantine: true,
          authorize: authorize,
          quitApplication: quitApplication,
          signerApproval: signerApproval,
          onProgress: (event) {
            if (task.state != DownloadState.installing ||
                !tasks.contains(task)) {
              return;
            }
            task.installPhase = event['stage'];
            if (event['signature'] != null) {
              task.signingInfo = Map.of(event)
                ..remove('package')
                ..remove('event')
                ..remove('stage');
            }
            _emit();
          },
        );
      }
      task.state = DownloadState.installed;
      if (task.platform == 'Android') task.installedApkPackage = selected;
      installedApps.invalidate();
    } catch (error) {
      task.state = previousInstalled
          ? DownloadState.installed
          : DownloadState.downloaded;
      task.error = error is PlatformException
          ? error.message ?? '安装未完成。'
          : '安装未完成。';
      _recordAndroidInstallError(task, error);
      rethrow;
    } finally {
      task.installPhase = null;
      _emit();
    }
  }

  void _emit() {
    notifyListeners();
    foreground?.update(_foregroundProgress);
    final previousWarning = historyWarning;
    _persistence = _persistence
        .then((_) async {
          // A read retry can restore older tasks while new downloads progress.
          // Include both sets only after restoration finishes.
          await _restoring;
          // Never replace the source until its complete bytes are safely kept
          // in a unique backup. A later save retries failed recovery writes.
          await _preserveHistory();
          final snapshot = jsonEncode(tasks.map((t) => t.toJson()).toList());
          if (writeHistory case final writer?) {
            await writer(snapshot);
            _historyError = null;
            return;
          }
          final tmp = File('${_index.path}.tmp');
          await tmp.writeAsString(snapshot, flush: true);
          await tmp.rename(_index.path);
          _historyError = null;
        })
        .catchError((Object error) {
          _historyError = error;
          /* Downloaded files remain usable without history. */
        })
        .whenComplete(() {
          if (previousWarning != historyWarning && hasListeners) {
            notifyListeners();
          }
        });
  }
}

class _QueuedDownload {
  _QueuedDownload(this.task);
  final DownloadTask task;
  final done = Completer<void>();
}
