import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

bool _isGitHub(Uri uri) =>
    uri.host == 'github.com' || uri.host == 'raw.githubusercontent.com';

/// Public paths are useful for diagnosis; credentials, queries, fragments and
/// non-GitHub redirect destinations must not appear in the debug output.
String githubDebugUrl(Uri uri) => _isGitHub(uri)
    ? Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString()
    : '<non-GitHub URL>';

Map<String, Object?> _errorDetails(Object error) {
  final details = <String, Object?>{'type': error.runtimeType.toString()};
  if (error is DioException) {
    details['dioType'] = error.type.name;
    details['status'] = error.response?.statusCode;
    if (error.error != null && !identical(error.error, error)) {
      details['cause'] = _errorDetails(error.error!);
    }
  } else if (error is SocketException) {
    // Do not print SocketException.toString(): it includes network addresses.
    final message = error.message.toLowerCase();
    details['reason'] = message.contains('host lookup')
        ? 'dnsLookupFailed'
        : message.contains('refused')
        ? 'connectionRefused'
        : message.contains('reset')
        ? 'connectionReset'
        : message.contains('unreachable')
        ? 'networkUnreachable'
        : message.contains('timed out')
        ? 'timedOut'
        : 'socketFailure';
    details['osErrorCode'] = error.osError?.errorCode;
  } else if (error is TlsException) {
    details['reason'] = error.message.contains('CERTIFICATE_VERIFY_FAILED')
        ? 'certificateVerifyFailed'
        : 'tlsFailure';
    details['osErrorCode'] = error.osError?.errorCode;
  } else if (error is TimeoutException) {
    details['timeoutMs'] = error.duration?.inMilliseconds;
  } else if (error is FormatException) {
    // Only the validation message, never the source HTML or offending input.
    details['reason'] = error.message;
  }
  return details;
}

void githubDebugLog(
  String event, {
  required Uri uri,
  Map<String, Object?> fields = const {},
  Object? error,
}) {
  if (!kDebugMode || !_isGitHub(uri)) return;
  debugPrint(
    '[GitHub] ${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'event': event, 'url': githubDebugUrl(uri), ...fields, if (error != null) 'error': _errorDetails(error)})}',
  );
}

class GitHubDebugTrace {
  GitHubDebugTrace._(this.id, this.uri);

  static int _nextId = 0;
  final int id;
  final Uri uri;
  final _clock = Stopwatch()..start();

  static GitHubDebugTrace? start(
    String event,
    Uri uri, {
    Map<String, Object?> fields = const {},
  }) {
    if (!kDebugMode || !_isGitHub(uri)) return null;
    final trace = GitHubDebugTrace._(++_nextId, uri);
    trace.log(event, fields: fields);
    return trace;
  }

  void log(
    String event, {
    Map<String, Object?> fields = const {},
    Object? error,
  }) => githubDebugLog(
    event,
    uri: uri,
    fields: {'id': id, 'elapsedMs': _clock.elapsedMilliseconds, ...fields},
    error: error,
  );
}
