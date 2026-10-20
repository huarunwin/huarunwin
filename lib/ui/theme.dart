import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Matches the background of assets/brand/huarun-icon.svg.
const brandColor = Color(0xFF0071E3);

const compactLayoutBreakpoint = 600.0;

bool usesMobileDesign(BuildContext context) =>
    usesMobileDesignForWidth(MediaQuery.sizeOf(context).width);

// Narrow windows share the Android design; native capabilities still use the
// real operating system. Keep the existing Android appearance on larger screens.
bool usesMobileDesignForWidth(double width) =>
    width < compactLayoutBreakpoint ||
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

RoundedSuperellipseBorder surfaceShape([double radius = 24]) =>
    RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));

ButtonStyle downloadButtonStyle(BuildContext context) {
  final colors = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    backgroundColor: colors.surfaceContainer,
    foregroundColor: colors.primary,
    disabledBackgroundColor: colors.surfaceContainer,
    disabledForegroundColor: colors.onSurface.withValues(alpha: .38),
    overlayColor: colors.primary,
    elevation: 0,
    shadowColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    shape: surfaceShape(1000),
    minimumSize: const Size(74, 34),
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 7),
    textStyle: const TextStyle(
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w600,
    ),
    visualDensity: VisualDensity.standard,
    tapTargetSize: MaterialTapTargetSize.padded,
  );
}

class ContinuousInputBorder extends InputBorder {
  const ContinuousInputBorder({
    super.borderSide = BorderSide.none,
    this.radius = 24,
  });
  final double radius;

  RoundedSuperellipseBorder get _shape => RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: borderSide,
  );

  @override
  bool get isOutline => true;
  @override
  EdgeInsetsGeometry get dimensions => _shape.dimensions;
  @override
  ContinuousInputBorder copyWith({BorderSide? borderSide}) =>
      ContinuousInputBorder(
        borderSide: borderSide ?? this.borderSide,
        radius: radius,
      );
  @override
  ContinuousInputBorder scale(double t) => ContinuousInputBorder(
    borderSide: borderSide.scale(t),
    radius: radius * t,
  );
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _shape.getOuterPath(rect, textDirection: textDirection);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _shape.getInnerPath(rect, textDirection: textDirection);
  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0,
    double gapPercentage = 0,
    TextDirection? textDirection,
  }) => _shape.paint(canvas, rect, textDirection: textDirection);
}

ThemeData appTheme(Brightness brightness, {double width = double.infinity}) {
  final dark = brightness == Brightness.dark;
  final mobile = usesMobileDesignForWidth(width);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: brandColor,
        brightness: brightness,
        primary: dark ? null : brandColor,
        onPrimary: dark ? null : Colors.white,
      ).copyWith(
        surface: dark ? const Color(0xFF141414) : const Color(0xFFF3F3F3),
        surfaceContainer: dark
            ? const Color(0xFF292929)
            : const Color(0xFFEBEBEB),
        surfaceContainerLow: dark
            ? const Color(0xFF202020)
            : const Color(0xFFFAFAFA),
        surfaceBright: dark ? const Color(0xFF393939) : const Color(0xFFFAFAFA),
        surfaceContainerHigh: dark
            ? const Color(0xFF313131)
            : const Color(0xFFE5E5E5),
        surfaceContainerHighest: dark
            ? const Color(0xFF393939)
            : const Color(0xFFDEDEDE),
        onSurface: dark ? const Color(0xFFE8E8E8) : const Color(0xFF202020),
        onSurfaceVariant: dark
            ? const Color(0xFFBABABA)
            : const Color(0xFF606060),
      );
  final colors = mobile
      ? scheme.copyWith(
          surface: dark ? const Color(0xFF141418) : const Color(0xFFEFEDF0),
          surfaceContainerLow: dark
              ? const Color(0xFF222226)
              : const Color(0xFFFCFAFC),
          surfaceBright: dark
              ? const Color(0xFF3A3A40)
              : const Color(0xFFFCFAFC),
          surfaceContainer: dark
              ? const Color(0xFF2D2D32)
              : const Color(0xFFEFEDF0),
          surfaceContainerHigh: dark
              ? const Color(0xFF38383F)
              : const Color(0xFFE6E3E8),
          surfaceContainerHighest: dark
              ? const Color(0xFF44444C)
              : const Color(0xFFDDDAE0),
          onSurface: dark ? const Color(0xFFF0EEF3) : const Color(0xFF1C1D24),
          onSurfaceVariant: dark
              ? const Color(0xFFC5C2CD)
              : const Color(0xFF4A4C59),
        )
      : scheme;
  final base = ThemeData(useMaterial3: true, colorScheme: colors);
  return base.copyWith(
    scaffoldBackgroundColor: colors.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      titleSpacing: 20,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: colors.onSurface,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      border: const ContinuousInputBorder(),
      enabledBorder: const ContinuousInputBorder(),
      focusedBorder: const ContinuousInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      prefixIconColor: colors.onSurfaceVariant,
      suffixIconColor: colors.onSurfaceVariant,
      hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
    ),
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: surfaceShape(mobile ? 34 : 20),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: surfaceShape(1000),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: surfaceShape(1000),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainer,
        foregroundColor: colors.onSurface,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: surfaceShape(1000),
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: surfaceShape(14),
      side: BorderSide.none,
      selectedColor: colors.primary,
      secondarySelectedColor: colors.primary,
      backgroundColor: colors.surfaceContainerLow,
      labelStyle: TextStyle(color: colors.onSurface, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: colors.onPrimary, fontSize: 13),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
    ),
    dialogTheme: DialogThemeData(
      shape: surfaceShape(mobile ? 34 : 24),
      backgroundColor: dark
          ? colors.surfaceContainerHigh
          : colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: colors.onSurface,
      ),
      contentTextStyle: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.5,
        color: colors.onSurfaceVariant,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      shape: mobile
          ? const RoundedSuperellipseBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            )
          : surfaceShape(28),
      backgroundColor: dark ? colors.surfaceContainer : colors.surface,
      showDragHandle: true,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: surfaceShape(16),
      color: dark ? colors.surfaceContainerHigh : colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      textStyle: TextStyle(fontSize: 14, color: colors.onSurface),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.onSurfaceVariant,
      textColor: colors.onSurface,
      titleTextStyle: base.textTheme.bodyMedium?.copyWith(
        fontSize: 14,
        height: 1.4,
        color: colors.onSurface,
      ),
      subtitleTextStyle: base.textTheme.bodySmall?.copyWith(
        fontSize: 12,
        height: 1.5,
        color: colors.onSurfaceVariant,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.onSurface.withValues(alpha: .14),
      thickness: .75,
      space: 1,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainerLow,
      indicatorColor: colors.surfaceContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: surfaceShape(16),
    ),
    textTheme: base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.7,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: mobile ? 17 : null,
        height: mobile ? 22 / 17 : null,
        fontWeight: FontWeight.w600,
        letterSpacing: mobile ? 0 : null,
      ),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        fontSize: mobile ? 13 : null,
        height: mobile ? 18 / 13 : null,
        letterSpacing: mobile ? 0 : null,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        fontSize: mobile ? 15 : null,
        height: mobile ? 20 / 15 : 1.55,
        letterSpacing: mobile ? 0 : null,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(
        fontSize: mobile ? 17 : null,
        height: mobile ? 22 / 17 : 1.65,
        letterSpacing: mobile ? 0 : null,
      ),
    ),
  );
}
