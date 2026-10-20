import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// A partial is reusable only with a matching digest or an HTTP validator.
/// The sidecar is written before bytes, so a crash never adopts unknown bytes.
class ResumableDownload {
  ResumableDownload(
    this.client, {
    this.retryDelay = const Duration(seconds: 1),
  });

  final Dio client;
  final Duration retryDelay;

  static Future<void> discard(File partial) async {
    for (final file in [
      partial,
      File('${partial.path}.json'),
      File('${partial.path}.json.tmp'),
    ]) {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.file) await file.delete();
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('下载临时文件的位置无效。');
      }
    }
  }

  Future<void> receive({
    required String url,
    required File partial,
    required CancelToken cancelToken,
    required int maxBytes,
    required bool resource,
    required void Function(int received, int total) onProgress,
    String? sha256,
  }) async {
    for (var attempt = 0; ; attempt++) {
      _checkCancelled(cancelToken);
      try {
        await _receive(
          url,
          partial,
          cancelToken,
          maxBytes,
          resource,
          onProgress,
          sha256,
        );
        return;
      } on FormatException {
        await discard(partial);
        rethrow;
      } catch (error) {
        if (cancelToken.isCancelled || attempt >= 2 || !_transient(error)) {
          rethrow;
        }
        await Future.any([
          Future<void>.delayed(retryDelay * (1 << attempt)),
          cancelToken.whenCancel.then<void>((error) => throw error),
        ]);
      }
    }
  }

  static void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw token.cancelError!;
  }

  static bool _transient(Object error) =>
      error is SocketException ||
      error is HttpException ||
      error is DioException &&
          (error.error is SocketException ||
              error.error is HttpException ||
              [
                DioExceptionType.connectionTimeout,
                DioExceptionType.receiveTimeout,
                DioExceptionType.sendTimeout,
                DioExceptionType.connectionError,
              ].contains(error.type) ||
              [
                408,
                429,
                500,
                502,
                503,
                504,
              ].contains(error.response?.statusCode));

  Future<void> _receive(
    String url,
    File partial,
    CancelToken token,
    int maxBytes,
    bool resource,
    void Function(int, int) progress,
    String? digest,
  ) async {
    final sidecar = File('${partial.path}.json');
    Map<String, dynamic>? saved;
    var offset = 0;
    for (final file in [partial, sidecar, File('${sidecar.path}.tmp')]) {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.notFound) {
        throw const FileSystemException('下载临时文件的位置无效。');
      }
    }
    try {
      if (await sidecar.length() < 16384) {
        final value = jsonDecode(await sidecar.readAsString());
        if (value is Map<String, dynamic> &&
            value['url'] == url &&
            value['sha256'] == digest &&
            (digest != null || _validator(value) != null)) {
          final length = await partial.length();
          final total = value['total'];
          if (length > 0 &&
              length <= maxBytes &&
              total is int &&
              total >= 0 &&
              total <= maxBytes &&
              (total == 0 || length <= total)) {
            saved = value;
            offset = length;
          }
        }
      }
    } on FileSystemException {
      // A missing sidecar or partial starts a new transfer.
    } on FormatException {
      // Corrupt metadata cannot establish the identity of partial bytes.
    }
    if (saved == null) await discard(partial);
    progress(offset, saved?['total'] as int? ?? 0);
    if (digest != null && offset > 0 && offset == saved?['total']) return;
    for (var restart = 0; restart < 2; restart++) {
      _checkCancelled(token);
      final response = await client.get<ResponseBody>(
        url,
        cancelToken: token,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 6,
          validateStatus: (code) => code == 200 || code == 206 || code == 416,
          headers: {
            'Accept-Encoding': 'identity',
            if (offset > 0) 'Range': 'bytes=$offset-',
            if (offset > 0 && _validator(saved!) != null)
              'If-Range': _validator(saved),
          },
        ),
      );
      final body = response.data!;
      Future<void> closeResponse() async => body.stream.listen((_) {}).cancel();
      final contentType =
          response.headers.value('content-type')?.toLowerCase() ?? '';
      final encoding = response.headers.value('content-encoding');
      if (response.realUri.scheme != 'https' ||
          encoding != null && encoding.toLowerCase() != 'identity' ||
          !resource &&
              (contentType.contains('text/html') ||
                  contentType.contains('application/json'))) {
        await closeResponse();
        throw const FormatException('下载地址返回了网页或非安装文件，请打开官方入口。');
      }
      final length = int.tryParse(
        response.headers.value('content-length') ?? '',
      );
      var total = length ?? 0;
      if (response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers.value('content-range') ?? '');
        final start = int.tryParse(range?.group(1) ?? '');
        final end = int.tryParse(range?.group(2) ?? '');
        final whole = int.tryParse(range?.group(3) ?? '');
        final sameValidator = saved?['etag'] != null
            ? saved!['etag'] == response.headers.value('etag')
            : saved?['lastModified'] == null ||
                  saved!['lastModified'] ==
                      response.headers.value('last-modified');
        if (offset == 0 ||
            start != offset ||
            end == null ||
            whole == null ||
            end < offset ||
            end != whole - 1 ||
            length != null && length != whole - offset ||
            saved?['total'] != 0 && saved?['total'] != whole ||
            !sameValidator) {
          await closeResponse();
          await discard(partial);
          offset = 0;
          saved = null;
          continue;
        }
        total = whole;
      } else if (response.statusCode == 416) {
        await closeResponse();
        await discard(partial);
        offset = 0;
        saved = null;
        continue;
      } else {
        offset = 0;
      }
      if (total < 0 || total > maxBytes) {
        await closeResponse();
        throw const FormatException('安装包超过 4 GB，请使用浏览器下载。');
      }
      final etag = response.headers.value('etag');
      final modified = response.headers.value('last-modified');
      final metadata = {
        'url': url,
        'sha256': digest,
        'total': total,
        'etag': etag != null && etag.startsWith('"') && etag.endsWith('"')
            ? etag
            : null,
        'lastModified': _httpDate(modified) ? modified : null,
      };
      IOSink? output;
      var listening = false;
      var completed = false;
      var received = offset;
      try {
        // Truncate before replacing the sidecar when a server ignores Range.
        if (offset == 0) await partial.writeAsBytes(const [], flush: true);
        final temporary = File('${sidecar.path}.tmp');
        await temporary.writeAsString(jsonEncode(metadata), flush: true);
        await temporary.rename(sidecar.path);
        output = partial.openWrite(mode: FileMode.append);
        progress(received, total);
        listening = true;
        await for (final chunk in body.stream) {
          _checkCancelled(token);
          received += chunk.length;
          if (received > maxBytes || total > 0 && received > total) {
            throw const FormatException('安装包长度与服务器记录不一致，请重新下载。');
          }
          output.add(chunk);
          await output.flush();
          progress(received, total);
        }
        await output.close();
        output = null;
        _checkCancelled(token);
        if (received == 0 || total > 0 && total != received) {
          throw const HttpException('下载的文件不完整，请重试。');
        }
        completed = true;
        progress(received, total == 0 ? received : total);
        return;
      } finally {
        if (!listening) await closeResponse();
        if (output != null) {
          try {
            await output.close();
          } on FileSystemException {
            /* Preserve the write error. */
          }
        }
        if (!completed && digest == null && _validator(metadata) == null) {
          await discard(partial);
        }
      }
    }
    throw const FormatException('服务器无法安全续传此文件，请重新下载。');
  }

  static String? _validator(Map<String, dynamic> saved) {
    final etag = saved['etag'];
    if (etag is String && etag.startsWith('"') && etag.endsWith('"')) {
      return etag;
    }
    final modified = saved['lastModified'];
    return modified is String && _httpDate(modified) ? modified : null;
  }

  static bool _httpDate(String? value) {
    if (value == null) return false;
    try {
      HttpDate.parse(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}
