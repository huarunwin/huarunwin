import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

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

  static double insetOf(BuildContext context) =>
      62 +
      math.max(0, MediaQuery.textScalerOf(context).scale(10) - 10) +
      math.max(21, MediaQuery.viewPaddingOf(context).bottom);

  @override
  Widget build(BuildContext context) {
    if (usesMobileDesign(context)) {
      return _MobileNavigationDock(
        selectedIndex: selectedIndex,
        destinations: destinations,
        onSelected: onSelected,
      );
    }
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Material(
            color: Theme.of(context).brightness == Brightness.dark
                ? colors.surfaceContainerHigh
                : colors.surfaceContainerLow,
            elevation: 3,
            shadowColor: Colors.black.withValues(alpha: .18),
            shape: surfaceShape(32),
            clipBehavior: Clip.antiAlias,
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              removeTop: true,
              child: NavigationBar(
                height: 64 + math.max(0, media.textScaler.scale(12) - 12),
                elevation: 0,
                backgroundColor: Colors.transparent,
                indicatorShape: surfaceShape(1000),
                selectedIndex: selectedIndex,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                onDestinationSelected: onSelected,
                destinations: destinations,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MobileNavigationDock extends StatefulWidget {
  const _MobileNavigationDock({
    required this.selectedIndex,
    required this.destinations,
    required this.onSelected,
  });

  final int selectedIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onSelected;

  @override
  State<_MobileNavigationDock> createState() => _MobileNavigationDockState();
}

class _MobileNavigationDockState extends State<_MobileNavigationDock> {
  double? _dragPosition;
  int? _pressedIndex;

  void _select(int index) {
    if (index != widget.selectedIndex) HapticFeedback.selectionClick();
    widget.onSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    final position = _dragPosition ?? widget.selectedIndex.toDouble();
    final selected = position.round();
    final duration = media.disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 280);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        21 + media.padding.left,
        8,
        21 + media.padding.right,
        math.max(21, media.viewPadding.bottom),
      ),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.destinations.length >= 5
                ? double.infinity
                : widget.destinations.length * 86 + 16,
          ),
          child: Material(
            color: colors.brightness == Brightness.dark
                ? colors.surfaceContainer
                : colors.surfaceContainerLow,
            elevation: 8,
            shadowColor: Colors.black.withValues(alpha: .16),
            shape: surfaceShape(1000),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              key: const ValueKey('android-navigation-bar'),
              height: 62 + math.max(0, media.textScaler.scale(10) - 10),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    double positionAt(double x) =>
                        (x / constraints.maxWidth * widget.destinations.length -
                                .5)
                            .clamp(0.0, widget.destinations.length - 1.0);
                    return GestureDetector(
                      onHorizontalDragStart: (event) => setState(
                        () =>
                            _dragPosition = positionAt(event.localPosition.dx),
                      ),
                      onHorizontalDragUpdate: (event) => setState(
                        () =>
                            _dragPosition = positionAt(event.localPosition.dx),
                      ),
                      onHorizontalDragCancel: () =>
                          setState(() => _dragPosition = null),
                      onHorizontalDragEnd: (_) {
                        final index = _dragPosition?.round();
                        setState(() => _dragPosition = null);
                        if (index != null) _select(index);
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          AnimatedAlign(
                            duration: _dragPosition == null
                                ? duration
                                : Duration.zero,
                            curve: Curves.easeOutCubic,
                            alignment: Alignment(
                              widget.destinations.length == 1
                                  ? 0
                                  : -1 +
                                        position *
                                            2 /
                                            (widget.destinations.length - 1),
                              0,
                            ),
                            child: FractionallySizedBox(
                              widthFactor: 1 / widget.destinations.length,
                              heightFactor: 1,
                              child: DecoratedBox(
                                key: const ValueKey(
                                  'android-navigation-selection',
                                ),
                                decoration: ShapeDecoration(
                                  color: colors.brightness == Brightness.dark
                                      ? colors.surfaceContainerHigh
                                      : colors.surfaceContainer,
                                  shape: surfaceShape(1000),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              for (final (index, destination)
                                  in widget.destinations.indexed)
                                Expanded(
                                  child: Semantics(
                                    button: true,
                                    selected: index == widget.selectedIndex,
                                    label: destination.label,
                                    onTap: () => _select(index),
                                    child: ExcludeSemantics(
                                      child: InkWell(
                                        customBorder: surfaceShape(1000),
                                        onTap: () => _select(index),
                                        onHighlightChanged: (pressed) =>
                                            setState(
                                              () => _pressedIndex = pressed
                                                  ? index
                                                  : null,
                                            ),
                                        child: AnimatedScale(
                                          scale: _pressedIndex == index
                                              ? .92
                                              : 1,
                                          duration: duration,
                                          child: Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              IconTheme.merge(
                                                data: IconThemeData(
                                                  size: 28,
                                                  color: index == selected
                                                      ? colors.primary
                                                      : colors.onSurfaceVariant,
                                                ),
                                                child: index == selected
                                                    ? destination
                                                              .selectedIcon ??
                                                          destination.icon
                                                    : destination.icon,
                                              ),
                                              const SizedBox(height: 2),
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 2,
                                                    ),
                                                child: FittedBox(
                                                  fit: BoxFit.scaleDown,
                                                  child: Text(
                                                    destination.label,
                                                    maxLines: 1,
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      height: 1.45,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: index == selected
                                                          ? colors.primary
                                                          : colors
                                                                .onSurfaceVariant,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
