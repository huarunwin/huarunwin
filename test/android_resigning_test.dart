import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:path/path.dart' as p;

import 'downloads_test.dart' show PackageAdapter, finished;

const key = AndroidSigningKey(
  id: 'local-key',
  label: '本机密钥',
  certificateSha256: 'cert',
);
const app = CatalogApp(
  id: 'fixture',
  name: 'Fixture',
  url: 'https://huarun.win/apps/fixture',
);
const source = [1, 2, 3, 4];
const signed = [5, 6, 7, 8];
final sourceDigest = sha256.convert(source).toString();
final signedDigest = sha256.convert(signed).toString();

class AndroidSignedTask extends DownloadTask {
  AndroidSignedTask(DownloadTask task)
    : super(
        id: task.id,
        appName: task.appName,
        url: task.url,
        filePath: task.filePath,
        kind: task.kind,
        createdAt: task.createdAt,
        platform: 'Android',
        state: task.state,
        resignKey: task.resignKey,
        resignedSha256: task.resignedSha256,
        sha256: task.sha256,
        verifiedSha256: task.verifiedSha256,
      );
  @override
  bool get canInstall => canInstallOn('Android');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadManager manager;
  late List<MethodCall> calls;
  late int downloads;
  DownloadLink link({String? digest}) => DownloadLink(
    url: 'https://example.com/fixture.apk',
    label: 'fixture.apk',
    kind: 'apk',
    platform: 'Android',
    sha256: digest ?? sourceDigest,
  );
  void native(Future<Object?> Function(MethodCall) response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          return response(call);
        });
  }

  Future<Object?> resign(MethodCall call) async {
    expect(call.method, 'resignApk');
    expect(call.arguments['expectedSourceSha256'], sourceDigest);
    expect(call.arguments['expectedCertificateSha256'], key.certificateSha256);
    expect(call.arguments['keyId'], anyOf(key.id, 'other'));
    final original = File(call.arguments['path'] as String);
    expect(await original.readAsBytes(), source);
    final output = File(
      p.join(
        original.parent.path,
        '${p.basenameWithoutExtension(original.path)}-huarun-sign.apk',
      ),
    );
    await output.parent.create(recursive: true);
    await output.writeAsBytes(signed);
    return {
      'sha256': signedDigest,
      'certificateSha256': key.certificateSha256,
      'packageName': call.arguments['packageName'] ?? 'test.app',
      'sourcePackageName': 'test.app',
    };
  }

  DownloadManager createManager() {
    final client = Dio()
      ..httpClientAdapter = PackageAdapter(() {
        downloads++;
        return ResponseBody.fromBytes(source, 200);
      });
    return DownloadManager(directory, client: client);
  }

  Future<void> restart() async {
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    manager = createManager();
    await manager.restore();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-resign-test');
    calls = [];
    downloads = 0;
    manager = createManager();
    native(resign);
  });
  tearDown(() async {
    await manager.flushHistory();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    await directory.delete(recursive: true);
  });

  test('renamed copies persist identity, remain distinct and retry with the same package', () async {
    final first = await manager.download(
      app,
      link(),
      resignKey: key,
      resignPackageName: 'test.app.personal',
    );
    await finished(manager, first);
    expect(first.resignReady, isTrue);
    expect(calls.last.arguments['packageName'], 'test.app.personal');
    expect(first.originalPackageName, 'test.app');
    final existing = await manager.download(
      app,
      link(),
      resignKey: key,
      resignPackageName: 'test.app.personal',
    );
    expect(existing, same(first));
    final second = await manager.download(
      app,
      link(),
      resignKey: key,
      resignPackageName: 'test.app.second',
    );
    await finished(manager, second);
    expect(second, isNot(same(first)));
    await manager.flushHistory();
    await restart();
    final restored = manager.tasks.singleWhere((task) => task.id == first.id);
    expect(restored.resignPackageName, 'test.app.personal');
    expect(restored.originalPackageName, 'test.app');
    expect(restored.resignKey!.id, key.id);
    await manager.retry(restored);
    expect(calls.last.arguments['packageName'], 'test.app.personal');
    expect(downloads, 2);
    expect(await File(restored.filePath).readAsBytes(), source);
    await File('${restored.resignedFilePath}.unsigned').writeAsBytes([9]);
    await manager.remove(restored, packages: {DownloadPackage.resigned});
    expect(
      await File('${restored.resignedFilePath}.unsigned').exists(),
      isFalse,
    );
    expect(await File(restored.filePath).readAsBytes(), source);
  });

  test(
    'a signed result with the wrong package is discarded without falling back',
    () async {
      native(
        (call) async => {
          ...Map<String, Object?>.from(await resign(call) as Map),
          'packageName': 'test.app.unexpected',
        },
      );
      final task = await manager.download(
        app,
        link(),
        resignKey: key,
        resignPackageName: 'test.app.personal',
      );
      await finished(manager, task);
      expect(task.resignReady, isFalse);
      expect(task.canInstallOn('Android'), isFalse);
      expect(await File(task.resignedFilePath).exists(), isFalse);
      expect(await File(task.filePath).readAsBytes(), source);
      expect(task.resignPackageName, 'test.app.personal');
    },
  );

  test('invalid package input never creates a download task', () async {
    await expectLater(
      manager.download(
        app,
        link(),
        resignKey: key,
        resignPackageName: 'test.1invalid',
      ),
      throwsFormatException,
    );
    await expectLater(
      manager.download(app, link(), resignPackageName: 'test.app.personal'),
      throwsFormatException,
    );
    expect(manager.tasks, isEmpty);
    expect(downloads, 0);
    expect(calls, isEmpty);
  });

  test(
    'all APK kinds can produce independent copies across restore and deletion',
    () async {
      const otherKey = AndroidSigningKey(
        id: 'other',
        label: '另一把个人密钥',
        certificateSha256: 'other-cert',
      );
      final identities = <String, (String, String)>{
        sourceDigest: ('test.app', 'official-cert'),
      };
      var sequence = 10;
      native((call) async {
        final input = File(call.arguments['path'] as String);
        final bytes = await input.readAsBytes();
        final digest = sha256.convert(bytes).toString();
        final (name, certificate) = identities[digest]!;
        if (call.method == 'inspectApk') {
          return {
            'packageName': name,
            'fileSha256': digest,
            'certificateSha256': [certificate],
          };
        }
        expect(call.method, 'resignApk');
        expect(call.arguments['expectedSourceSha256'], digest);
        final target = call.arguments['packageName'] as String? ?? name;
        final targetCertificate =
            call.arguments['expectedCertificateSha256'] as String;
        final output = File(
          p.join(
            input.parent.path,
            '${p.basenameWithoutExtension(input.path)}-huarun-sign.apk',
          ),
        );
        final outputBytes = [...bytes, sequence++];
        await output.writeAsBytes(outputBytes);
        final outputDigest = sha256.convert(outputBytes).toString();
        identities[outputDigest] = (target, targetCertificate);
        return {
          'sha256': outputDigest,
          'certificateSha256': targetCertificate,
          'sourcePackageName': name,
          'packageName': target,
        };
      });
      final first = await manager.download(app, link(), resignKey: key);
      await finished(manager, first);
      final signedBytes = await File(first.resignedFilePath).readAsBytes();
      await manager.inspectApk(first, package: DownloadPackage.original);
      final renamed = await manager.resignForInstallation(
        first,
        key,
        package: DownloadPackage.original,
        packageName: 'test.app.clone',
      );
      expect(
        manager.entries.map((e) => e.task.packageLabel(e.package!)),
        unorderedEquals(['原始包', '重签包', '改包重签']),
      );
      expect(renamed.androidPackages, [DownloadPackage.resigned]);
      final descendants = <DownloadTask>[];
      for (final (input, package, target) in [
        (first, DownloadPackage.original, null),
        (first, DownloadPackage.resigned, 'test.app.second'),
        (first, DownloadPackage.resigned, null),
        (renamed, DownloadPackage.resigned, null),
        (renamed, DownloadPackage.resigned, 'test.app.next'),
        (renamed, DownloadPackage.resigned, 'test.app'),
      ]) {
        final before = await File(input.packagePath(package)).readAsBytes();
        final info = await manager.inspectApk(input, package: package);
        final result = await manager.resignForInstallation(
          input,
          otherKey,
          package: package,
          packageName: target,
        );
        descendants.add(result);
        expect(result, isNot(same(input)));
        expect(result.resignedPackageName, target ?? info.packageName);
        expect(result.rootPackageName, 'test.app');
        expect(
          result.packageLabel(DownloadPackage.resigned),
          (target ?? info.packageName) == 'test.app' ? '重签包' : '改包重签',
        );
        expect(result.resignKey, otherKey);
        expect(await File(input.packagePath(package)).readAsBytes(), before);
      }
      final descendant = descendants[3];
      expect(descendant.resignPackageName, isNull);
      expect(descendant.resignedPackageName, 'test.app.clone');
      expect(await File(first.filePath).readAsBytes(), source);
      expect(await File(first.resignedFilePath).readAsBytes(), signedBytes);
      await manager.remove(renamed, packages: {DownloadPackage.resigned});
      expect(await File(renamed.filePath).exists(), isFalse);
      expect(manager.tasks, isNot(contains(renamed)));
      await manager.flushHistory();
      await restart();
      final restored = manager.tasks.singleWhere((t) => t.id == descendant.id);
      expect(restored.androidPackages, [DownloadPackage.resigned]);
      expect(restored.packageLabel(DownloadPackage.resigned), '改包重签');
      expect(restored.resignKey!.id, otherKey.id);
      await manager.retry(restored);
      expect(restored.resignedPackageName, 'test.app.clone');
      expect(restored.resignReady, isTrue);
      await File('${restored.resignedFilePath}.unsigned').writeAsBytes([9]);
      await manager.remove(restored, packages: {DownloadPackage.resigned});
      expect(await File(restored.filePath).parent.exists(), isFalse);
      expect(await File(first.filePath).readAsBytes(), source);
      expect(await File(first.resignedFilePath).readAsBytes(), signedBytes);
      expect(downloads, 1);
    },
  );

  test(
    'a signed input changed after confirmation creates no derived task',
    () async {
      final task = await manager.download(app, link(), resignKey: key);
      await finished(manager, task);
      native(
        (_) async => {
          'packageName': 'test.app',
          'fileSha256': signedDigest,
          'certificateSha256': [key.certificateSha256],
        },
      );
      await manager.inspectApk(task, package: DownloadPackage.resigned);
      await File(task.resignedFilePath).writeAsBytes([9]);
      calls.clear();
      await expectLater(
        manager.resignForInstallation(
          task,
          key,
          package: DownloadPackage.resigned,
          packageName: 'test.app.clone',
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
      expect(manager.tasks, [task]);
      expect(await File(task.filePath).readAsBytes(), source);
      expect(task.checking, isFalse);
    },
  );

  test('keeps original public hash separate from the signed copy and persists key identity', () async {
    final task = await manager.download(app, link(), resignKey: key);
    await finished(manager, task);
    expect(task.state, DownloadState.downloaded);
    expect(task.canInstallOn('Android'), isTrue);
    expect(task.verifiedSha256, sourceDigest);
    expect(task.sha256, sourceDigest);
    expect(task.resignedSha256, signedDigest);
    expect(await File(task.filePath).readAsBytes(), source);
    expect(
      task.resignedFilePath,
      p.join(File(task.filePath).parent.path, 'fixture-huarun-sign.apk'),
    );
    expect(await File(task.installationFilePath).readAsBytes(), signed);
    final restored = DownloadTask.fromJson(task.toJson());
    expect(restored.resignKey!.id, key.id);
    expect(restored.resignedSha256, signedDigest);
    expect(restored.installationFilePath, task.resignedFilePath);
    expect(restored.checksumVerified, isTrue);
    await manager.remove(task);
    expect(await File(task.filePath).parent.exists(), isFalse);
  });

  Future<DownloadTask> legacyTask() async {
    final task = DownloadTask(
      id: 'legacy',
      appName: 'Fixture',
      url: link().url,
      filePath: '${directory.path}/legacy/fixture.apk',
      kind: 'apk',
      platform: 'Android',
      createdAt: DateTime(2026, 10, 18),
      state: DownloadState.downloaded,
      resignKey: key,
      sha256: sourceDigest,
      verifiedSha256: sourceDigest,
      resignedSha256: signedDigest,
    );
    final legacyPath = '${directory.path}/legacy/resigned/fixture.apk';
    await File(legacyPath).parent.create(recursive: true);
    await File(task.filePath).writeAsBytes(source);
    await File(legacyPath).writeAsBytes(signed);
    await File(
      '${directory.path}/tasks.json',
    ).writeAsString(jsonEncode([task.toJson()..remove('resignedFileLayout')]));
    await manager.restore();
    return manager.tasks.single;
  }

  for (final legacy in [false, true]) {
    for (final package in DownloadPackage.values) {
      test(
        'selectively deletes $package (${legacy ? 'legacy' : 'sibling'}) and restores the retained package',
        () async {
          final task = legacy
              ? await legacyTask()
              : await manager.download(app, link(), resignKey: key);
          if (!legacy) await finished(manager, task);
          final signedPath = task.resignedFilePath;
          expect(await manager.packagesForRemoval(task), {
            DownloadPackage.original,
            DownloadPackage.resigned,
          });
          await manager.remove(task, packages: {package});
          expect(manager.tasks, [task]);
          expect(task.resignKey!.id, key.id);
          final keepSigned = package == DownloadPackage.original;
          expect(await File(task.filePath).exists(), !keepSigned);
          expect(await File(signedPath).exists(), keepSigned);
          expect(task.originalAvailable, !keepSigned);
          expect(task.packageAvailable, keepSigned);
          expect(task.canInstallOn('Android'), keepSigned);
          await manager.flushHistory();
          await restart();
          await manager.refresh();
          final restored = manager.tasks.single;
          expect(restored.resignKey!.id, key.id);
          expect(restored.originalAvailable, !keepSigned);
          expect(restored.packageAvailable, keepSigned);
          expect(restored.canInstallOn('Android'), keepSigned);
          if (keepSigned) {
            expect(
              await File(restored.installationFilePath).readAsBytes(),
              signed,
            );
          } else {
            expect(restored.installationFilePath, signedPath);
            expect(restored.error, contains('重签包已删除'));
            final previousDownloads = downloads;
            await manager.retry(restored);
            expect(downloads, previousDownloads);
            expect(restored.canInstallOn('Android'), isTrue);
            expect(
              await File(restored.installationFilePath).readAsBytes(),
              signed,
            );
          }
          await manager.remove(restored);
          expect(manager.tasks, isEmpty);
          expect(await File(restored.filePath).parent.exists(), isFalse);
        },
      );
    }
  }

  test(
    'empty deletion selection preserves files, state and key identity',
    () async {
      final task = await manager.download(app, link(), resignKey: key);
      await finished(manager, task);
      final saved = task.toJson();
      await manager.remove(task, packages: {});
      expect(task.toJson(), saved);
      expect(manager.tasks, [task]);
      expect(await File(task.filePath).readAsBytes(), source);
      expect(await File(task.resignedFilePath).readAsBytes(), signed);
      await File(task.filePath).delete();
      expect(await manager.packagesForRemoval(task), {
        DownloadPackage.resigned,
      });
      await manager.remove(task, packages: {DownloadPackage.resigned});
      expect(manager.tasks, isEmpty);
    },
  );

  test(
    'partial deletion preserves installed Android package identity',
    () async {
      final task = await manager.download(app, link(), resignKey: key);
      await finished(manager, task);
      task.state = DownloadState.installed;
      task.installedPackage = 'test.fixture';
      calls.clear();
      await manager.remove(task, packages: {DownloadPackage.resigned});
      expect(task.state, DownloadState.installed);
      expect(task.installedPackage, 'test.fixture');
      expect(task.originalAvailable, isTrue);
      expect(task.packageAvailable, isFalse);
      expect(await File(task.filePath).readAsBytes(), source);
      expect(calls, isEmpty);
      await manager.remove(task, packages: {DownloadPackage.original});
      expect(manager.tasks, isEmpty);
      expect(calls, isEmpty);
    },
  );

  test(
    'legacy signed copies survive restart, verification, handoff and deletion',
    () async {
      final task = await legacyTask();
      final legacyPath = p.join(
        '${directory.path}/legacy',
        'resigned',
        'fixture.apk',
      );
      expect(task.installationFilePath, legacyPath);
      expect(
        DownloadTask.fromJson(task.toJson()).installationFilePath,
        legacyPath,
      );
      await manager.refresh();
      expect(task.canInstallOn('Android'), isTrue);
      native(
        (call) async => call.method == 'inspectApk'
            ? {
                'packageName': 'test.app',
                'fileSha256': signedDigest,
                'certificateSha256': ['cert'],
              }
            : true,
      );
      await manager.inspectApk(task);
      await manager.handOff(task);
      expect(calls.last.method, 'openPackage');
      expect(calls.last.arguments['path'], legacyPath);
      expect(calls.last.arguments['expectedSha256'], signedDigest);
      expect(task.state, DownloadState.handedOff);
      expect(await File(task.filePath).readAsBytes(), source);
      await manager.remove(task);
      expect(await File(task.filePath).parent.exists(), isFalse);
    },
  );

  test('retrying a legacy copy adopts the sibling filename and preserves the original', () async {
    final task = await legacyTask();
    final legacyPath = task.resignedFilePath;
    await manager.retry(task);
    expect(
      task.resignedFilePath,
      p.join('${directory.path}/legacy', 'fixture-huarun-sign.apk'),
    );
    expect(task.canInstallOn('Android'), isTrue);
    expect(downloads, 0);
    expect(await File(legacyPath).exists(), isFalse);
    expect(await File(task.filePath).readAsBytes(), source);
    expect(await File(task.installationFilePath).readAsBytes(), signed);
    await manager.flushHistory();
    await restart();
    expect(manager.tasks.single.installationFilePath, task.resignedFilePath);
    expect(manager.tasks.single.canInstallOn('Android'), isTrue);
  });

  test(
    'public checksum failure never reaches signing and discards partial data',
    () async {
      final task = await manager.download(
        app,
        link(digest: '0' * 64),
        resignKey: key,
      );
      await finished(manager, task);
      expect(task.state, DownloadState.failed);
      expect(calls, isEmpty);
      expect(task.canInstallOn('Android'), isFalse);
      expect(await File(task.filePath).exists(), isFalse);
      expect(await File('${task.filePath}.part').exists(), isFalse);
    },
  );

  test('failure retains a verified original; retry signs it without another download', () async {
    native((_) async => throw PlatformException(code: 'sign', message: '重签失败'));
    final task = await manager.download(app, link(), resignKey: key);
    await finished(manager, task);
    expect(task.state, DownloadState.downloaded);
    expect(task.error, '重签失败');
    expect(task.canInstallOn('Android'), isFalse);
    expect(task.canHandOff, isFalse);
    expect(await File(task.filePath).readAsBytes(), source);
    native(resign);
    await manager.retry(task);
    expect(downloads, 1);
    expect(task.error, isNull);
    expect(task.canInstallOn('Android'), isTrue);
  });

  test('source mutation before retry blocks signing', () async {
    native((_) async => throw PlatformException(code: 'sign'));
    final task = await manager.download(app, link(), resignKey: key);
    await finished(manager, task);
    calls.clear();
    await File(task.filePath).writeAsBytes([9]);
    await manager.retry(task);
    expect(calls, isEmpty);
    expect(task.state, DownloadState.failed);
    expect(task.verifiedSha256, isNull);
    expect(task.error, contains('已变化'));
  });

  test(
    'cancelling during signing waits for cleanup and never publishes the copy',
    () async {
      final begun = Completer<MethodCall>();
      final release = Completer<void>();
      native((call) async {
        begun.complete(call);
        await release.future;
        return resign(call);
      });
      final task = await manager.download(app, link(), resignKey: key);
      await begun.future;
      expect(task.state, DownloadState.resigning);
      manager.cancel(task);
      expect(task.busy, isTrue);
      release.complete();
      await finished(manager, task);
      expect(task.state, DownloadState.cancelled);
      expect(task.resignedSha256, isNull);
      expect(await File(task.resignedFilePath).exists(), isFalse);
      expect(await File(task.filePath).readAsBytes(), source);
      native(resign);
      await manager.retry(task);
      expect(downloads, 1);
      expect(task.canInstallOn('Android'), isTrue);
    },
  );

  test(
    'reboot recovers interrupted signing, refresh never installs the raw APK',
    () async {
      final task = await manager.download(app, link(), resignKey: key);
      await finished(manager, task);
      task.state = DownloadState.resigning;
      task.resignedSha256 = null;
      await File('${directory.path}/tasks.json')
          .writeAsString(jsonEncode([task.toJson()]));
      await restart();
      final restored = manager.tasks.single;
      expect(restored.state, DownloadState.downloaded);
      expect(restored.error, contains('重签已中断'));
      await manager.refresh();
      expect(restored.canInstallOn('Android'), isFalse);
      await manager.retry(restored);
      expect(restored.resignedSha256, signedDigest);
      expect(downloads, 1);
      await File(restored.resignedFilePath).delete();
      await manager.refresh();
      expect(restored.canInstallOn('Android'), isFalse);
      expect(restored.originalAvailable, isTrue);
      await manager.retry(restored);
      expect(restored.canInstallOn('Android'), isTrue);
    },
  );

  test(
    'same URL with original or different key creates distinct managed tasks',
    () async {
      final original = await manager.download(app, link());
      await finished(manager, original);
      final task = await manager.download(app, link(), resignKey: key);
      await finished(manager, task);
      expect(task, isNot(same(original)));
      expect(await manager.download(app, link(), resignKey: key), same(task));
      const otherKey = AndroidSigningKey(
        id: 'other',
        label: 'Other',
        certificateSha256: 'cert',
      );
      final other = await manager.download(app, link(), resignKey: otherKey);
      await finished(manager, other);
      expect(other, isNot(same(task)));
      expect(manager.tasks, hasLength(3));
    },
  );

  test(
    'a symbolic signing directory is rejected without deleting another task',
    () async {
      final task = await legacyTask();
      await File(task.resignedFilePath).parent.delete(recursive: true);
      final other = await Directory('${directory.path}/other-task').create();
      final otherApk = File('${other.path}/fixture.apk');
      await otherApk.writeAsBytes([9, 8, 7]);
      await Link(File(task.resignedFilePath).parent.path).create(other.path);
      calls.clear();
      await manager.retry(task);
      expect(calls, isEmpty);
      expect(task.error, contains('目录无效'));
      await expectLater(
        manager.remove(task),
        throwsA(isA<FileSystemException>()),
      );
      expect(await otherApk.readAsBytes(), [9, 8, 7]);
      expect(await File(task.filePath).readAsBytes(), source);
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );

  test(
    'signed APK installation and handoff use the derived file and its digest',
    () async {
      final downloaded = await manager.download(app, link(), resignKey: key);
      await finished(manager, downloaded);
      final task = AndroidSignedTask(downloaded);
      manager.tasks
        ..clear()
        ..add(task);
      native(
        (call) async => switch (call.method) {
          'inspectApk' => {
            'packageName': 'test.app',
            'fileSha256': signedDigest,
            'certificateSha256': ['cert'],
          },
          'installApk' => 'test.app',
          _ => true,
        },
      );
      await manager.inspectApk(task);
      await manager.install(task);
      expect(calls.last.method, 'installApk');
      expect(calls.last.arguments, {
        'path': task.resignedFilePath,
        'expectedSha256': signedDigest,
      });
      task.state = DownloadState.downloaded;
      await manager.handOff(task);
      expect(calls.last.arguments['path'], task.resignedFilePath);
      expect(calls.last.arguments['expectedSha256'], signedDigest);
      expect(task.state, DownloadState.handedOff);
      await File(task.resignedFilePath).writeAsBytes([9]);
      calls.clear();
      await expectLater(
        manager.inspectApk(task),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, isEmpty);
      expect(task.verifiedSha256, sourceDigest);
    },
  );

  test('installation-time signing uses the inspected local APK without downloading', () async {
    final task = await manager.download(app, link());
    await finished(manager, task);
    calls.clear();
    native(
      (call) async => call.method == 'inspectApk'
          ? {'packageName': 'test.app', 'fileSha256': sourceDigest}
          : await resign(call),
    );
    await manager.inspectApk(task);
    await manager.resignForInstallation(task, key);
    expect(task.resignKey, key);
    expect(task.resignReady, isTrue);
    expect(task.resignedSha256, signedDigest);
    expect(downloads, 1);
    expect(calls.map((call) => call.method), ['inspectApk', 'resignApk']);
    expect(await File(task.filePath).readAsBytes(), source);
  });

  test(
    'changed original and failed signing cannot silently install original',
    () async {
      final task = await manager.download(app, link());
      await finished(manager, task);
      native(
        (_) async => {'packageName': 'test.app', 'fileSha256': sourceDigest},
      );
      await manager.inspectApk(task);
      await File(task.filePath).writeAsBytes([9]);
      calls.clear();
      await expectLater(
        manager.resignForInstallation(task, key),
        throwsFormatException,
      );
      expect(calls, isEmpty);
      expect(task.resignKey, isNull);
      await File(task.filePath).writeAsBytes(source);
      native(
        (_) async => throw PlatformException(code: 'sign', message: '重签失败'),
      );
      await expectLater(
        manager.resignForInstallation(task, key),
        throwsA(isA<PlatformException>()),
      );
      expect(task.resignKey, key);
      expect(task.resignReady, isFalse);
      expect(task.canInstallOn('Android'), isFalse);
      expect(task.canHandOff, isFalse);
      expect(await File(task.filePath).readAsBytes(), source);
      expect(downloads, 1);
    },
  );
}
