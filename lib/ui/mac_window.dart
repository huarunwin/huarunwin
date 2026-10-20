import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

bool get hasMacWindowControls =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

Future<void> showMacWindowAfterFirstFrame() async {
  if (!hasMacWindowControls) return;
  await WidgetsBinding.instance.waitUntilFirstFrameRasterized;
  await const MethodChannel('win.huarun/window')
      .invokeMethod<void>('firstFrameReady');
}

class MacWindowInsets extends StatelessWidget {
  const MacWindowInsets({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!hasMacWindowControls) return child;
    final media = MediaQuery.of(context);
    // Keep this height aligned with WindowDragArea in MainFlutterWindow.swift.
    const height = 32.0;
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(
          top: math.max(media.padding.top, height),
        ),
        viewPadding: media.viewPadding.copyWith(
          top: math.max(media.viewPadding.top, height),
        ),
      ),
      child: child,
    );
  }
}
