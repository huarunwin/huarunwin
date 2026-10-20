import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/downloads.dart';

const abcSha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const app = CatalogApp(
  id: 'fixture',
  name: 'Fixture',
  url: 'https://huarun.win/apps/fixture',
);

class ControlledPackages implements HttpClientAdapter {
  bool closing = false;
  final requests = <String>[];
  final responses = <String, Completer<ResponseBody>>{};
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) {
    final name = options.uri.pathSegments.last;
    requests.add(name);
    if (closing) return Future.value(ResponseBody.fromString('', 503));
    return responses.putIfAbsent(name, Completer<ResponseBody>.new).future;
  }

  void finish(String name, {int status = 200}) => responses[name]!.complete(
    ResponseBody.fromString(
      'abc',
      status,
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['3'],
      },
    ),
  );
  @override
  void close({bool force = false}) {
    closing = true;
    for (final response in responses.values) {
      if (!response.isCompleted) {
        response.complete(ResponseBody.fromString('', 503));
      }
    }
  }
}

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Download did not reach the expected state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadManager manager;
  late ControlledPackages adapter;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-reliable-');
    adapter = ControlledPackages();
    manager = DownloadManager(
      directory,
      client: Dio()..httpClientAdapter = adapter,
    );
  });
  tearDown(() async {
    adapter.close(force: true);
    await until(() => manager.tasks.every((task) => !task.busy));
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
    await directory.delete(recursive: true);
  });

  DownloadLink link(String name, {String? digest}) => DownloadLink(
    url: 'https://example.com/$name.zip',
    label: name,
    platform: 'macOS',
    kind: 'zip',
    sha256: digest,
  );

  test('three active transfers queue the rest and queued cancellation or deletion never starts a request', () async {
    final tasks = <DownloadTask>[];
    for (var i = 0; i < 6; i++) {
      tasks.add(await manager.download(app, link('$i')));
    }
    await until(() => adapter.requests.length == 3);
    expect(tasks[3].state, DownloadState.queued);
    expect(tasks[4].state, DownloadState.queued);
    await manager.remove(tasks[3]).timeout(const Duration(seconds: 2));
    manager.cancel(tasks[4]);
    expect(tasks[4].state, DownloadState.cancelled);
    expect(adapter.requests, ['0.zip', '1.zip', '2.zip']);
    adapter.finish('0.zip', status: 404);
    await until(() => adapter.requests.length == 4);
    expect(adapter.requests.last, '5.zip');
    adapter.finish('1.zip');
    adapter.finish('2.zip');
    adapter.finish('5.zip');
    await until(() => manager.tasks.every((task) => !task.busy));
    expect(tasks[0].state, DownloadState.failed);
    expect(tasks[5].state, DownloadState.downloaded);
  });

  test(
    'published SHA-256 is verified, persisted, and rechecked before install',
    () async {
      final task = await manager.download(
        app,
        link('valid', digest: abcSha256),
      );
      await until(() => adapter.requests.isNotEmpty);
      adapter.finish('valid.zip');
      await until(() => !task.busy);
      await manager.flushHistory();
      expect(task.state, DownloadState.downloaded);
      expect(task.checksumVerified, isTrue);
      final saved = DownloadTask.fromJson(
        Map<String, dynamic>.from(
          (jsonDecode(
                await File('${directory.path}/tasks.json').readAsString(),
              ) as List).single
              as Map,
        ),
      );
      expect(saved.checksumVerified, isTrue);
      await File(task.filePath).writeAsString('changed');
      var nativeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeInstaller.channel, (_) async {
            nativeCalls++;
            return '/Applications/Fixture.app';
          });
      await expectLater(
        manager.install(task),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'checksum'),
        ),
      );
      expect(nativeCalls, 0);
      expect(task.checksumVerified, isFalse);
      expect(task.state, DownloadState.downloaded);
    },
    skip: !Platform.isMacOS,
  );

  test('a checksum mismatch never becomes an installable file', () async {
    final task = await manager.download(app, link('bad', digest: '0' * 64));
    await until(() => adapter.requests.isNotEmpty);
    adapter.finish('bad.zip');
    await until(() => !task.busy);
    expect(task.state, DownloadState.failed);
    expect(task.error, contains('SHA-256'));
    expect(task.canInstallOn('macOS'), isFalse);
    expect(await File(task.filePath).exists(), isFalse);
    expect(await File('${task.filePath}.part').exists(), isFalse);
  });

  test('Mac install interrupted after local import restores a retry without claiming success', () async {
    final source = await File('${directory.path}/source.zip')
        .writeAsString('abc');
    await manager.importFile(source, platform: 'macOS');
    final original = manager.tasks.single;
    original.state = DownloadState.installing;
    await manager.flushHistory();
    await File('${directory.path}/tasks.json')
        .writeAsString(jsonEncode([original.toJson()]));
    manager.tasks.clear();
    await manager.restore();
    final restored = manager.tasks.single;
    expect(restored.state, DownloadState.downloaded);
    expect(restored.canInstallOn('macOS'), isTrue);
    expect(restored.error, contains('结果尚未确认'));
    expect(restored.installedPath, isNull);
    expect(restored.url, isEmpty);
  });

  test(
    'opening a PKG retains an unconfirmed handoff through refresh and restart',
    () async {
      final source = await File('${directory.path}/source.pkg')
          .writeAsString('fixture');
      await manager.importFile(source, platform: 'macOS');
      final task = manager.tasks.single;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
            calls.add(call);
            return true;
          });
      await manager.handOff(task);
      expect(calls.single.method, 'openPackage');
      expect(task.state, DownloadState.handedOff);
      expect(task.installedPath, isNull);
      expect(task.canInstallOn('macOS'), isFalse);
      await manager.refresh();
      expect(task.state, DownloadState.handedOff);
      await manager.flushHistory();
      manager.tasks.clear();
      await manager.restore();
      expect(manager.tasks.single.state, DownloadState.handedOff);
      await File(task.filePath).delete();
      await manager.refresh();
      expect(manager.tasks.single.packageAvailable, isFalse);
    },
  );

  test(
    'a failed system handoff retains the package and retry action',
    () async {
      final source = await File('${directory.path}/source.zip')
          .writeAsString('fixture');
      await manager.importFile(source, platform: 'macOS');
      final task = manager.tasks.single;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            NativeInstaller.channel,
            (_) async => false,
          );
      await manager.handOff(task);
      expect(task.state, DownloadState.downloaded);
      expect(task.canHandOff, isTrue);
      expect(task.error, contains('无法打开安装包'));
    },
  );
}
