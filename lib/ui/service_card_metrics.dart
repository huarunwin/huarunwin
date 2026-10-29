import 'package:flutter/material.dart';

import 'theme.dart';

/// Shared specification columns for service directory and package cards.
class ServiceCardMetrics extends StatelessWidget {
  const ServiceCardMetrics({
    super.key,
    required this.facts,
    required this.columns,
    this.truncate = true,
  });

  final List<MapEntry<String, String>> facts;
  final int columns;
  final bool truncate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final mobile = usesMobileDesign(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < facts.length; start += columns) ...[
          if (start > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < columns; column++) ...[
                if (column > 0) const SizedBox(width: 12),
                Expanded(
                  child: start + column >= facts.length
                      ? const SizedBox.shrink()
                      : Tooltip(
                          message:
                              '${facts[start + column].key}：${facts[start + column].value}',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                facts[start + column].key,
                                style: TextStyle(
                                  fontSize: compact ? 12 : (mobile ? 13 : 11),
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                facts[start + column].value,
                                maxLines: truncate ? 2 : null,
                                overflow: truncate
                                    ? TextOverflow.ellipsis
                                    : null,
                                style: TextStyle(
                                  fontSize: compact ? 13 : (mobile ? 15 : 13),
                                  fontWeight: compact
                                      ? FontWeight.w500
                                      : FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
