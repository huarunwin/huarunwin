import 'package:flutter/material.dart';

class AirportPrice extends StatelessWidget {
  const AirportPrice({super.key, required this.value, this.fontSize = 26});

  final String value;
  final double fontSize;

  // Split only for typography; keep the published amount and suffix as text.
  static final _parts = RegExp(r'^([≈约]?\s*[¥￥\$€£]\s*)(\d+(?:[.,]\d+)*)(.*)$');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parts = _parts.firstMatch(value);
    if (parts == null) {
      return Text(
        value,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      );
    }
    final suffix = parts[3]!.trimLeft();
    return Semantics(
      label: value,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            parts[1]!,
            style: TextStyle(
              fontSize: 14,
              height: 1.15,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: parts[2]),
                  if (suffix.isNotEmpty)
                    TextSpan(
                      text: ' $suffix',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              style: TextStyle(
                fontSize: fontSize,
                height: 1.15,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
