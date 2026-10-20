import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../data/app_changelog.dart';
import 'theme.dart';

enum AppUpdateAction { cancel, ignore, download }

Future<AppUpdateAction?> showAppUpdateDialog({
  required BuildContext context,
  required AppRelease release,
  required AppUpdateChannel channel,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final colors = Theme.of(context).colorScheme;
  return navigator.push<AppUpdateAction>(
    _UpdateRoute(
      release: release,
      channel: channel,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      barrierColor: colors.scrim.withValues(
        alpha: colors.brightness == Brightness.dark ? .48 : .2,
      ),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

class _UpdateSpring extends Curve {
  static final _simulation = SpringSimulation(
    SpringDescription.withDurationAndBounce(
      duration: const Duration(milliseconds: 275),
    ),
    0,
    1,
    0,
  );

  @override
  double transformInternal(double t) =>
      _simulation.x(t * .404) + (1 - _simulation.x(.404)) * t;
}

class _UpdateRoute extends PopupRoute<AppUpdateAction> {
  _UpdateRoute({
    required this.release,
    required this.channel,
    required this.themes,
    required this.reduceMotion,
    required this.barrierColor,
    required this.barrierLabel,
  }) : super(traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop);

  final AppRelease release;
  final AppUpdateChannel channel;
  final CapturedThemes themes;
  final bool reduceMotion;
  @override
  final Color barrierColor;
  @override
  final String barrierLabel;
  @override
  bool get barrierDismissible => true;
  @override
  Duration get transitionDuration =>
      reduceMotion ? Duration.zero : const Duration(milliseconds: 404);

  late final _progress = CurvedAnimation(
    parent: animation!,
    curve: _UpdateSpring(),
    reverseCurve: _UpdateSpring().flipped,
  );
  double _entryScale = 1.2;

  @override
  Widget buildModalBarrier() => AnimatedModalBarrier(
    color: _progress.drive(
      ColorTween(begin: barrierColor.withValues(alpha: 0), end: barrierColor),
    ),
    dismissible: barrierDismissible,
    semanticsLabel: barrierLabel,
    barrierSemanticsDismissible: semanticsDismissible,
  );

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => themes.wrap(
    SafeArea(
      child: _UpdateAlert(release: release, channel: channel),
    ),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduceMotion) return child;
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, child) {
        if (animation.status != AnimationStatus.reverse) {
          _entryScale = 1.2 - .2 * _progress.value;
        }
        return FadeTransition(
          opacity: _progress,
          child: Transform.scale(scale: _entryScale, child: child),
        );
      },
      child: child,
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }
}

class _UpdateAlert extends StatefulWidget {
  const _UpdateAlert({required this.release, required this.channel});

  final AppRelease release;
  final AppUpdateChannel channel;

  @override
  State<_UpdateAlert> createState() => _UpdateAlertState();
}

class _UpdateAlertState extends State<_UpdateAlert> {
  bool _closing = false;

  void _choose(AppUpdateAction action) {
    if (_closing) return;
    setState(() => _closing = true);
    Navigator.of(context).pop(action);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final dark = colors.brightness == Brightness.dark;
      final width = math.min(348.0, math.max(0.0, constraints.maxWidth - 80));
      final bodyStyle = Theme.of(context).textTheme.bodyMedium!.copyWith(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w400,
        color: colors.onSurfaceVariant.withValues(alpha: dark ? 1 : .85),
      );
      final ignoreStyle = bodyStyle.copyWith(
        fontSize: 17,
        height: 22 / 17,
        fontWeight: FontWeight.w500,
      );
      final downloadStyle = ignoreStyle.copyWith(fontWeight: FontWeight.w600);
      bool fits(String text, TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final result = painter.width + 32 <= (width - 48) / 3;
        painter.dispose();
        return result;
      }

      Widget button(String label, AppUpdateAction action, TextStyle textStyle) {
        final primary = action == AppUpdateAction.download;
        final fill = dark
            ? colors.surfaceContainerHighest
            : colors.surfaceContainer;
        final background = primary ? colors.primary : fill;
        final foreground = primary ? colors.onPrimary : colors.onSurface;
        return TextButton(
          onPressed: _closing ? null : () => _choose(action),
          style:
              TextButton.styleFrom(
                foregroundColor: foreground,
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: textStyle,
                shape: surfaceShape(1000),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.standard,
                splashFactory: NoSplash.splashFactory,
              ).copyWith(
                backgroundColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.disabled)) return fill;
                  if (states.contains(WidgetState.pressed)) {
                    return background.withValues(
                      alpha: dark ? (primary ? .5 : 1) : .4,
                    );
                  }
                  return background;
                }),
                overlayColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return foreground.withValues(alpha: .1);
                  }
                  if (states.contains(WidgetState.hovered)) {
                    return foreground.withValues(alpha: .08);
                  }
                  return Colors.transparent;
                }),
                side: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.focused)
                      ? BorderSide(color: colors.primary, width: 2)
                      : BorderSide.none,
                ),
              ),
          child: Text(label, textAlign: TextAlign.center),
        );
      }

      final cancel = button('取消', AppUpdateAction.cancel, ignoreStyle);
      final ignore = button('本版本不再提示', AppUpdateAction.ignore, ignoreStyle);
      final download = button('前往下载', AppUpdateAction.download, downloadStyle);
      final sideBySide =
          fits('取消', ignoreStyle) &&
          fits('本版本不再提示', ignoreStyle) &&
          fits('前往下载', downloadStyle);
      return _UpdatePressFeedback(
        width: width,
        child: AlertDialog(
          constraints: BoxConstraints.tightFor(width: width),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 40,
            vertical: 24,
          ),
          shape: surfaceShape(34),
          backgroundColor: dark
              ? colors.surfaceContainerHigh
              : colors.surfaceBright,
          surfaceTintColor: Colors.transparent,
          titlePadding: const EdgeInsets.fromLTRB(30, 21, 30, 0),
          contentPadding: const EdgeInsets.fromLTRB(30, 6, 30, 20),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          titleTextStyle: bodyStyle.copyWith(
            color: colors.onSurface,
            fontSize: 17,
            height: 22 / 17,
            fontWeight: FontWeight.w600,
          ),
          title: Text(
            widget.channel == AppUpdateChannel.debug ? '发现测试版本' : '发现新版本',
          ),
          content: SingleChildScrollView(
            child: SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${widget.release.version}\n',
                    style: bodyStyle.copyWith(fontSize: 22, height: 28 / 22),
                  ),
                  const TextSpan(text: '\n'),
                  for (final change in widget.release.changes)
                    TextSpan(text: '• $change\n'),
                ],
              ),
              style: bodyStyle,
            ),
          ),
          actions: [
            sideBySide
                ? Row(
                    children: [
                      Expanded(child: cancel),
                      const SizedBox(width: 8),
                      Expanded(child: ignore),
                      const SizedBox(width: 8),
                      Expanded(child: download),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      download,
                      const SizedBox(height: 8),
                      ignore,
                      const SizedBox(height: 8),
                      cancel,
                    ],
                  ),
          ],
        ),
      );
    },
  );
}

class _UpdatePressFeedback extends StatefulWidget {
  const _UpdatePressFeedback({required this.width, required this.child});

  final double width;
  final Widget child;

  @override
  State<_UpdatePressFeedback> createState() => _UpdatePressFeedbackState();
}

class _UpdatePressFeedbackState extends State<_UpdatePressFeedback> {
  int? _pointer;
  Offset _origin = Offset.zero;
  Offset _offset = Offset.zero;

  void _release(PointerEvent event) {
    if (event.pointer == _pointer) {
      setState(() {
        _pointer = null;
        _offset = Offset.zero;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Listener(
      onPointerDown: (event) {
        if (_pointer != null || reduceMotion || event.buttons & 1 == 0) return;
        setState(() {
          _pointer = event.pointer;
          _origin = event.position;
        });
      },
      onPointerMove: (event) {
        if (event.pointer != _pointer) return;
        final delta = (event.position - _origin) / 24;
        setState(() {
          _offset = Offset(delta.dx.clamp(-3, 3), delta.dy.clamp(-3, 3));
        });
      },
      onPointerUp: _release,
      onPointerCancel: _release,
      child: TweenAnimationBuilder<Offset>(
        tween: Tween(
          begin: Offset.zero,
          end: reduceMotion ? Offset.zero : _offset,
        ),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, offset, child) =>
            Transform.translate(offset: offset, child: child),
        child: AnimatedScale(
          scale: !reduceMotion && _pointer != null
              ? 1 + 4 / math.max(1, widget.width)
              : 1,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}
