import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

const _dockHeight = 62.0;
const _dockPadding = 4.0;
const _dockMargin = 21.0;
const _iconSize = 28.0;
const _labelSize = 10.0;
const _labelHeight = 14.5;

final _travelSpring = SpringDescription.withDurationAndBounce(
  duration: const Duration(milliseconds: 400),
  bounce: .15,
);
final _pressSpring = SpringDescription.withDurationAndBounce(
  duration: const Duration(milliseconds: 250),
  bounce: .2,
);
final _hoverSpring = SpringDescription.withDurationAndBounce(
  duration: const Duration(milliseconds: 260),
  bounce: .18,
);

class CompactNavigation extends StatelessWidget {
  const CompactNavigation({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
  });

  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onSelected;

  static double _heightOf(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context);
    return math.max(
      _dockHeight + math.max(0, scale.scale(_labelSize) - _labelSize),
      _dockPadding * 2 + _iconSize + 2 + scale.scale(_labelHeight),
    );
  }

  static double insetOf(BuildContext context) =>
      _heightOf(context) +
      math.max(_dockMargin, MediaQuery.viewPaddingOf(context).bottom);

  @override
  Widget build(BuildContext context) {
    if (destinations.isEmpty) return const SizedBox.shrink();
    final padding = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _dockMargin + padding.left,
        8,
        _dockMargin + padding.right,
        math.max(_dockMargin, MediaQuery.viewPaddingOf(context).bottom),
      ),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: destinations.length >= 5
                ? double.infinity
                : destinations.length * 86 + 16,
          ),
          child: SizedBox(
            height: _heightOf(context),
            child: RepaintBoundary(
              child: _NavigationDock(
                selectedIndex: selectedIndex,
                destinations: destinations,
                onSelected: onSelected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockLayout {
  _DockLayout(this.width, this.count) {
    final available = math.max(0.0, width - _dockPadding * 2);
    final itemWidth = math.max(0.0, available - _dockPadding * 2) / count;
    lensWidth = math.min(available, math.max(84.0, itemWidth + 8));
    pitch = count == 1 ? available : (available - lensWidth) / (count - 1);
    inset = count == 1 ? 0 : (lensWidth - pitch) / 2;
  }

  final double width;
  final int count;
  late final double lensWidth;
  late final double pitch;
  late final double inset;

  double centerOf(double position) =>
      _dockPadding + inset + (position + .5) * pitch;

  double positionAt(double x) =>
      pitch <= 0 ? 0 : (x - _dockPadding - inset) / pitch - .5;
}

class _NavigationDock extends StatefulWidget {
  const _NavigationDock({
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
  });

  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onSelected;

  @override
  State<_NavigationDock> createState() => _NavigationDockState();
}

class _NavigationDockState extends State<_NavigationDock>
    with TickerProviderStateMixin {
  late final _position = AnimationController.unbounded(
    value: widget.selectedIndex.toDouble(),
    vsync: this,
  )..addListener(_finishRelease);
  late final _lift = AnimationController.unbounded(vsync: this)
    ..addListener(_finishRelease);
  late final _swell = AnimationController.unbounded(vsync: this);
  late final _pull = AnimationController.unbounded(vsync: this);
  late final _motion = Listenable.merge([_position, _lift, _swell, _pull]);
  late double _target = widget.selectedIndex.toDouble();
  late _DockLayout _layout;
  bool _reduceMotion = false;
  bool _rtl = false;
  int? _pointer;
  int? _pressedIndex;
  int? _focusedIndex;
  double? _hoverPosition;
  double _pressX = 0;
  double _dragVelocity = 0;
  bool _dragging = false;
  bool _releasing = false;
  VelocityTracker? _velocity;

  int get _lastIndex => widget.destinations.length - 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rtl = Directionality.of(context) == TextDirection.rtl;
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) {
      _releasing = false;
      _position.value = _target;
      _lift.value = _swell.value = _pull.value = 0;
    }
  }

  @override
  void didUpdateWidget(covariant _NavigationDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destinations.length != widget.destinations.length) {
      _pointer = _pressedIndex = _focusedIndex = null;
      _hoverPosition = null;
      _velocity = null;
      _dragging = _releasing = false;
      _target = widget.selectedIndex.toDouble();
      _position.value = _target;
      _lift.value = _swell.value = _pull.value = 0;
    } else if (_pointer == null &&
        oldWidget.selectedIndex != widget.selectedIndex) {
      _moveTo(widget.selectedIndex.toDouble());
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _lift.dispose();
    _swell.dispose();
    _pull.dispose();
    super.dispose();
  }

  void _spring(
    AnimationController controller,
    double target,
    SpringDescription spring,
  ) {
    if (_reduceMotion) {
      controller.value = target;
      return;
    }
    controller.animateWith(
      SpringSimulation(
        spring,
        controller.value,
        target,
        controller.velocity,
        tolerance: const Tolerance(distance: .001, velocity: .01),
      ),
    );
  }

  void _moveTo(double target, [SpringDescription? spring]) {
    if (_target == target &&
        (_position.isAnimating || (_position.value - target).abs() < .001)) {
      return;
    }
    _target = target;
    _spring(_position, target, spring ?? _travelSpring);
  }

  void _finishRelease() {
    if (!_releasing || _pointer != null) return;
    if (_lift.value < .96 || (_position.value - _target).abs() > .04) return;
    _releasing = false;
    _spring(_lift, 0, _pressSpring);
  }

  double _positionAt(double x) {
    final position = _layout.positionAt(_rtl ? _layout.width - x : x);
    final bounded = position.clamp(0.0, _lastIndex.toDouble());
    final excess = position - bounded;
    return bounded + excess / (1 + excess.abs() / .35);
  }

  int _indexAt(double position) => position.round().clamp(0, _lastIndex);

  void _select(int index, {bool feedback = true}) {
    _moveTo(index.toDouble());
    if (index == widget.selectedIndex) return;
    if (feedback) HapticFeedback.selectionClick();
    widget.onSelected(index);
  }

  void _setSwell() => _spring(
    _swell,
    _pointer != null ? 1 : (_hoverPosition == null ? 0 : .4),
    _pressSpring,
  );

  void _hover(PointerHoverEvent event) {
    if (event.kind == PointerDeviceKind.touch || _pointer != null) return;
    final position = _positionAt(event.localPosition.dx);
    setState(() => _hoverPosition = position);
    final index = _indexAt(position);
    if (index == widget.selectedIndex) {
      _moveTo(index + (position - index) * .2, _hoverSpring);
    } else {
      _moveTo(widget.selectedIndex.toDouble(), _hoverSpring);
    }
    _setSwell();
  }

  void _exit(PointerExitEvent event) {
    setState(() => _hoverPosition = null);
    if (_pointer == null) {
      _moveTo(widget.selectedIndex.toDouble(), _hoverSpring);
    }
    _setSwell();
  }

  void _press(PointerDownEvent event) {
    if (_pointer != null || event.buttons & kPrimaryButton == 0) return;
    _pointer = event.pointer;
    _pressX = event.localPosition.dx;
    _pressedIndex = _indexAt(_positionAt(_pressX));
    _hoverPosition = null;
    _dragging = _releasing = false;
    _velocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    _moveTo(_pressedIndex!.toDouble());
    _spring(_lift, _reduceMotion ? 0 : 1, _pressSpring);
    _setSwell();
  }

  void _drag(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    _velocity?.addPosition(event.timeStamp, event.localPosition);
    if (!_dragging && (event.localPosition.dx - _pressX).abs() < kTouchSlop) {
      return;
    }
    _dragging = true;
    final x = event.localPosition.dx;
    final excess = x - x.clamp(0.0, _layout.width);
    _pull.value = _reduceMotion ? 0 : excess / (1 + excess.abs() / 14);
    _dragVelocity =
        (_velocity?.getVelocity().pixelsPerSecond.dx ?? 0) /
        math.max(1, _layout.pitch);
    final position = _positionAt(x);
    _target = position;
    _position.value = position;
    final index = _indexAt(position);
    if (index != _pressedIndex) {
      HapticFeedback.selectionClick();
      _pressedIndex = index;
    }
  }

  void _release(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final dragged = _dragging;
    var index = _pressedIndex ?? widget.selectedIndex;
    if (dragged && event is PointerUpEvent) {
      final speed = _velocity?.getVelocity().pixelsPerSecond.dx ?? 0;
      final lead = speed / math.max(1, _layout.pitch) * .1 * (_rtl ? -1 : 1);
      index = (_position.value + lead)
          .round()
          .clamp(index - 1, index + 1)
          .clamp(0, _lastIndex);
    }
    _pointer = _pressedIndex = null;
    _velocity = null;
    _dragging = false;
    _releasing = !_reduceMotion;
    final bounds = Rect.fromLTWH(
      0,
      0,
      _layout.width,
      CompactNavigation._heightOf(context),
    );
    _hoverPosition =
        event is PointerUpEvent &&
            event.kind == PointerDeviceKind.mouse &&
            bounds.contains(event.localPosition)
        ? _positionAt(event.localPosition.dx)
        : null;
    _spring(_pull, 0, _pressSpring);
    _setSwell();
    if (event is PointerUpEvent) {
      _select(index, feedback: !dragged);
    } else {
      _moveTo(widget.selectedIndex.toDouble());
    }
    _finishRelease();
  }

  Widget _items({
    required Color color,
    required TextStyle style,
    required double labelHeight,
    required double lift,
  }) => Padding(
    padding: EdgeInsets.symmetric(horizontal: _dockPadding + _layout.inset),
    child: Row(
      children: [
        for (final destination in widget.destinations)
          Expanded(
            child: Transform.scale(
              scale: 1 + .16 * lift,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconTheme.merge(
                      data: IconThemeData(size: _iconSize, color: color),
                      child: lift > 0
                          ? destination.selectedIcon ?? destination.icon
                          : destination.icon,
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: labelHeight,
                      child: Center(
                        child: Text(
                          destination.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: style.copyWith(color: color),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _actions(ColorScheme colors, Set<int> truncatedLabels) => Padding(
    padding: EdgeInsets.symmetric(horizontal: _dockPadding + _layout.inset),
    child: Row(
      children: [
        for (final (index, destination) in widget.destinations.indexed)
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              selected: index == widget.selectedIndex,
              label: destination.label,
              onTap: () => _select(index),
              child: ExcludeSemantics(
                child: FocusableActionDetector(
                  mouseCursor: SystemMouseCursors.click,
                  actions: {
                    ActivateIntent: CallbackAction<ActivateIntent>(
                      onInvoke: (_) {
                        _select(index);
                        return null;
                      },
                    ),
                  },
                  onShowFocusHighlight: (focused) => setState(() {
                    if (focused) {
                      _focusedIndex = index;
                    } else if (_focusedIndex == index) {
                      _focusedIndex = null;
                    }
                  }),
                  child: Tooltip(
                    message: truncatedLabels.contains(index)
                        ? destination.label
                        : '',
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: surfaceShape(1000).copyWith(
                          side: _focusedIndex == index
                              ? BorderSide(color: colors.primary, width: 2)
                              : BorderSide.none,
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final labelStyle = DefaultTextStyle.of(context).style.copyWith(
      fontSize: _labelSize,
      height: _labelHeight / _labelSize,
      fontWeight: FontWeight.w500,
      letterSpacing: 0,
    );
    var widest = 0.0;
    var labelHeight = 0.0;
    final labelWidths = <double>[];
    for (final destination in widget.destinations) {
      final painter = TextPainter(
        text: TextSpan(text: destination.label, style: labelStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      labelHeight = math.max(labelHeight, painter.height);
      labelWidths.add(painter.width);
      painter.dispose();
    }
    final strength = dark ? 3.0 : 1.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layout = _DockLayout(constraints.maxWidth, widget.destinations.length);
        final room = math.max(0.0, _layout.pitch - 4);
        final ratio = widest <= room ? 1.0 : math.max(.9, room / widest);
        final style = labelStyle.copyWith(fontSize: _labelSize * ratio);
        final actions = _actions(colors, {
          for (final (index, width) in labelWidths.indexed)
            if (width * ratio > room) index,
        });
        final inactive = _items(
          color: colors.onSurfaceVariant,
          style: style,
          labelHeight: labelHeight,
          lift: 0,
        );
        return MouseRegion(
          onHover: _hover,
          onExit: _exit,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _press,
            onPointerMove: _drag,
            onPointerUp: _release,
            onPointerCancel: _release,
            child: AnimatedBuilder(
              animation: _motion,
              builder: (context, _) {
                final lift = _reduceMotion ? 0.0 : _lift.value.clamp(0.0, 1.0);
                final velocity = _dragging ? _dragVelocity : _position.velocity;
                final stretch = _reduceMotion
                    ? 0.0
                    : (velocity.abs() / 25).clamp(0.0, .12);
                final height = constraints.maxHeight - _dockPadding * 2;
                Rect lensAt(double position, {double growth = 0}) {
                  final center = _layout.centerOf(position);
                  return Rect.fromCenter(
                    center: Offset(
                      _rtl ? constraints.maxWidth - center : center,
                      constraints.maxHeight / 2,
                    ),
                    width: (_layout.lensWidth + growth) * (1 + stretch),
                    height: (height + growth) * (1 - stretch),
                  );
                }

                final lens = lensAt(_position.value, growth: 16 * lift);
                final scale = _reduceMotion
                    ? 1.0
                    : 1 + 16 / math.max(1, constraints.maxWidth) * _swell.value;
                return Transform.translate(
                  offset: Offset(_pull.value, 0),
                  transformHitTests: false,
                  child: Transform.scale(
                    scale: scale,
                    transformHitTests: false,
                    child: DecoratedBox(
                      key: const ValueKey('android-navigation-bar'),
                      decoration: ShapeDecoration(
                        color: dark
                            ? colors.surfaceContainerHigh
                            : colors.surfaceBright,
                        shape: surfaceShape(1000),
                        shadows: [
                          BoxShadow(
                            color: colors.shadow.withValues(
                              alpha: .08 * strength,
                            ),
                            blurRadius: 24,
                            offset: const Offset(0, 8),
                          ),
                          BoxShadow(
                            color: colors.shadow.withValues(
                              alpha: .04 * strength,
                            ),
                            blurRadius: 3,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        fit: StackFit.expand,
                        children: [
                          if (_hoverPosition != null && _pointer == null)
                            Positioned.fromRect(
                              rect: lensAt(
                                _indexAt(_hoverPosition!) +
                                    (_hoverPosition! -
                                            _indexAt(_hoverPosition!)) *
                                        .2,
                              ),
                              child: DecoratedBox(
                                decoration: ShapeDecoration(
                                  color: colors.onSurface.withValues(
                                    alpha: .08,
                                  ),
                                  shape: surfaceShape(1000),
                                ),
                              ),
                            ),
                          Positioned.fromRect(
                            rect: lens,
                            child: DecoratedBox(
                              key: const ValueKey(
                                'android-navigation-selection',
                              ),
                              decoration: ShapeDecoration(
                                color: Color.alphaBlend(
                                  colors.onSurface.withValues(
                                    alpha: .08 * lift,
                                  ),
                                  dark
                                      ? colors.surfaceContainerHighest
                                      : colors.surfaceContainer,
                                ),
                                shape: surfaceShape(1000),
                              ),
                            ),
                          ),
                          ExcludeSemantics(
                            child: IgnorePointer(
                              child: Stack(
                                fit: StackFit.expand,
                                clipBehavior: Clip.none,
                                children: [
                                  ClipPath(
                                    clipper: _LensClipper(lens, outside: true),
                                    child: inactive,
                                  ),
                                  ClipPath(
                                    clipper: _LensClipper(lens),
                                    child: _items(
                                      color: colors.primary,
                                      style: style,
                                      labelHeight: labelHeight,
                                      lift: lift,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: _dockPadding,
                            ),
                            child: actions,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _LensClipper extends CustomClipper<Path> {
  const _LensClipper(this.lens, {this.outside = false});

  final Rect lens;
  final bool outside;

  @override
  Path getClip(Size size) {
    final shape = surfaceShape(1000).getOuterPath(lens);
    if (!outside) return shape;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(shape, Offset.zero);
  }

  @override
  bool shouldReclip(covariant _LensClipper oldClipper) =>
      oldClipper.lens != lens || oldClipper.outside != outside;
}
