import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/models.dart';
import 'installed_apps.dart';
import 'package_integrity.dart';

typedef LinuxProcessRunner = Future<ProcessResult> Function(
  String,
  List<String>,
);
typedef LinuxProcessStarter = Future<void> Function(String, List<String>);

class LinuxSystemInfo {
  const LinuxSystemInfo({
    this.architecture,
    this.packageKind,
    this.distribution,
  });
  final String? architecture, packageKind, distribution;

  factory LinuxSystemInfo.parse(String release, String machine) {
    final values = <String, String>{};
    for (final line in release.split('\n')) {
      final equal = line.indexOf('=');
      if (equal <= 0 || line.trimLeft().startsWith('#')) continue;
      var value = line.substring(equal + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[line.substring(0, equal).trim()] = value;
    }
    String? kind;
    for (final id
        in '${values['ID'] ?? ''} ${values['ID_LIKE'] ?? ''}'
            .toLowerCase()
            .split(RegExp(r'\s+'))) {
      kind = switch (id) {
        'debian' || 'ubuntu' || 'linuxmint' || 'pop' || 'kali' => 'deb',
        'fedora' ||
        'rhel' ||
        'centos' ||
        'rocky' ||
        'almalinux' ||
        'opensuse' ||
        'suse' ||
        'sles' => 'rpm',
        'arch' || 'manjaro' || 'endeavouros' => 'pkg.tar.zst',
        _ => null,
      };
      if (kind != null) break;
    }
    return LinuxSystemInfo(
      architecture: switch (machine.trim().toLowerCase()) {
        'x86_64' || 'amd64' => 'x64',
        'aarch64' || 'arm64' => 'arm64',
        'i386' || 'i486' || 'i586' || 'i686' => 'x86',
        'armv7l' || 'armv7' => 'armv7',
        _ => null,
      },
      packageKind: kind,
      distribution: values['PRETTY_NAME'] ?? values['ID'],
    );
  }

  DownloadLink? recommended(List<DownloadLink> packages) {
    if (architecture == null) return null;
    for (final kind in [?packageKind, 'appimage']) {
      for (final arch in [architecture, 'universal']) {
        final matches = packages
            .where((v) => v.kind == kind && v.architecture == arch)
            .toList();
        if (matches.length == 1) return matches.single;
        if (matches.length > 1) return null;
      }
    }
    return null;
  }
}

/// Local operations use argument vectors and the user's own application folder.
class LinuxInstaller {
  LinuxInstaller({
    String? home,
    LinuxProcessRunner? run,
    LinuxProcessStarter? start,
    Future<String> Function(String)? readText,
  }) : home = home ?? Platform.environment['HOME'],
       run = run ?? _run,
       start = start ?? _start,
       readText = readText ?? ((path) => File(path).readAsString());

  final String? home;
  final LinuxProcessRunner run;
  final LinuxProcessStarter start;
  final Future<String> Function(String) readText;
  Future<LinuxSystemInfo>? _system;

  static Future<ProcessResult> _run(String executable, List<String> args) =>
      Process.run(
        executable,
        args,
        runInShell: false,
      ).timeout(const Duration(seconds: 30));
  static Future<void> _start(String executable, List<String> args) async {
    await Process.start(
      executable,
      args,
      mode: ProcessStartMode.detached,
      runInShell: false,
    );
  }

  Future<LinuxSystemInfo> systemInfo() => _system ??= _readSystem();
  Future<LinuxSystemInfo> _readSystem() async {
    var release = '', machine = '';
    try {
      release = await readText('/etc/os-release');
    } catch (_) {
      /* A portable AppImage remains an option. */
    }
    try {
      final result = await run('uname', ['-m']);
      if (result.exitCode == 0) machine = result.stdout.toString();
    } catch (_) {
      /* Unknown architecture must not be guessed. */
    }
    return LinuxSystemInfo.parse(release, machine);
  }

  /// Read the distribution database; launching an installer never supplies this
  /// identity or proves that the package is installed.
  Future<List<InstalledApplication>> installedApplications() async {
    final kind = (await systemInfo()).packageKind;
    final (String command, List<String> arguments) = switch (kind) {
      'deb' => (
        'dpkg-query',
        [
          '-W',
          r'-f=${Package}\t${Architecture}\t${Version}\t${db:Status-Status}\n',
        ],
      ),
      'rpm' => (
        'rpm',
        [
          '-qa',
          '--qf',
          r'%{NAME}\t%{ARCH}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n',
        ],
      ),
      'pkg.tar.zst' => ('pacman', ['-Q']),
      _ => ('', <String>[]),
    };
    if (command.isEmpty) return const [];
    final result = await run(command, arguments);
    if (result.exitCode != 0) {
      throw PlatformException(
        code: 'installed_apps',
        message: '无法读取系统软件包数据库，请刷新后重试。',
      );
    }
    final applications = <InstalledApplication>[];
    for (final line in result.stdout.toString().split('\n')) {
      final fields = line.trim().split(kind == 'pkg.tar.zst' ? ' ' : '\t');
      if (kind == 'pkg.tar.zst') {
        if (fields.length != 2 || !_packageToken(fields[0])) continue;
        applications.add(
          InstalledApplication(
            uninstallId: 'arch:${fields[0]}',
            version: fields[1],
            names: [fields[0]],
          ),
        );
      } else {
        if (fields.length < 3 ||
            !_packageToken(fields[0]) ||
            !_packageToken(fields[1]) ||
            kind == 'deb' && (fields.length != 4 || fields[3] != 'installed')) {
          continue;
        }
        applications.add(
          InstalledApplication(
            uninstallId:
                '${kind == 'deb' ? 'deb' : 'rpm'}:${fields[0]}:${fields[1]}'
                '${kind == 'rpm' ? ':${fields[2]}' : ''}',
            version: fields[2],
            names: [fields[0]],
          ),
        );
      }
    }
    return applications;
  }

  static bool _packageToken(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9+_.-]*$').hasMatch(value);

  Future<String?> _executable(String name) async {
    for (final root in ['/usr/bin', '/bin', '/usr/local/bin']) {
      final path = p.join(root, name);
      if (await File(path).exists()) return path;
    }
    return null;
  }

  Future<void> uninstallPackage(String identity, String? version) async {
    final matches = (await installedApplications()).where(
      (app) => app.uninstallId == identity,
    );
    if (matches.length != 1 || matches.single.version != version) {
      throw PlatformException(code: 'changed', message: '本机软件包已变化，请刷新后重新选择卸载。');
    }
    final parts = identity.split(':');
    String? executable;
    late List<String> arguments;
    switch (parts.first) {
      case 'deb':
        executable = await _executable('apt-get');
        arguments = ['remove', '--', '${parts[1]}:${parts[2]}'];
      case 'rpm':
        final dnf = await _executable('dnf');
        executable = dnf ?? await _executable('zypper');
        arguments = [
          'remove',
          '--',
          dnf != null
              ? '${parts[1]}-$version.${parts[2]}'
              : '${parts[1]}.${parts[2]}=$version',
        ];
      case 'arch':
        executable = await _executable('pacman');
        arguments = ['-R', '--', parts[1]];
      default:
        throw PlatformException(code: 'package', message: '无法确认软件包身份。');
    }
    final authorize = await _executable('pkexec');
    if (executable != null && authorize != null) {
      for (final (terminal, prefix) in [
        ('x-terminal-emulator', ['-e']),
        ('gnome-terminal', ['--']),
        ('konsole', ['-e']),
        ('xterm', ['-e']),
      ]) {
        final window = await _executable(terminal);
        if (window == null) continue;
        try {
          // The package manager retains its own dependency/confirmation prompt.
          // No shell, automatic yes, purge, or autoremove operation is used.
          await start(window, [...prefix, authorize, executable, ...arguments]);
          return;
        } on ProcessException {
          continue;
        }
      }
    }
    throw PlatformException(
      code: 'uninstall_unavailable',
      message: '未找到可用的系统终端、授权程序或包管理器，请在系统软件管理器中卸载所选软件包。',
    );
  }

  Future<void> _regularFile(String path) async {
    if (!p.isAbsolute(path) ||
        await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw PlatformException(
        code: 'package_path',
        message: '安装包不存在或不是普通文件，请重新下载。',
      );
    }
  }

  static String kind(String path) => path.toLowerCase().endsWith('.pkg.tar.zst')
      ? 'pkg.tar.zst'
      : p.extension(path).replaceFirst('.', '').toLowerCase();

  Future<void> openPackage(String path) async {
    await _regularFile(path);
    final format = kind(path);
    if (!['deb', 'rpm', 'pkg.tar.zst', 'zip'].contains(format)) {
      throw PlatformException(
        code: 'package_kind',
        message: '请使用对应的安装入口处理此文件。',
      );
    }
    final system = await systemInfo();
    if (format != 'zip' &&
        system.packageKind != null &&
        format != system.packageKind) {
      throw PlatformException(
        code: 'package_kind',
        message:
            '当前系统优先使用 ${system.packageKind!.toUpperCase()}，请选择对应安装包或 AppImage；不会自动转换软件包。',
      );
    }
    await _openUri(Uri.file(path));
  }

  Future<void> reveal(String path) async {
    await _regularFile(path);
    await _openUri(Uri.directory(p.dirname(path)));
  }

  Future<void> _openUri(Uri uri) async {
    try {
      final result = await run('xdg-open', [uri.toString()]);
      if (result.exitCode == 0) return;
    } catch (_) {
      /* Fall through to an actionable error. */
    }
    throw PlatformException(
      code: 'open_package',
      message: '系统没有可用的处理程序，或窗口未能打开。请查看安装包文件，使用软件中心、包管理器或解压工具手动处理。',
    );
  }

  Future<String> _root({bool create = true}) async {
    final userHome = home;
    if (userHome == null || !p.isAbsolute(userHome)) {
      throw PlatformException(code: 'home', message: '无法确认用户目录，不能安装 AppImage。');
    }
    final canonicalHome = await Directory(userHome).resolveSymbolicLinks();
    var current = canonicalHome;
    for (final component in ['Applications', 'HuarunWin']) {
      current = p.join(current, component);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.notFound && create) {
        await Directory(current).create();
      } else if (type != FileSystemEntityType.directory) {
        throw PlatformException(
          code: 'install_path',
          message: '用户应用目录包含符号链接或其他文件，请先处理后重试。',
        );
      }
    }
    return current;
  }

  Future<void> _validateAppImage(String path, String? architecture) async {
    await _regularFile(path);
    final input = await File(path).open();
    late Uint8List bytes;
    try {
      bytes = await input.read(64);
    } finally {
      await input.close();
    }
    if (bytes.length < 64 ||
        bytes[0] != 0x7f ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4c ||
        bytes[3] != 0x46 ||
        bytes[8] != 0x41 ||
        bytes[9] != 0x49 ||
        ![1, 2].contains(bytes[10]) ||
        ![1, 2].contains(bytes[4]) ||
        ![1, 2].contains(bytes[5])) {
      throw PlatformException(
        code: 'appimage',
        message: '文件不是可识别的 ELF AppImage，请重新选择安装包。',
      );
    }
    final machine = ByteData.sublistView(bytes)
        .getUint16(18, bytes[5] == 1 ? Endian.little : Endian.big);
    final expected = switch (architecture) {
      'x64' => (62, 2),
      'arm64' => (183, 2),
      'x86' => (3, 1),
      'armv7' => (40, 1),
      _ => null,
    };
    if (expected == null || machine != expected.$1 || bytes[4] != expected.$2) {
      throw PlatformException(
        code: 'architecture',
        message: 'AppImage 实际架构与当前设备不匹配或无法确认，请选择其他安装包。',
      );
    }
  }

  Future<void> validateSelfUpdateAppImage(String path) async =>
      _validateAppImage(path, (await systemInfo()).architecture);

  Future<String> installAppImage(
    String source, {
    String? expectedSha256,
  }) async {
    final system = await systemInfo();
    await _validateAppImage(source, system.architecture);
    final digest = await compute(packageSha256, source);
    if (expectedSha256 != null && digest != expectedSha256) {
      throw PlatformException(
        code: 'checksum',
        message: '安装包 SHA-256 不匹配，请重新下载。',
      );
    }
    final folder = await Directory(await _root()).createTemp('app-');
    try {
      final target = p.join(folder.path, 'Application.AppImage');
      await File(source).copy(target);
      if (await compute(packageSha256, target) != digest) {
        throw PlatformException(code: 'checksum', message: '安装包在复制期间已变化，请重试。');
      }
      await _validateAppImage(target, system.architecture);
      final mode = await run('chmod', ['700', target]);
      if (mode.exitCode != 0) {
        throw PlatformException(
          code: 'permission',
          message: '无法授予 AppImage 执行权限。',
        );
      }
      return target;
    } catch (_) {
      await folder.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> openAppImage(String path) async {
    final root = await _root();
    final parent = p.dirname(path);
    if (!p.isWithin(root, path) ||
        p.dirname(parent) != root ||
        await FileSystemEntity.type(parent, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw PlatformException(
        code: 'install_path',
        message: '应用不在受管理的用户安装目录内，请重新安装。',
      );
    }
    await _validateAppImage(path, (await systemInfo()).architecture);
    try {
      await start(path, const []);
    } catch (_) {
      throw PlatformException(
        code: 'launch',
        message: 'AppImage 未能启动，请检查系统兼容性和 FUSE 支持；安装文件已保留。',
      );
    }
  }

  Future<void> uninstallAppImage(String path) async {
    final root = await _root(create: false);
    final parent = p.dirname(path);
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.dirname(parent) != root ||
        !p.basename(parent).startsWith('app-') ||
        p.basename(path) != 'Application.AppImage' ||
        await FileSystemEntity.type(parent, followLinks: false) !=
            FileSystemEntityType.directory ||
        await File(path).resolveSymbolicLinks() != path) {
      throw PlatformException(
        code: 'install_path',
        message: '应用不在受管理的用户安装目录内，不能卸载。',
      );
    }
    await _regularFile(path);
    final trash = await _executable('gio');
    if (trash == null ||
        (await run(trash, ['trash', '--', path])).exitCode != 0) {
      throw PlatformException(
        code: 'trash',
        message: '无法移到系统回收站，请使用文件管理器处理；不会永久删除应用。',
      );
    }
    // Remove only the now-empty task folder, preserving any unexpected files.
    try {
      if (await Directory(parent).list().isEmpty) {
        await Directory(parent).delete();
      }
    } on FileSystemException {
      // The app has already moved to Trash; an empty folder is harmless.
    }
  }
}
