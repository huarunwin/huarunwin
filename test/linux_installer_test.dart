import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/linux_installer.dart';

class LinuxTask extends DownloadTask {
  LinuxTask(String path)
    : super(
        id: 'linux',
        appName: 'Linux Fixture',
        url: '',
        filePath: path,
        kind: 'appimage',
        platform: 'Linux',
        state: DownloadState.downloaded,
        createdAt: DateTime(2026, 10, 18),
      );
  @override
  bool get canInstall => canInstallOn('Linux');
}

Uint8List appImage({int machine = 62, int bits = 2, bool magic = true}) {
  final data = Uint8List(128);
  data.setRange(0, 7, [0x7f, 0x45, 0x4c, 0x46, bits, 1, 1]);
  if (magic) data.setRange(8, 11, [0x41, 0x49, 2]);
  ByteData.sublistView(data).setUint16(18, machine, Endian.little);
  return data;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LinuxInstaller installer;
  late List<(String, List<String>)> commands;
  late List<String> started;
  var chmodStatus = 0, openStatus = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-linux-');
    directory = Directory(await directory.resolveSymbolicLinks());
    commands = [];
    started = [];
    chmodStatus = 0;
    openStatus = 0;
    installer = LinuxInstaller(
      home: directory.path,
      readText: (_) async => 'ID=ubuntu\nPRETTY_NAME="Ubuntu"',
      run: (exe, args) async {
        commands.add((exe, List.of(args)));
        return ProcessResult(
          1,
          exe == 'chmod'
              ? chmodStatus
              : exe == 'xdg-open'
              ? openStatus
              : 0,
          exe == 'uname' ? 'x86_64\n' : '',
          '',
        );
      },
      start: (path, _) async {
        started.add(path);
      },
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<File> image({int machine = 62, int bits = 2, bool magic = true}) =>
      File('${directory.path}/Source App.AppImage')
          .writeAsBytes(appImage(machine: machine, bits: bits, magic: magic));

  test(
    'distribution parsing reads ID and ID_LIKE without evaluating shell',
    () {
      expect(
        LinuxSystemInfo.parse(
          'ID=custom\nID_LIKE="ubuntu debian"',
          'aarch64',
        ).packageKind,
        'deb',
      );
      expect(LinuxSystemInfo.parse('ID=rocky\n', 'x86_64').packageKind, 'rpm');
      expect(
        LinuxSystemInfo.parse('ID=arch\n', 'i686').packageKind,
        'pkg.tar.zst',
      );
      final unknown = LinuxSystemInfo.parse(
        'ID="\$(touch /tmp/anything)"',
        'riscv64',
      );
      expect(unknown.packageKind, isNull);
      expect(unknown.architecture, isNull);
    },
  );
  test('Linux recommendation considers package family, ABI and ambiguity', () {
    DownloadLink asset(String kind, String arch, [String extra = '']) =>
        DownloadLink(
          url: 'https://example.com/$arch$extra.$kind',
          label: kind,
          platform: 'Linux',
          kind: kind,
          architecture: arch,
        );
    final deb = asset('deb', 'x64'),
        rpm = asset('rpm', 'x64'),
        portable = asset('appimage', 'x64');
    final system = LinuxSystemInfo.parse('ID=ubuntu', 'x86_64');
    expect(system.recommended([rpm, portable, deb]), deb);
    expect(system.recommended([rpm, portable]), portable);
    expect(system.recommended([rpm]), isNull);
    expect(system.recommended([deb, asset('deb', 'x64', '-other')]), isNull);
    expect(
      LinuxSystemInfo.parse(
        'ID=unknown',
        'x86_64',
      ).recommended([rpm, portable]),
      portable,
    );
  });
  test(
    'AppImage copies to a unique user directory and never runs during install',
    () async {
      final source = await image();
      final first = await installer.installAppImage(source.path);
      final second = await installer.installAppImage(source.path);
      expect(first, isNot(second));
      expect(
        first,
        startsWith(p.join(directory.path, 'Applications', 'HuarunWin', 'app-')),
      );
      expect(await File(first).readAsBytes(), await source.readAsBytes());
      expect(commands.where((v) => v.$1 == 'chmod').first.$2, ['700', first]);
      expect(started, isEmpty);
      await installer.openAppImage(first);
      expect(started, [first]);
      expect(await source.exists(), isTrue);
    },
  );
  for (final entry in [(183, 2, true), (62, 1, true), (62, 2, false)]) {
    test(
      'invalid AppImage architecture or header $entry never gains execute permission',
      () async {
        final source = await image(
          machine: entry.$1,
          bits: entry.$2,
          magic: entry.$3,
        );
        await expectLater(
          installer.installAppImage(source.path),
          throwsA(isA<PlatformException>()),
        );
        expect(commands.any((v) => v.$1 == 'chmod'), isFalse);
        expect(started, isEmpty);
      },
    );
  }
  test(
    'AppImage checksum failure preserves source and unrelated files',
    () async {
      final source = await image();
      await expectLater(
        installer.installAppImage(source.path, expectedSha256: 'a' * 64),
        throwsA(isA<PlatformException>()),
      );
      expect(await source.exists(), isTrue);
      expect(
        await Directory('${directory.path}/Applications').exists(),
        isFalse,
      );
    },
  );
  test('failed chmod cleans only its new temporary installation', () async {
    final source = await image();
    final previous = await installer.installAppImage(source.path);
    chmodStatus = 1;
    await expectLater(
      installer.installAppImage(source.path),
      throwsA(isA<PlatformException>()),
    );
    expect(await File(previous).exists(), isTrue);
    expect(
      await Directory('${directory.path}/Applications/HuarunWin').list().length,
      1,
    );
  });
  test(
    'symlinks cannot redirect the managed application directory',
    () async {
      final outside = await Directory('${directory.path}/other').create();
      await Link('${directory.path}/Applications').create(outside.path);
      final source = await image();
      await expectLater(
        installer.installAppImage(source.path),
        throwsA(isA<PlatformException>()),
      );
      expect(await outside.list().isEmpty, isTrue);
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );
  test('system packages use a URI argument, retain files, and never convert formats', () async {
    final source = await File('${directory.path}/A \$package; name.deb')
        .writeAsString('fixture');
    await installer.openPackage(source.path);
    expect(commands.last.$1, 'xdg-open');
    expect(commands.last.$2, [Uri.file(source.path).toString()]);
    final foreign = await File('${directory.path}/foreign.rpm')
        .writeAsString('fixture');
    await expectLater(
      installer.openPackage(foreign.path),
      throwsA(isA<PlatformException>()),
    );
    expect(commands.where((v) => v.$1 == 'xdg-open').length, 1);
    openStatus = 1;
    await expectLater(
      installer.openPackage(source.path),
      throwsA(isA<PlatformException>()),
    );
    expect(await source.exists(), isTrue);
    expect(started, isEmpty);
  });
  test(
    'manager refresh and record deletion preserve the installed AppImage',
    () async {
      final downloads = await Directory('${directory.path}/downloads').create();
      final manager = DownloadManager(
        downloads,
        installer: NativeInstaller(linuxInstaller: installer),
      );
      addTearDown(() async {
        await manager.flushHistory();
        manager.dispose();
        manager.client.close(force: true);
        manager.macResolver.client.close(force: true);
      });
      final source = await image();
      await manager.importFile(source, platform: 'Linux');
      final task = LinuxTask(manager.tasks.single.filePath);
      manager.tasks
        ..clear()
        ..add(task);
      await manager.install(task);
      expect(task.state, DownloadState.installed);
      expect(task.installedPath, isNotNull);
      expect(started, isEmpty);
      await File(task.filePath).delete();
      await manager.refresh();
      expect(task.state, DownloadState.installed);
      expect(task.packageAvailable, isFalse);
      await manager.remove(task);
      expect(await File(task.installedPath!).exists(), isTrue);
      expect(await source.exists(), isTrue);
    },
  );
  test(
    'Linux imports Arch compound extensions and rejects unrelated archives',
    () async {
      final manager = DownloadManager(
        directory,
        installer: NativeInstaller(linuxInstaller: installer),
      );
      addTearDown(() async {
        await manager.flushHistory();
        manager.dispose();
        manager.client.close(force: true);
        manager.macResolver.client.close(force: true);
      });
      final source = await File('${directory.path}/application.pkg.tar.zst')
          .writeAsString('fixture');
      await manager.importFile(source, platform: 'Linux');
      expect(manager.tasks.single.kind, 'pkg.tar.zst');
      await expectLater(
        manager.importFile(
          File('${directory.path}/random.tar.zst'),
          platform: 'Linux',
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'AppImage applies actual owner-only permissions to the temporary copy',
    () async {
      final source = await image();
      final local = LinuxInstaller(
        home: directory.path,
        readText: (_) async => 'ID=ubuntu',
        run: (exe, args) async => exe == 'uname'
            ? ProcessResult(1, 0, 'x86_64', '')
            : Process.run(exe, args, runInShell: false),
        start: (_, _) async =>
            fail('Installation must not execute the AppImage'),
      );
      final installed = await local.installAppImage(source.path);
      expect((await File(installed).stat()).mode & 511, 448);
    },
    skip: Platform.isWindows,
  );

  test('Linux system handoff persists without claiming installation', () async {
    final manager = DownloadManager(
      directory,
      installer: NativeInstaller(linuxInstaller: installer),
    );
    addTearDown(() async {
      await manager.flushHistory();
      manager.dispose();
      manager.client.close(force: true);
      manager.macResolver.client.close(force: true);
    });
    final source = await File('${directory.path}/fixture.deb')
        .writeAsString('fixture');
    await manager.importFile(source, platform: 'Linux');
    final task = manager.tasks.single;
    await manager.handOff(task);
    expect(task.state, DownloadState.handedOff);
    expect(task.installedPath, isNull);
    await manager.refresh();
    await manager.flushHistory();
    manager.tasks.clear();
    await manager.restore();
    expect(manager.tasks.single.state, DownloadState.handedOff);
    expect(manager.tasks.single.installedPath, isNull);
  });

  test(
    'an unowned AppImage or a source symlink cannot be launched or installed',
    () async {
      final source = await image();
      await expectLater(
        installer.openAppImage(source.path),
        throwsA(isA<PlatformException>()),
      );
      final link = await Link('${directory.path}/linked.AppImage')
          .create(source.path);
      await expectLater(
        installer.installAppImage(link.path),
        throwsA(isA<PlatformException>()),
      );
      expect(started, isEmpty);
      expect(commands.any((v) => v.$1 == 'chmod'), isFalse);
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );
}
