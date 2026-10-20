import 'dart:async';

import 'package:flutter/services.dart';

class AndroidDownloadForeground {
  AndroidDownloadForeground() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'downloadsStopped') {
        _generation++;
        _active = false;
        onStopped?.call(call.arguments as String? ?? '后台下载已停止，请返回应用重试。');
      } else if (call.method == 'openDownloads') {
        onOpen?.call();
      }
    });
  }

  static const _channel = MethodChannel('win.huarun/download_foreground');
  Future<void> _pending = Future.value();
  bool _active = false;
  int _generation = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  void Function(String)? onStopped;
  void Function()? onOpen;

  Future<void> start(Map<String, Object> progress) {
    final next = _pending.then((_) async {
      if (!_active) {
        final generation = _generation;
        await _channel.invokeMethod<void>('start', progress);
        if (generation != _generation) {
          throw PlatformException(
            code: 'download_service',
            message: '后台下载服务已停止，请重试。',
          );
        }
        _active = true;
      }
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  void update(Map<String, Object> progress) {
    if (!_active) return;
    final stopping = progress['count'] == 0;
    final now = DateTime.now();
    if (!stopping && now.difference(_lastUpdate).inMilliseconds < 750) return;
    _lastUpdate = now;
    _pending = _pending
        .then((_) async {
          if (!_active) return;
          if (stopping) {
            await _channel.invokeMethod<void>('stop');
            _active = false;
          } else {
            await _channel.invokeMethod<void>('update', progress);
          }
        })
        .catchError((Object _) {
          _active = false;
          onStopped?.call('后台下载服务未能继续，请返回应用后重试。');
        });
  }

  Future<void> consumeOpenRequest() async {
    try {
      if (await _channel.invokeMethod<bool>('consumeOpen') == true) {
        onOpen?.call();
      }
    } on PlatformException {
      // Notification navigation must not prevent normal app startup.
    } on MissingPluginException {
      // Keep startup usable if the native bridge is unavailable.
    }
  }

  void dispose() {
    update(const {'count': 0});
    onStopped = null;
    onOpen = null;
    _channel.setMethodCallHandler(null);
  }
}
