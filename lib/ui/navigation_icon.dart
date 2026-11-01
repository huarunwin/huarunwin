import 'package:flutter/material.dart';

enum _NavigationSymbol { discovery, library, cloud, airplane, settings }

class NavigationIcon extends StatelessWidget {
  const NavigationIcon.discovery({super.key})
    : _symbol = _NavigationSymbol.discovery;
  const NavigationIcon.library({super.key})
    : _symbol = _NavigationSymbol.library;
  const NavigationIcon.cloud({super.key}) : _symbol = _NavigationSymbol.cloud;
  const NavigationIcon.airplane({super.key})
    : _symbol = _NavigationSymbol.airplane;
  const NavigationIcon.settings({super.key})
    : _symbol = _NavigationSymbol.settings;

  final _NavigationSymbol _symbol;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final color = theme.color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return CustomPaint(
      size: Size.square(theme.size ?? 28),
      painter: _NavigationIconPainter(
        _symbol,
        color.withValues(alpha: color.a * (theme.opacity ?? 1)),
      ),
    );
  }
}

class _NavigationIconPainter extends CustomPainter {
  const _NavigationIconPainter(this.symbol, this.color);

  final _NavigationSymbol symbol;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;
    Path rounded(Rect rect, double radius) => Path()
      ..addRSuperellipse(
        RSuperellipse.fromRectAndRadius(rect, Radius.circular(radius)),
      );
    switch (symbol) {
      case _NavigationSymbol.discovery:
        for (final rect in const [
          Rect.fromLTRB(3, 3, 11, 12),
          Rect.fromLTRB(13, 3, 21, 10),
          Rect.fromLTRB(3, 14, 11, 21),
          Rect.fromLTRB(13, 12, 21, 21),
        ]) {
          canvas.drawPath(rounded(rect, 3), paint);
        }
      case _NavigationSymbol.library:
        canvas.drawPath(rounded(const Rect.fromLTRB(3, 3, 21, 7), 1.6), paint);
        final box = rounded(const Rect.fromLTRB(4, 8.5, 20, 21), 2.3)
          ..fillType = PathFillType.evenOdd
          ..addPath(
            rounded(const Rect.fromLTRB(8, 11.5, 16, 13.5), 1),
            Offset.zero,
          );
        canvas.drawPath(box, paint);
      case _NavigationSymbol.cloud:
        canvas.drawPath(
          Path()
            ..moveTo(6, 19.5)
            ..cubicTo(-.5, 19.5, -.8, 10, 5.5, 9.2)
            ..cubicTo(6.6, 1, 17, 1.2, 18.6, 9.2)
            ..cubicTo(25.2, 9.5, 25, 19.5, 18.5, 19.5)
            ..close(),
          paint,
        );
      case _NavigationSymbol.airplane:
        canvas.drawPath(
          Path()
            ..moveTo(10.5, 3.5)
            ..quadraticBezierTo(12, 0, 13.5, 3.5)
            ..lineTo(13.7, 9.2)
            ..lineTo(21, 14)
            ..quadraticBezierTo(22.2, 15, 21, 16)
            ..lineTo(13.8, 13.8)
            ..lineTo(13.7, 18.5)
            ..lineTo(16.4, 20.5)
            ..quadraticBezierTo(17.1, 21.4, 16, 22)
            ..lineTo(12, 20.6)
            ..lineTo(8, 22)
            ..quadraticBezierTo(6.9, 21.4, 7.6, 20.5)
            ..lineTo(10.3, 18.5)
            ..lineTo(10.2, 13.8)
            ..lineTo(3, 16)
            ..quadraticBezierTo(1.8, 15, 3, 14)
            ..lineTo(10.3, 9.2)
            ..close(),
          paint,
        );
      case _NavigationSymbol.settings:
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round;
        for (final y in [5.5, 12.0, 18.5]) {
          canvas.drawLine(Offset(3.5, y), Offset(20.5, y), paint);
        }
        paint.style = PaintingStyle.fill;
        for (final center in const [
          Offset(8, 5.5),
          Offset(16, 12),
          Offset(10, 18.5),
        ]) {
          canvas.drawPath(
            rounded(Rect.fromCenter(center: center, width: 4, height: 6), 1.5),
            paint,
          );
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NavigationIconPainter oldDelegate) =>
      oldDelegate.symbol != symbol || oldDelegate.color != color;
}
