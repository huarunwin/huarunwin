import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/github_acceleration.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions) respond;
  final urls = <Uri>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    urls.add(options.uri);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(
  String body, {
  int status = 200,
  String type = 'text/plain',
}) => ResponseBody.fromString(
  body,
  status,
  headers: {
    'content-type': [type],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final raw = Uri.parse(
    'https://raw.githubusercontent.com/example/app/main/manifest.json',
  );
  final asset = Uri.parse(
    'https://github.com/example/app/releases/download/v1.0/app.apk',
  );
  late DateTime now;
  late SharedPreferences preferences;
  late GitHubAcceleration access;
  late Dio client;

  setUp(() async {
    now = DateTime.utc(2026, 10, 23, 12);
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    access = GitHubAcceleration(clock: () => now)..restore(preferences);
    client = Dio();
  });
  tearDown(() {
    client.close(force: true);
    access.dispose();
  });

  Future<String> fetch({CancelToken? token}) => access.readRaw(
    client,
    raw,
    cancelToken: token,
    maxBytes: 1024,
    decode: (r) => r.data!,
  );

  test('Raw failure falls back without changing the logical URL', () async {
    final adapter = _Adapter(
      (request) => request.uri.host == raw.host
          ? _response('', status: 503)
          : _response('contents'),
    );
    client.httpClientAdapter = adapter;
    expect(await fetch(), 'contents');
    expect(adapter.urls, [
      raw,
      GitHubAcceleration.transport(raw, GitHubRoute.proxy),
    ]);
    expect(access.lastSuccessful(GitHubTraffic.raw), GitHubRoute.proxy);
    expect(access.lastSuccessful(GitHubTraffic.download), isNull);
  });

  test('hold survives restart and successes never extend two hours', () async {
    await access.succeeded(
      access.begin(GitHubTraffic.raw, raw),
      GitHubRoute.proxy,
    );
    now = now.add(const Duration(hours: 1));
    await access.succeeded(
      access.begin(GitHubTraffic.raw, raw),
      GitHubRoute.proxy,
    );
    final saved =
        jsonDecode(preferences.getString('githubAcceleration')!) as Map;
    expect(
      saved['raw']['since'],
      DateTime.utc(2026, 10, 23, 12).toIso8601String(),
    );
    final restarted = GitHubAcceleration(clock: () => now)
      ..restore(preferences);
    addTearDown(restarted.dispose);
    expect(
      restarted.begin(GitHubTraffic.raw, raw).routes.first,
      GitHubRoute.proxy,
    );
    expect(
      restarted.begin(GitHubTraffic.download, asset).routes.first,
      GitHubRoute.direct,
    );
    now = now.add(const Duration(hours: 1));
    expect(
      restarted.begin(GitHubTraffic.raw, raw).routes.first,
      GitHubRoute.direct,
    );
  });

  test(
    'manual retry rejects late success and preserves the other traffic hold',
    () async {
      await access.succeeded(
        access.begin(GitHubTraffic.raw, raw),
        GitHubRoute.proxy,
      );
      await access.succeeded(
        access.begin(GitHubTraffic.download, asset),
        GitHubRoute.proxy,
      );
      final older = access.begin(GitHubTraffic.raw, raw);
      access.retryPrimary(GitHubTraffic.raw);
      await access.succeeded(older, GitHubRoute.proxy);
      expect(
        access.begin(GitHubTraffic.raw, raw).routes.first,
        GitHubRoute.direct,
      );
      expect(
        access.begin(GitHubTraffic.download, asset).routes.first,
        GitHubRoute.proxy,
      );
      await access.select(GitHubAccessMode.direct);
      await access.succeeded(older, GitHubRoute.proxy);
      expect(access.lastSuccessful(GitHubTraffic.raw), isNull);
    },
  );

  test('failed preferred proxy immediately returns to direct access', () async {
    await access.succeeded(
      access.begin(GitHubTraffic.raw, raw),
      GitHubRoute.proxy,
    );
    final adapter = _Adapter(
      (request) => request.uri.host == 'gh-proxy.com'
          ? _response('<html>landing page</html>', type: 'text/html')
          : _response('original'),
    );
    client.httpClientAdapter = adapter;
    expect(await fetch(), 'original');
    expect(adapter.urls.map((u) => u.host), ['gh-proxy.com', raw.host]);
    expect(
      access.begin(GitHubTraffic.raw, raw).routes.first,
      GitHubRoute.direct,
    );
  });

  test(
    'fixed modes never fall back and retain their setting after restart',
    () async {
      for (final mode in [GitHubAccessMode.proxy, GitHubAccessMode.direct]) {
        await access.select(mode);
        final adapter = _Adapter((_) => _response('', status: 503));
        client.httpClientAdapter = adapter;
        await expectLater(fetch(), throwsA(isA<DioException>()));
        expect(adapter.urls, hasLength(1));
        final restored = GitHubAcceleration()..restore(preferences);
        addTearDown(restored.dispose);
        expect(restored.mode, mode);
      }
    },
  );

  test(
    '404, invalid metadata and cancellation do not select a fallback',
    () async {
      final missing = _Adapter((_) => _response('', status: 404));
      client.httpClientAdapter = missing;
      await expectLater(fetch(), throwsA(isA<DioException>()));
      expect(missing.urls, hasLength(1));
      final invalid = _Adapter((_) => _response('invalid json'));
      client.httpClientAdapter = invalid;
      await expectLater(
        access.readRaw(
          client,
          raw,
          maxBytes: 1024,
          decode: (response) => jsonDecode(response.data!),
        ),
        throwsFormatException,
      );
      expect(invalid.urls, hasLength(1));
      final token = CancelToken()..cancel();
      await expectLater(fetch(token: token), throwsA(isA<DioException>()));
      expect(invalid.urls, hasLength(1));
      expect(access.lastSuccessful(GitHubTraffic.raw), isNull);
    },
  );

  test(
    'HTML, API, private credentials and unrelated hosts are never proxied',
    () async {
      await access.select(GitHubAccessMode.proxy);
      for (final url in [
        'https://github.com/example/app/releases',
        'https://github.com/example/app/releases/tag/v1.0',
        'https://github.com/example/app/releases/expanded_assets/v1.0',
        'https://api.github.com/repos/example/app/releases',
        'https://user:secret@raw.githubusercontent.com/example/app/main/file',
        'https://example.test/app.apk',
        'https://gh-proxy.com/https://github.com/example/app/releases/download/v1/app.apk',
      ]) {
        expect(access.begin(GitHubTraffic.download, Uri.parse(url)).routes, [
          GitHubRoute.direct,
        ]);
      }
    },
  );
}
