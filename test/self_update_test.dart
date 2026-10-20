import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/app_changelog.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/app_updates.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/self_update.dart';

const abcDigest =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

class UpdatePackageAdapter implements HttpClientAdapter {
  String body = 'abc';
  final requests = <Uri>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    return ResponseBody.fromString(
      this.body,
      200,
      headers: {
        'content-type': ['application/octet-stream'],
        'content-length': ['${this.body.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> downloaded(DownloadManager manager, DownloadTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (task.busy) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Download did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await manager.flushHistory();
}

AppUpdateFeed packageFeed(
  List<Map<String, Object?>> packages, {
  String? downloadUrl = 'https://example.com/releases/0.2.0',
}) => AppUpdateFeed.decode(
  jsonEncode({
    'release': {
      'publishedVersion': '0.2.0',
      'releases': [
        {
          'version': '0.2.0',
          'changes': ['Update'],
          'downloadUrl': ?downloadUrl,
          'packages': packages,
        },
      ],
    },
  }),
  channel: AppUpdateChannel.release,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadManager manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-self-update');
    manager = DownloadManager(directory);
  });
  tearDown(() async {
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    await directory.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });

  final android = <String, Object?>{
    'platform': 'Android',
    'architecture': 'arm64',
    'kind': 'apk',
    'downloadUrl': 'https://example.com/0.2.0/android.apk',
  };

  test('platform packages retain pinned version and never fall back', () async {
    final release = packageFeed([android]).published!;
    final packages = await SelfUpdatePackages.resolve(
      release,
      'Android',
      manager,
    );
    expect(packages.single.version, '0.2.0');
    expect(packages.single.url, android['downloadUrl']);
    await expectLater(
      SelfUpdatePackages.resolve(release, 'macOS', manager),
      throwsFormatException,
    );
  });

  test('invalid package identity, URLs and digest types fail closed', () {
    for (final change in <Map<String, Object?>>[
      {'platform': 'macOS'},
      {'architecture': null},
      {'architecture': 'unknown'},
      {'downloadUrl': null},
      {'downloadUrl': ''},
      {'downloadUrl': 'http://example.com/app.apk'},
      {'downloadUrl': 'https://user:password@example.com/app.apk'},
      {'sha256': 'invalid'},
      {'sha256': 42},
    ]) {
      expect(
        () => packageFeed([
          {...android, ...change},
        ]),
        throwsFormatException,
      );
    }
  });

  test('explicit packages work without a release download link', () async {
    final release = packageFeed([android], downloadUrl: null).published!;
    const expected =
        'https://github.com/huarunwin/huarunwin/releases/tag/v0.2.0';
    expect(release.packages.single.releaseUrl, expected);
    final packages = await SelfUpdatePackages.resolve(
      release,
      'Android',
      manager,
    );
    expect(packages.single.url, android['downloadUrl']);
    expect(packages.single.version, '0.2.0');
    expect(packages.single.releaseUrl, expected);
  });

  test('latest release pages do not choose a self update version', () async {
    await expectLater(
      SelfUpdatePackages.resolve(
        AppRelease(
          version: '0.2.0',
          changes: const ['Update'],
          downloadUrl: Uri.parse(
            'https://github.com/example/app/releases/latest',
          ),
        ),
        'Android',
        manager,
      ),
      throwsFormatException,
    );
  });

  test('iOS accepts system distribution destinations only', () {
    DownloadLink link(String url) => DownloadLink(url: url, label: 'Update');
    expect(
      SelfUpdatePackages.iosStore(link('https://apps.apple.com/app/id123456'))
          .scheme,
      'itms-apps',
    );
    expect(
      SelfUpdatePackages.iosStore(
        link('https://testflight.apple.com/join/Abc123'),
      ).host,
      'testflight.apple.com',
    );
    for (final url in [
      'https://example.com/app.ipa',
      'https://testflight.apple.com.evil.example/join/Abc123',
      'https://github.com/example/app/releases/tag/v0.2.0',
    ]) {
      expect(
        () => SelfUpdatePackages.iosStore(link(url)),
        throwsFormatException,
      );
    }
  });

  Future<DownloadTask> savedTask({String? job}) async {
    final folder = await Directory('${directory.path}/package').create();
    final package = await File('${folder.path}/update.zip')
        .writeAsBytes([1, 2]);
    final task = DownloadTask(
      id: 'update',
      appName: '华润赢更新',
      url: 'https://example.com/update.zip',
      filePath: package.path,
      kind: 'zip',
      platform: 'macOS',
      createdAt: DateTime.now(),
      state: DownloadState.handedOff,
      selfUpdateChannel: 'release',
      selfUpdateJob: job,
      version: '0.2.0',
    );
    await File('${directory.path}/tasks.json')
        .writeAsString(jsonEncode([task.toJson()]));
    return task;
  }

  test(
    'restored updater errors override success and remain retryable',
    () async {
      final job = await Directory('${directory.path}/job').create();
      await File('${job.path}/result').writeAsString('installed');
      final failure = await File('${job.path}/error.txt')
          .writeAsString('Replacement failed');
      await savedTask(job: job.path);
      await manager.restore();
      final restored = manager.tasks.single;
      expect(restored.selfUpdateChannel, 'release');
      expect(restored.selfUpdateJob, job.path);
      expect(restored.state, DownloadState.downloaded);
      expect(restored.error, 'Replacement failed');
      await failure.delete();
      await manager.refresh();
      expect(restored.state, DownloadState.installed);
      expect(restored.error, isNull);
    },
  );

  test('history failure prevents starting the independent installer', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final task = await savedTask();
    task.state = DownloadState.downloaded;
    final broken = DownloadManager(
      directory,
      writeHistory: (_) async => throw const FileSystemException('Disk full'),
    );
    broken.tasks.add(task);
    var started = false;
    try {
      await expectLater(
        broken.installSelfUpdate(task, (_) async {
          started = true;
        }),
        throwsFormatException,
      );
      expect(started, isFalse);
      expect(task.state, DownloadState.downloaded);
      expect(await File(task.filePath).exists(), isTrue);
    } finally {
      await broken.flushHistory();
      broken.dispose();
      broken.client.close(force: true);
      broken.macResolver.client.close(force: true);
    }
  });

  test('published feed resolves and downloads only its channel with persisted checksum', () async {
    final adapter = UpdatePackageAdapter();
    manager.client.httpClientAdapter = adapter;
    final metadataClient = Dio();
    addTearDown(metadataClient.close);
    metadataClient.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final data = jsonDecode(
            jsonEncode({
              'publishedVersion': '0.2.0',
              'releases': [
                {
                  'version': '0.2.0',
                  'changes': ['Update'],
                  'downloadUrl': 'https://example.com/releases/0.2.0',
                  'packages': [
                    {...android, 'sha256': abcDigest},
                  ],
                },
              ],
            }),
          );
          handler.resolve(
            Response(
              requestOptions: options,
              data: jsonEncode({
                'release': {'publishedVersion': null, 'releases': []},
                'debug': data,
              }),
            ),
          );
        },
      ),
    );
    final updates = AppUpdates(
      client: metadataClient,
      channel: AppUpdateChannel.debug,
      readVersion: () async => '0.1.0',
    );
    final result = await updates.check();
    final packages = await SelfUpdatePackages.resolve(
      result.update!,
      'Android',
      manager,
    );
    final task = await manager.downloadSelfUpdate(
      packages.single,
      updates.channel.name,
    );
    await downloaded(manager, task);
    expect(task.state, DownloadState.downloaded);
    expect(task.checksumVerified, isTrue);
    expect(await File(task.filePath).readAsString(), 'abc');
    expect(adapter.requests.single.toString(), android['downloadUrl']);
    final restored = DownloadManager(directory);
    try {
      await restored.restore();
      expect(restored.tasks.single.selfUpdateChannel, 'debug');
      expect(restored.tasks.single.version, '0.2.0');
      expect(restored.tasks.single.checksumVerified, isTrue);
      expect(restored.tasks.single.state, DownloadState.downloaded);
    } finally {
      await restored.flushHistory();
      restored.dispose();
      restored.client.close(force: true);
      restored.macResolver.client.close(force: true);
    }
  });

  test(
    'same URL never reuses another target version or update channel',
    () async {
      manager.client.httpClientAdapter = UpdatePackageAdapter();
      DownloadLink link(String version) => DownloadLink(
        url: 'https://example.com/latest.apk',
        label: 'Update',
        platform: 'Android',
        kind: 'apk',
        version: version,
        sha256: abcDigest,
      );
      final first = await manager.downloadSelfUpdate(link('0.2.0'), 'debug');
      await downloaded(manager, first);
      expect(
        await manager.downloadSelfUpdate(link('0.2.0'), 'debug'),
        same(first),
      );
      final newer = await manager.downloadSelfUpdate(link('0.3.0'), 'debug');
      await downloaded(manager, newer);
      final releaseTask = await manager.downloadSelfUpdate(
        link('0.3.0'),
        'release',
      );
      await downloaded(manager, releaseTask);
      expect(manager.tasks, hasLength(3));
      expect({for (final task in manager.tasks) task.filePath}, hasLength(3));
    },
  );

  test(
    'bad update bytes are discarded and retry downloads a verified package',
    () async {
      final adapter = UpdatePackageAdapter()..body = 'bad';
      manager.client.httpClientAdapter = adapter;
      const link = DownloadLink(
        url: 'https://example.com/update.apk',
        label: 'Update',
        platform: 'Android',
        kind: 'apk',
        version: '0.2.0',
        sha256: abcDigest,
      );
      final task = await manager.downloadSelfUpdate(link, 'debug');
      await downloaded(manager, task);
      expect(task.state, DownloadState.failed);
      expect(task.packageAvailable, isFalse);
      expect(await File(task.filePath).exists(), isFalse);
      expect(await File('${task.filePath}.part').exists(), isFalse);
      adapter.body = 'abc';
      await manager.retry(task);
      await downloaded(manager, task);
      expect(task.state, DownloadState.downloaded);
      expect(task.checksumVerified, isTrue);
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'a failure saving prepared handoff cancels exit and signals the updater',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final task = await savedTask();
      task.state = DownloadState.downloaded;
      final job = await Directory('${directory.path}/prepared-job').create();
      final broken = DownloadManager(
        directory,
        writeHistory: (snapshot) async {
          if (task.selfUpdateJob != null) {
            throw const FileSystemException('Disk full');
          }
        },
      );
      broken.tasks.add(task);
      var prepared = false;
      try {
        await expectLater(
          broken.installSelfUpdate(task, (_) async {
            prepared = true;
            task.selfUpdateJob = job.path;
          }),
          throwsFormatException,
        );
        expect(prepared, isTrue);
        expect(task.state, DownloadState.downloaded);
        expect(await File('${job.path}/cancel').readAsString(), 'cancel');
        expect(await File(task.filePath).exists(), isTrue);
      } finally {
        await broken.flushHistory();
        broken.dispose();
        broken.client.close(force: true);
        broken.macResolver.client.close(force: true);
      }
    },
  );
}
