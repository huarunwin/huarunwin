import 'package:flutter/material.dart';

import '../data/site_models.dart';
import 'detail_components.dart';
import 'site_reader.dart';
import 'content_image.dart';
import 'theme.dart';

class ServiceDetailHero extends StatelessWidget {
  const ServiceDetailHero({
    super.key,
    required this.detail,
    required this.onOpen,
    this.compact,
  });

  final SiteServiceDetails detail;
  final ValueChanged<String> onOpen;
  final bool? compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = this.compact ?? constraints.maxWidth < 600;
      final desktopAirport = !compact && detail.kind == SiteServiceKind.airport;
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final icon = detail.kind == SiteServiceKind.vps
          ? Icons.cloud_outlined
          : Icons.flight_rounded;
      final iconSize = compact
          ? (constraints.maxWidth * .3).clamp(88.0, 140.0)
          : desktopAirport
          ? 96.0
          : 112.0;
      final purchase = detail.purchase;
      final actionStyle = compact
          ? FilledButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              overlayColor: colors.onPrimary,
              textStyle: const TextStyle(
                fontSize: 16,
                height: 20 / 16,
                fontWeight: FontWeight.w600,
              ),
            ).merge(downloadButtonStyle(context))
          : downloadButtonStyle(context);
      final hero = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipPath.shape(
            shape: surfaceShape(iconSize * .25),
            child: SizedBox.square(
              dimension: iconSize,
              child: detail.image == null
                  ? ColoredBox(
                      color: colors.surfaceContainer,
                      child: Icon(
                        icon,
                        size: iconSize * .43,
                        color: colors.primary,
                      ),
                    )
                  : ColoredBox(
                      // Preserve the contrast of transparent published logos.
                      color: const Color(0xfff5f5f5),
                      child: ContentImage(
                        imageUrl: detail.image!,
                        fit: BoxFit.contain,
                        errorWidget: (_, _, _) => Icon(
                          icon,
                          size: iconSize * .43,
                          color: Colors.black54,
                        ),
                      ),
                    ),
            ),
          ),
          SizedBox(width: compact ? 16 : (desktopAirport ? 20 : 26)),
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: compact || desktopAirport ? iconSize : 0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: detail.title,
                        child: Text(
                          detail.title,
                          maxLines: compact ? 3 : null,
                          overflow: compact ? TextOverflow.ellipsis : null,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontSize: compact ? 22 : (desktopAirport ? 28 : 30),
                            height: compact
                                ? 27 / 22
                                : (desktopAirport ? 1.2 : null),
                            fontWeight: compact || desktopAirport
                                ? FontWeight.w600
                                : null,
                          ),
                        ),
                      ),
                      if (!desktopAirport || detail.identity.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        SiteRichText(
                          detail.identity.isNotEmpty
                              ? detail.identity
                              : [
                                  SiteText(
                                    detail.kind == SiteServiceKind.vps
                                        ? 'VPS 套餐'
                                        : '机场',
                                  ),
                                ],
                          onLink: onOpen,
                          style: TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (purchase != null)
                    Padding(
                      padding: EdgeInsets.only(
                        top: compact || desktopAirport ? 8 : 16,
                      ),
                      child: FilledButton(
                        style: actionStyle,
                        onPressed: () => onOpen(purchase.url),
                        child: Text(purchase.label),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
      if (!desktopAirport || detail.highlights.isEmpty) return hero;
      final highlights = _AirportHighlights(values: detail.highlights);
      final textScaler = MediaQuery.textScalerOf(context);
      if (constraints.maxWidth >= textScaler.scale(840)) {
        return Row(
          children: [
            Expanded(child: hero),
            const SizedBox(width: 40),
            SizedBox(width: textScaler.scale(300), child: highlights),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [hero, const SizedBox(height: 20), highlights],
      );
    },
  );
}

class _AirportHighlights extends StatelessWidget {
  const _AirportHighlights({required this.values});

  final Map<String, String> values;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final textScaler = MediaQuery.textScalerOf(context);
      final width = constraints.maxWidth.clamp(0.0, textScaler.scale(360));
      final columns = values.length.clamp(1, 2);
      return Wrap(
        spacing: 24,
        runSpacing: 16,
        children: [
          for (final entry in values.entries)
            SizedBox(
              width: (width - (columns - 1) * 24) / columns,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.value,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    },
  );
}

class ServiceDetailOverview extends StatelessWidget {
  const ServiceDetailOverview({super.key, required this.detail});

  final SiteServiceDetails detail;

  bool get hasContent =>
      detail.price.isNotEmpty ||
      detail.referencePrice.isNotEmpty ||
      detail.referenceNote.isNotEmpty ||
      detail.subtitle.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final sections = <Widget>[
      if (detail.price.isNotEmpty ||
          detail.referencePrice.isNotEmpty ||
          detail.referenceNote.isNotEmpty)
        DetailSection(
          title: '官方报价',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detail.price.isNotEmpty)
                Text(
                  detail.price,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontSize: 16,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              if (detail.referencePrice.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: detail.price.isEmpty ? 0 : 6),
                  child: Text(
                    '人民币参考价：${detail.referencePrice}',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (detail.referenceNote.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    detail.referenceNote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (detail.subtitle.isNotEmpty)
        DetailSection(
          title: detail.kind == SiteServiceKind.vps ? '套餐介绍' : '机场介绍',
          child: DetailText(detail.subtitle, maxLines: 7),
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < sections.length; index++) ...[
          if (index > 0) const DetailSectionDivider(),
          sections[index],
        ],
      ],
    );
  }
}
