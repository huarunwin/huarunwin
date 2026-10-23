import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/resumable_download.dart';
import 'package:huarunwin/services/github_acceleration.dart';

class ResumeAdapter implements HttpClientAdapter {
  ResumeAdapter(this.respond);
  final ResponseBody Function(RequestOptions, int) respond;
  final List<RequestOptions> requests = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    return respond(options, requests.length);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody bytes(
  List<int> data, {
  int status = 200,
  String? range,
  String? etag = '"first"',
}) => ResponseBody.fromBytes(
  data,
  status,
  headers: {
    'content-length': ['${data.length}'],
    if (range != null) 'content-range': [range],
    if (etag != null) 'etag': [etag],
  },
);

void main() {
  const url = 'https://example.test/application.apk';
  late Directory directory;
  late File partial;
  late Dio client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-resume-');
    partial = File('${directory.path}/application.apk.part');
    client = Dio();
  });
  tearDown(() async {
    client.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> seed({String? etag = '"first"', String source = url}) async {
    await partial.writeAsBytes([1, 2]);
    await File('${partial.path}.json').writeAsString(
      jsonEncode({'url': source, 'sha256': null, 'total': 4, 'etag': etag}),
    );
  }

  Future<void> fetch({CancelToken? token, void Function(int, int)? progress}) =>
      ResumableDownload(client, retryDelay: Duration.zero).receive(
        url: url,
        partial: partial,
        cancelToken: token ?? CancelToken(),
        maxBytes: 1024,
        resource: false,
        onProgress: progress ?? (_, _) {},
      );

  test(
    'a restarted downloader resumes only matching bytes and validator',
    () async {
      await seed();
      final adapter = ResumeAdapter((request, _) {
        expect(request.headers['Range'], 'bytes=2-');
        expect(request.headers['If-Range'], '"first"');
        return bytes([3, 4], status: 206, range: 'bytes 2-3/4');
      });
      client.httpClientAdapter = adapter;
      await fetch();
      expect(await partial.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('a full response to Range replaces rather than appends', () async {
    await seed();
    client.httpClientAdapter = ResumeAdapter(
      (_, _) => bytes([5, 6, 7], etag: '"new"'),
    );
    await fetch();
    expect(await partial.readAsBytes(), [5, 6, 7]);
  });

  test(
    'invalid ranges and changed validators restart without mixing files',
    () async {
      for (final changed in [false, true]) {
        await seed();
        client.httpClientAdapter = ResumeAdapter((request, call) {
          if (call == 1) {
            return bytes(
              [8, 9],
              status: 206,
              range: changed ? 'bytes 2-3/4' : 'bytes 1-2/4',
              etag: changed ? '"new"' : '"first"',
            );
          }
          expect(request.headers.containsKey('Range'), isFalse);
          return bytes([5, 6, 7, 8], etag: '"new"');
        });
        await fetch();
        expect(await partial.readAsBytes(), [5, 6, 7, 8]);
      }
    },
  );

  test(
    '416 restarts and unvalidated or unrelated partials are not reused',
    () async {
      await seed();
      client.httpClientAdapter = ResumeAdapter(
        (request, call) => call == 1 ? bytes([], status: 416) : bytes([3, 4]),
      );
      await fetch();
      expect(await partial.readAsBytes(), [3, 4]);
      for (final source in [url, 'https://example.test/other.apk']) {
        await seed(etag: source == url ? null : '"first"', source: source);
        client.httpClientAdapter = ResumeAdapter((request, _) {
          expect(request.headers.containsKey('Range'), isFalse);
          return bytes([7, 8]);
        });
        await fetch();
        expect(await partial.readAsBytes(), [7, 8]);
      }
    },
  );

  test(
    'truncated transfer retries with Range and retains completed bytes',
    () async {
      final adapter = ResumeAdapter((request, call) {
        if (call == 1) {
          return ResponseBody.fromBytes(
            [1, 2],
            200,
            headers: {
              'content-length': ['4'],
              'etag': ['"first"'],
            },
          );
        }
        expect(request.headers['Range'], 'bytes=2-');
        return bytes([3, 4], status: 206, range: 'bytes 2-3/4');
      });
      client.httpClientAdapter = adapter;
      await fetch();
      expect(adapter.requests, hasLength(2));
      expect(await partial.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('cancelled transfer preserves partial for an explicit retry', () async {
    final token = CancelToken();
    client.httpClientAdapter = ResumeAdapter(
      (_, _) => ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ]),
        200,
        headers: {
          'content-length': ['4'],
          'etag': ['"first"'],
        },
      ),
    );
    await expectLater(
      fetch(
        token: token,
        progress: (received, _) {
          if (received == 2) token.cancel();
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(await partial.readAsBytes(), [1, 2]);
    expect(await File('${partial.path}.json').exists(), isTrue);
    client.httpClientAdapter = ResumeAdapter((request, _) {
      expect(request.headers['Range'], 'bytes=2-');
      return bytes([3, 4], status: 206, range: 'bytes 2-3/4');
    });
    await fetch();
    expect(await partial.readAsBytes(), [1, 2, 3, 4]);
  });

  test('proxy fallback preserves logical identity and restarts unverified partials', () async {
    const source =
        'https://github.com/example/app/releases/download/v1/app.apk';
    await seed(source: source);
    final github = GitHubAcceleration();
    addTearDown(github.dispose);
    final adapter = ResumeAdapter((request, call) {
      if (call == 1) {
        expect(request.uri.host, 'github.com');
        expect(request.headers['Range'], 'bytes=2-');
        return bytes([], status: 503);
      }
      expect(request.uri.host, 'gh-proxy.com');
      expect(request.headers.containsKey('Range'), isFalse);
      return bytes([5, 6, 7, 8]);
    });
    client.httpClientAdapter = adapter;
    await ResumableDownload(
      client,
      github: github,
      retryDelay: Duration.zero,
    ).receive(
      url: source,
      partial: partial,
      cancelToken: CancelToken(),
      maxBytes: 1024,
      resource: false,
      onProgress: (_, _) {},
    );
    expect(await partial.readAsBytes(), [5, 6, 7, 8]);
    final sidecar =
        jsonDecode(await File('${partial.path}.json').readAsString()) as Map;
    expect(sidecar['url'], source);
    expect(sidecar['transportUrl'], '${GitHubAcceleration.proxyBase}$source');
    expect(github.lastSuccessful(GitHubTraffic.download), GitHubRoute.proxy);
    expect(github.lastSuccessful(GitHubTraffic.raw), isNull);
  });

  test('digest-bound partials retain Range through a route change', () async {
    const source =
        'https://github.com/example/app/releases/download/v1/app.apk';
    final digest = List.filled(64, 'a').join();
    await seed(source: source);
    final metadata = File('${partial.path}.json');
    final saved = jsonDecode(await metadata.readAsString()) as Map;
    saved['sha256'] = digest;
    await metadata.writeAsString(jsonEncode(saved));
    final github = GitHubAcceleration();
    addTearDown(github.dispose);
    client.httpClientAdapter = ResumeAdapter((request, call) {
      if (call == 1) return bytes([], status: 503);
      expect(request.headers['Range'], 'bytes=2-');
      return bytes([3, 4], status: 206, range: 'bytes 2-3/4');
    });
    await ResumableDownload(client, github: github).receive(
      url: source,
      partial: partial,
      cancelToken: CancelToken(),
      maxBytes: 1024,
      resource: false,
      sha256: digest,
      onProgress: (_, _) {},
    );
    expect(await partial.readAsBytes(), [1, 2, 3, 4]);
    // DownloadManager independently checks the final digest before accepting it.
  });

  test('automatic routing shares the three-attempt budget', () async {
    const source =
        'https://github.com/example/app/releases/download/v1/app.apk';
    final github = GitHubAcceleration();
    addTearDown(github.dispose);
    final adapter = ResumeAdapter((_, _) => bytes([], status: 503));
    client.httpClientAdapter = adapter;
    await expectLater(
      ResumableDownload(
        client,
        github: github,
        retryDelay: Duration.zero,
      ).receive(
        url: source,
        partial: partial,
        cancelToken: CancelToken(),
        maxBytes: 1024,
        resource: false,
        onProgress: (_, _) {},
      ),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests.map((r) => r.uri.host), [
      'github.com',
      'gh-proxy.com',
      'gh-proxy.com',
    ]);
    expect(github.lastSuccessful(GitHubTraffic.download), isNull);
  });

  test(
    'failed final validation never records the proxy as successful',
    () async {
      const source =
          'https://github.com/example/app/releases/download/v1/app.apk';
      final github = GitHubAcceleration();
      addTearDown(github.dispose);
      client.httpClientAdapter = ResumeAdapter(
        (request, call) =>
            call == 1 ? bytes([], status: 503) : bytes([1, 2, 3, 4]),
      );
      await expectLater(
        ResumableDownload(client, github: github).receive(
          url: source,
          partial: partial,
          cancelToken: CancelToken(),
          maxBytes: 1024,
          resource: false,
          onProgress: (_, _) {},
          verify: () async => throw const FormatException('Digest mismatch'),
        ),
        throwsFormatException,
      );
      expect(github.lastSuccessful(GitHubTraffic.download), isNull);
      expect(await partial.exists(), isFalse);
    },
  );

  test('retry is bounded and a non-file response discards partials', () async {
    final adapter = ResumeAdapter((_, _) => bytes([], status: 503));
    client.httpClientAdapter = adapter;
    await expectLater(fetch(), throwsA(isA<DioException>()));
    expect(adapter.requests, hasLength(3));
    await seed();
    client.httpClientAdapter = ResumeAdapter(
      (_, _) => ResponseBody.fromString(
        '<html>',
        200,
        headers: {
          'content-type': ['text/html'],
        },
      ),
    );
    await expectLater(fetch(), throwsA(isA<FormatException>()));
    expect(await partial.exists(), isFalse);
    expect(await File('${partial.path}.json').exists(), isFalse);
  });
}
