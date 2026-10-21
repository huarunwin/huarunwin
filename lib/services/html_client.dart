import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'github_debug.dart';

const _githubTraceKey = 'huarunwin.githubDebugTrace';

Dio createHtmlClient() {
  final client = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      responseType: ResponseType.plain,
      headers: {'Accept': 'text/html'},
    ),
  );
  client.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final trace = GitHubDebugTrace.start(
          'http.start',
          options.uri,
          fields: {
            'method': options.method,
            'connectTimeoutMs': options.connectTimeout?.inMilliseconds,
            'receiveTimeoutMs': options.receiveTimeout?.inMilliseconds,
          },
        );
        if (trace != null) options.extra[_githubTraceKey] = trace;
        var userAgent = 'HuarunWin (+https://huarun.win)';
        try {
          // Apple version fields omit prerelease labels; use the full build
          // version when available, as the client update check does.
          const builtVersion = String.fromEnvironment('HUARUNWIN_VERSION');
          final version = builtVersion.isNotEmpty
              ? builtVersion
              : (await PackageInfo.fromPlatform()).version;
          if (version.isNotEmpty) {
            userAgent = 'HuarunWin/$version (+https://huarun.win)';
          }
        } catch (error) {
          // Missing package metadata must not prevent content from loading.
          trace?.log('http.userAgentFallback', error: error);
        }
        options.headers['User-Agent'] = userAgent;
        trace?.log('http.send', fields: {'userAgent': userAgent});
        handler.next(options);
      },
      onResponse: (response, handler) {
        final trace =
            response.requestOptions.extra[_githubTraceKey] as GitHubDebugTrace?;
        trace?.log(
          'http.response',
          fields: {
            'status': response.statusCode,
            'actualUrl': githubDebugUrl(response.realUri),
            'redirects': [
              for (final redirect in response.redirects)
                {
                  'status': redirect.statusCode,
                  'url': githubDebugUrl(redirect.location),
                },
            ],
            'contentType': response.headers.value('content-type'),
            'contentLength': response.headers.value('content-length'),
            if (response.data is String)
              'characters': (response.data as String).length,
          },
        );
        handler.next(response);
      },
      onError: (error, handler) {
        final trace =
            error.requestOptions.extra[_githubTraceKey] as GitHubDebugTrace?;
        trace?.log('http.error', error: error);
        handler.next(error);
      },
    ),
  );
  return client;
}
