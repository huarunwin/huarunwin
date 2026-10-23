import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum GitHubAccessMode {
  automatic('自动'),
  direct('GitHub 直连'),
  proxy('GH-Proxy');

  const GitHubAccessMode(this.label);
  final String label;
}

enum GitHubRoute {
  direct('GitHub 直连'),
  proxy('GH-Proxy');

  const GitHubRoute(this.label);
  final String label;
}

enum GitHubTraffic { raw, download }

class GitHubTransportException extends FormatException {
  const GitHubTransportException(super.message);
}

typedef GitHubAccessRequest = ({
  int revision,
  int generation,
  GitHubTraffic traffic,
  List<GitHubRoute> routes,
});

class _RouteState {
  GitHubRoute? last;
  DateTime? since;
  int generation = 0;
}

/// Routes public file requests only. GitHub Release HTML is not supported by
/// GH-Proxy and must continue through the existing HTML resolver.
class GitHubAcceleration extends ChangeNotifier {
  GitHubAcceleration({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static final instance = GitHubAcceleration();
  static const proxyBase = 'https://gh-proxy.com/';
  static const holdDuration = Duration(hours: 2);
  static const _key = 'githubAcceleration';
  final DateTime Function() _clock;
  final _states = {
    for (final kind in GitHubTraffic.values) kind: _RouteState(),
  };
  SharedPreferences? _preferences;
  Future<void> _writes = Future.value();
  GitHubAccessMode mode = GitHubAccessMode.automatic;
  GitHubAccessMode? _configuredMode;
  int _revision = 0;
  bool _disposed = false;

  GitHubRoute? lastSuccessful(GitHubTraffic traffic) => _states[traffic]!.last;

  void restore(SharedPreferences preferences) {
    _preferences = preferences;
    final stored = preferences.get(_key);
    Map<String, dynamic> data = {};
    try {
      final decoded = stored is String ? jsonDecode(stored) : null;
      if (decoded is Map<String, dynamic>) data = decoded;
    } on FormatException {
      // Invalid preferences do not prevent direct access.
    }
    mode =
        _configuredMode ??
        GitHubAccessMode.values
            .where((value) => value.name == data['mode'])
            .firstOrNull ??
        GitHubAccessMode.automatic;
    for (final kind in GitHubTraffic.values) {
      final saved = data[kind.name];
      final state = _states[kind]!;
      state.last = null;
      state.since = null;
      if (saved is Map) {
        state.last = GitHubRoute.values
            .where((value) => value.name == saved['route'])
            .firstOrNull;
        if (state.last == GitHubRoute.proxy && saved['since'] is String) {
          state.since = DateTime.tryParse(saved['since'] as String)?.toUtc();
        }
      }
      state.generation++;
    }
    _revision++;
  }

  /// Content-source selection is authoritative; route history is best effort.
  void configure(GitHubAccessMode value, {bool reset = false}) {
    if (_disposed) return;
    _configuredMode = value;
    if (!reset && mode == value) return;
    mode = value;
    _revision++;
    for (final state in _states.values) {
      state.last = null;
      state.since = null;
      state.generation++;
    }
    // Restoration must not overwrite legacy preferences before migration.
    if (reset) unawaited(_persist());
    notifyListeners();
  }

  Future<void> reload() async {
    final preferences = _preferences;
    if (preferences == null) return;
    final revision = _revision;
    final generations = [for (final state in _states.values) state.generation];
    await _writes;
    await preferences.reload();
    if (_disposed ||
        revision != _revision ||
        !listEquals(generations, [
          for (final s in _states.values) s.generation,
        ])) {
      return;
    }
    restore(preferences);
    notifyListeners();
  }

  Future<void> select(GitHubAccessMode value) async {
    if (mode == value) return;
    // Save the whole choice atomically before exposing it to new requests.
    final snapshot = jsonEncode({'mode': value.name});
    final saved = _writes.then((_) async {
      if (_preferences != null &&
          !await _preferences!.setString(_key, snapshot)) {
        throw StateError('Unable to save GitHub access mode');
      }
      if (_disposed) return;
      mode = value;
      _revision++;
      for (final state in _states.values) {
        state.last = null;
        state.since = null;
        state.generation++;
      }
      notifyListeners();
    });
    _writes = saved.catchError((Object _) {});
    await saved;
    // A response queued during the preference write must not replace it.
    await _persist();
  }

  GitHubAccessRequest begin(GitHubTraffic traffic, Uri original) {
    final state = _states[traffic]!;
    if (state.since != null) {
      final elapsed = _clock().toUtc().difference(state.since!);
      if (elapsed.isNegative || elapsed >= holdDuration) {
        state.since = null;
        state.generation++;
        unawaited(_persist());
      }
    }
    return (
      revision: _revision,
      generation: state.generation,
      traffic: traffic,
      routes: _routes(
        original,
        traffic,
        state.since == null ? GitHubRoute.direct : GitHubRoute.proxy,
      ),
    );
  }

  List<GitHubRoute> _routes(
    Uri original,
    GitHubTraffic traffic,
    GitHubRoute preferred,
  ) {
    if (!supports(original, traffic)) return [GitHubRoute.direct];
    return switch (mode) {
      GitHubAccessMode.direct => [GitHubRoute.direct],
      GitHubAccessMode.proxy => [GitHubRoute.proxy],
      GitHubAccessMode.automatic => [
        preferred,
        preferred == GitHubRoute.direct
            ? GitHubRoute.proxy
            : GitHubRoute.direct,
      ],
    };
  }

  /// Images follow the last working Raw route until another text request
  /// succeeds. Image cache hits and failures never change either hold period.
  List<Uri> imageUris(Uri original) => [
    for (final route in _routes(
      original,
      GitHubTraffic.raw,
      lastSuccessful(GitHubTraffic.raw) ?? GitHubRoute.direct,
    ))
      transport(original, route),
  ];

  void retryPrimary([GitHubTraffic? traffic]) {
    if (mode != GitHubAccessMode.automatic) return;
    for (final kind in traffic == null ? GitHubTraffic.values : [traffic]) {
      final state = _states[kind]!;
      state.since = null;
      state.generation++;
    }
    unawaited(_persist());
    notifyListeners();
  }

  Future<void> succeeded(GitHubAccessRequest request, GitHubRoute route) async {
    final state = _states[request.traffic]!;
    if (_disposed ||
        request.revision != _revision ||
        request.generation != state.generation) {
      return;
    }
    final since =
        mode == GitHubAccessMode.automatic && route == GitHubRoute.proxy
        ? state.since ?? _clock().toUtc()
        : null;
    if (state.last == route && state.since == since) return;
    state.last = route;
    state.since = since;
    state.generation++;
    await _persist();
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist() {
    final revision = _revision;
    final snapshot = jsonEncode({
      'mode': mode.name,
      for (final entry in _states.entries)
        entry.key.name: {
          'route': entry.value.last?.name,
          'since': entry.value.since?.toIso8601String(),
        },
    });
    return _writes = _writes.then((_) async {
      if (revision != _revision) return;
      try {
        await _preferences?.setString(_key, snapshot);
      } catch (_) {
        // A state write failure must not hide a successful transfer.
      }
    });
  }

  static bool supports(Uri uri, GitHubTraffic traffic) {
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasFragment) {
      return false;
    }
    final parts = uri.pathSegments;
    if (parts.any(
      (p) =>
          p.isEmpty ||
          p == '.' ||
          p == '..' ||
          p.contains('/') ||
          p.contains('\\'),
    )) {
      return false;
    }
    if (uri.host == 'raw.githubusercontent.com') return parts.length >= 4;
    if (traffic != GitHubTraffic.download || uri.host != 'github.com') {
      return false;
    }
    return parts.length >= 6 &&
            parts[2] == 'releases' &&
            parts[3] == 'download' ||
        parts.length >= 4 && parts[2] == 'archive';
  }

  static Uri transport(Uri original, GitHubRoute route) =>
      route == GitHubRoute.direct ? original : Uri.parse('$proxyBase$original');

  static Uri originalUri(Uri transport) {
    if (transport.toString().startsWith('${proxyBase}https://')) {
      return Uri.parse(transport.toString().substring(proxyBase.length));
    }
    return transport;
  }

  static bool retryable(Object error) =>
      error is GitHubTransportException ||
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is DioException &&
          ([
                DioExceptionType.connectionTimeout,
                DioExceptionType.receiveTimeout,
                DioExceptionType.sendTimeout,
                DioExceptionType.connectionError,
                DioExceptionType.transformTimeout,
              ].contains(error.type) ||
              error.type == DioExceptionType.unknown &&
                  (error.error is SocketException ||
                      error.error is HttpException ||
                      error.error is HandshakeException &&
                          (error.error as HandshakeException).osError == null &&
                          (error.error as HandshakeException).message ==
                              'Connection terminated during handshake') ||
              error.type == DioExceptionType.badResponse &&
                  ([403, 408, 429].contains(error.response?.statusCode) ||
                      (error.response?.statusCode ?? 0) >= 500));

  Future<T> readRaw<T>(
    Dio client,
    Uri original, {
    required T Function(Response<String>) decode,
    required int maxBytes,
    Duration timeout = const Duration(seconds: 20),
    Duration connectTimeout = const Duration(seconds: 15),
    CancelToken? cancelToken,
  }) async {
    final request = begin(GitHubTraffic.raw, original);
    final perRoute = Duration(
      microseconds: timeout.inMicroseconds ~/ request.routes.length,
    );
    final connecting = connectTimeout < perRoute ? connectTimeout : perRoute;
    for (final route in request.routes) {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      final token = CancelToken();
      unawaited(cancelToken?.whenCancel.then((error) => token.cancel(error)));
      try {
        final response = await client
            .getUri<String>(
              transport(original, route),
              cancelToken: token,
              options: Options(
                responseType: ResponseType.plain,
                connectTimeout: connecting,
                sendTimeout: connecting,
                receiveTimeout: perRoute,
              ),
            )
            .timeout(
              perRoute,
              onTimeout: () {
                token.cancel('GitHub file request timed out');
                throw TimeoutException(
                  'GitHub file request timed out',
                  perRoute,
                );
              },
            );
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        final body = response.data;
        if (response.statusCode != 200 ||
            originalUri(response.realUri) != original ||
            body == null ||
            utf8.encode(body).length > maxBytes ||
            (response.headers.value('content-type') ?? '')
                .toLowerCase()
                .contains('text/html')) {
          throw const GitHubTransportException('GitHub 文件来源返回了非预期的内容，请稍后重试。');
        }
        final value = decode(response);
        await succeeded(request, route);
        return value;
      } catch (error) {
        if (cancelToken?.isCancelled == true ||
            route == request.routes.last ||
            !retryable(error)) {
          rethrow;
        }
      }
    }
    throw StateError('No GitHub route available');
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
