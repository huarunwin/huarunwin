import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/app_changelog.dart';
import '../data/models.dart';
import 'app_updates.dart';
import 'downloads.dart';
import 'github_releases.dart';
import 'installed_apps.dart';
import 'mac_downloads.dart';

class SelfUpdatePackages {
  static Future<List<DownloadLink>> resolve(
    AppRelease release,
    String platform,
    DownloadManager manager,
  ) async {
    List<DownloadLink> resources;
    if (release.packages.isNotEmpty) {
      resources = release.packages;
    } else {
      final url = release.downloadUrl!;
      if (platform == 'iOS') {
        resources = [
          DownloadLink(
            url: url.toString(),
            label: '系统更新渠道',
            platform: platform,
            kind: 'store',
          ),
        ];
      } else if (url.host == 'github.com' &&
          url.pathSegments.length >= 5 &&
          url.pathSegments[2] == 'releases' &&
          url.pathSegments[3] == 'tag') {
        resources = await GitHubReleaseResolver(manager.macResolver)
            .loadResources(
              GitHubRelease(
                page: url,
                tag: url.pathSegments.skip(4).join('/'),
                name: release.version,
              ),
            );
      } else {
        final name = url.pathSegments.lastOrNull ?? '';
        final kind = MacDownloadResolver.packageKind(name, platform);
        if (kind == null || !_kinds(platform).contains(kind)) {
          throw const FormatException('更新信息尚未提供本平台的安装包，请稍后重试。');
        }
        resources = [
          DownloadLink(
            url: url.toString(),
            label: name,
            platform: platform,
            kind: kind,
            architecture: MacDownloadResolver.architecture(name),
          ),
        ];
      }
    }
    final packages = resources
        .where(
          (r) =>
              r.platform == platform &&
              (platform == 'iOS'
                  ? r.kind == 'store'
                  : _kinds(platform).contains(r.kind)),
        )
        .toList();
    if (packages.isEmpty) throw const FormatException('此版本尚未提供本平台的更新安装包。');
    return [
      for (final item in packages)
        DownloadLink(
          url: item.url,
          label: item.label,
          platform: platform,
          kind: item.kind,
          architecture: item.architecture,
          sha256: item.sha256,
          checksumSource: item.checksumSource,
          version: release.version,
          releaseUrl: release.downloadUrl.toString(),
        ),
    ];
  }

  static List<String> _kinds(String platform) => switch (platform) {
    'Android' => ['apk'],
    'macOS' => ['dmg', 'zip'],
    'Windows' => ['exe', 'msi', 'msix', 'zip'],
    'Linux' => ['deb', 'rpm', 'pkg.tar.zst', 'appimage'],
    _ => [],
  };

  static Uri iosStore(DownloadLink link) {
    final uri = Uri.parse(link.url);
    if (isAppStoreUrl(link.url)) return uri.replace(scheme: 'itms-apps');
    if (uri.scheme == 'https' &&
        uri.host == 'testflight.apple.com' &&
        uri.userInfo.isEmpty &&
        uri.pathSegments.length == 2 &&
        uri.pathSegments.first == 'join' &&
        uri.pathSegments.last.isNotEmpty) {
      return uri;
    }
    throw const FormatException('iOS 更新须配置该应用的 App Store 或 TestFlight 地址。');
  }
}

class SelfUpdateInstaller {
  static const _channel = NativeInstaller.channel;

  static bool needsExit(DownloadTask task) =>
      task.platform == 'macOS' ||
      task.platform == 'Windows' ||
      task.platform == 'Linux' && task.kind == 'appimage';

  /// Returns only after the independent updater is ready, or the system accepted
  /// a package. The caller persists the handoff before exiting the current app.
  static Future<void> install(
    DownloadManager manager,
    DownloadTask task,
    String digest,
  ) async {
    if (!task.isSelfUpdate || task.wantsResign || task.version == null) {
      throw const FormatException('客户端更新任务信息不完整。');
    }
    if (task.selfUpdateChannel != AppUpdates.instance.channel.name) {
      throw const FormatException('该安装包不属于当前更新渠道，请重新检查更新。');
    }
    final current = await AppUpdates.instance.currentVersion();
    if (hasNewerVersion(task.version!, current)) {
      throw const FormatException('该更新包比当前客户端更旧，请重新检查更新。');
    }
    if (Platform.isAndroid || Platform.isMacOS) {
      final result = await _channel.invokeMethod<Object?>('installSelfUpdate', {
        'path': task.filePath,
        'expectedSha256': digest,
        'version': task.version,
        'channel': task.selfUpdateChannel,
      });
      if (result == null) throw const FormatException('系统未确认更新安装请求。');
      if (Platform.isAndroid) task.installedPackage = result as String;
      if (Platform.isMacOS && result is Map && result['job'] is String) {
        task.selfUpdateJob = result['job'] as String;
      }
    } else if (Platform.isWindows) {
      final job = await _jobDirectory();
      task.selfUpdateJob = job.path;
      final script = File(p.join(job.path, 'update.ps1'));
      await script.writeAsString(
        '\uFEFF${await rootBundle.loadString('assets/updater/windows.ps1')}',
      );
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot == null) throw const FormatException('无法确认 Windows 系统目录。');
      final executable = p.join(
        systemRoot,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      await Process.start(
        executable,
        [
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          task.filePath,
          digest,
          Platform.resolvedExecutable,
          '$pid',
          task.version!,
          job.path,
        ],
        mode: ProcessStartMode.detached,
        workingDirectory: job.path,
      );
      await _waitReady(job);
    } else if (Platform.isLinux) {
      if (task.kind == 'appimage') {
        if (task.sha256 == null) {
          throw const FormatException('AppImage 自身更新需由 Hub 或发布页提供 SHA-256。');
        }
        await manager.installer.linux.validateSelfUpdateAppImage(task.filePath);
        final current = Platform.environment['APPIMAGE'];
        if (current == null ||
            !p.isAbsolute(current) ||
            await FileSystemEntity.type(current, followLinks: false) !=
                FileSystemEntityType.file) {
          throw const FormatException('当前客户端未从 AppImage 启动，请使用系统软件包更新。');
        }
        final job = await _jobDirectory();
        task.selfUpdateJob = job.path;
        final script = File(p.join(job.path, 'update.sh'));
        await script.writeAsString(
          await rootBundle.loadString('assets/updater/linux.sh'),
        );
        await Process.start('/bin/sh', [
          script.path,
          task.filePath,
          digest,
          current,
          '$pid',
          job.path,
        ], mode: ProcessStartMode.detached);
        await _waitReady(job);
      } else {
        await _checkLinuxIdentity(task);
        await manager.installer.openLinuxPackage(task.filePath);
      }
    } else {
      throw const FormatException('当前平台不支持此安装方式。');
    }
  }

  static Future<Directory> _jobDirectory() async {
    final root = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'self-updates'),
    );
    await root.create(recursive: true);
    return root.createTemp('job-');
  }

  static Future<void> _waitReady(Directory job) async {
    final ready = File(p.join(job.path, 'ready'));
    final failure = File(p.join(job.path, 'error.txt'));
    final deadline = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(deadline)) {
      if (await failure.exists()) {
        throw FormatException(await failure.readAsString());
      }
      if (await ready.exists()) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await File(p.join(job.path, 'cancel')).writeAsString('cancel');
    throw const FormatException('准备更新超时，当前客户端保持运行，安装包已保留。');
  }

  static Future<void> _checkLinuxIdentity(DownloadTask task) async {
    final command = switch (task.kind) {
      'deb' => ('dpkg-deb', ['--field', task.filePath]),
      'rpm' => (
        'rpm',
        ['-qp', '--qf', 'Name: %{NAME}\nVersion: %{VERSION}\n', task.filePath],
      ),
      'pkg.tar.zst' => ('bsdtar', ['-xOf', task.filePath, '.PKGINFO']),
      _ => throw const FormatException('不支持此 Linux 更新格式。'),
    };
    final result = await Process.run(
      command.$1,
      command.$2,
      runInShell: false,
    ).timeout(const Duration(seconds: 30));
    final text = result.stdout.toString();
    final namePattern = task.kind == 'pkg.tar.zst'
        ? r'^pkgname = (.+)$'
        : r'^(?:Package|Name): (.+)$';
    final versionPattern = task.kind == 'pkg.tar.zst'
        ? r'^pkgver = (.+)$'
        : r'^Version: (.+)$';
    final name = RegExp(
      namePattern,
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final version = RegExp(
      versionPattern,
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    final base = task.version!.split('-').first;
    if (result.exitCode != 0 ||
        name != 'huarunwin' ||
        version == null ||
        !(version == task.version ||
            version == base ||
            version.startsWith('$base-'))) {
      throw const FormatException('软件包名称或版本与华润赢更新不匹配。');
    }
  }
}
