import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AndroidDownloadCopies extends ChangeNotifier {
  static const _channel = MethodChannel('win.huarun/download_copies');
  bool enabled = false;
  String? treeUri, directoryLabel, warning;

  bool get hasCustomDirectory => enabled && treeUri != null;
  String get directoryDescription =>
      hasCustomDirectory ? directoryLabel ?? '已选择的文件夹' : '应用默认位置';

  void _apply(Map<Object?, Object?> settings) {
    enabled = settings['enabled'] == true;
    treeUri = settings['treeUri'] as String?;
    directoryLabel = settings['label'] as String?;
    warning = settings['warning'] as String?;
    notifyListeners();
  }

  Future<void> refresh({bool validate = true}) async {
    try {
      final settings = await _channel.invokeMapMethod<Object?, Object?>(
        'settings',
        {'validate': validate},
      );
      if (settings != null) _apply(settings);
    } catch (_) {
      warning = '暂时无法读取副本保存设置，请刷新重试。';
      notifyListeners();
    }
  }

  Future<bool> chooseDirectory() async {
    final settings = await _channel.invokeMapMethod<Object?, Object?>(
      'chooseDirectory',
    );
    if (settings == null) return false;
    _apply(settings);
    return true;
  }

  Future<void> resetDirectory() async {
    final settings = await _channel.invokeMapMethod<Object?, Object?>(
      'resetDirectory',
    );
    if (settings != null) _apply(settings);
  }

  Future<({String uri, String directory})> save({
    required String id,
    required String path,
    required CancelToken cancelToken,
    String? sha256,
  }) async {
    final target = treeUri;
    if (!hasCustomDirectory || target == null) {
      throw PlatformException(
        code: 'copy_permission',
        message: '请先在下载目录设置中选择保存副本的文件夹。',
      );
    }
    var completed = false;
    unawaited(
      cancelToken.whenCancel.then((_) async {
        if (completed) return;
        try {
          await _channel.invokeMethod<void>('cancel', {'id': id});
        } catch (_) {
          // A detached engine also cancels native copy jobs.
        }
      }),
    );
    try {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      final result = await _channel.invokeMapMethod<String, String>('copy', {
        'id': id,
        'path': path,
        'sha256': sha256,
        'treeUri': target,
      });
      if (result?['uri'] == null || result?['directory'] == null) {
        throw PlatformException(code: 'copy_failed', message: '未能确认副本已保存，请重试。');
      }
      return (uri: result!['uri']!, directory: result['directory']!);
    } finally {
      completed = true;
    }
  }
}
