import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/downloads.dart';
import 'downloads_page.dart';
import 'page_components.dart';

class AndroidIncomingApks extends StatefulWidget {
  const AndroidIncomingApks({
    super.key,
    required this.manager,
    required this.navigatorKey,
    required this.child,
  });
  static const channel = MethodChannel('win.huarun/incoming_apks');
  final DownloadManager manager;
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<AndroidIncomingApks> createState() => _AndroidIncomingApksState();
}

class _AndroidIncomingApksState extends State<AndroidIncomingApks>
    with WidgetsBindingObserver {
  bool _draining = false, _again = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AndroidIncomingApks.channel.setMethodCallHandler((call) async {
      if (call.method == 'pendingApksChanged') unawaited(_drain());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_drain()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_drain());
  }

  void _message(String message) {
    final context = widget.navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _drain() async {
    if (!mounted) return;
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    try {
      do {
        _again = false;
        final pending =
            await AndroidIncomingApks.channel.invokeListMethod<Object?>(
              'pendingApks',
            ) ??
            const [];
        for (final value in pending) {
          if (!mounted) return;
          final entry = Map<Object?, Object?>.from(value as Map);
          final id = entry['id'] as String;
          if (entry['error'] case final String error) {
            _message(error);
            await AndroidIncomingApks.channel.invokeMethod<void>('ackApk', {
              'id': id,
            });
            continue;
          }
          final task = await widget.manager.adoptAndroidApk(entry);
          if (!mounted) return;
          await AndroidIncomingApks.channel.invokeMethod<void>('ackApk', {
            'id': id,
          });
          if (!mounted) return;
          await widget.navigatorKey.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                body: PageSafeArea(
                  child: DownloadsPage(
                    manager: widget.manager,
                    showBackButton: true,
                    initialTask: task.canInstallOn('Android') ? task : null,
                  ),
                ),
              ),
            ),
          );
        }
      } while (mounted && _again);
    } on MissingPluginException {
      // No incoming-file bridge exists on non-Android test hosts.
    } catch (error) {
      if (mounted) {
        _message(
          error is PlatformException
              ? error.message ?? '导入 APK 失败，请重试。'
              : '导入 APK 失败，文件已保留，请重新打开应用重试。',
        );
      }
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AndroidIncomingApks.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
