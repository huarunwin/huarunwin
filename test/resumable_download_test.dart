import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/resumable_download.dart';

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
