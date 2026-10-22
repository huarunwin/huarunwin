import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/content_sources.dart';

class ContentSourceScope extends InheritedNotifier<ContentSources> {
  const ContentSourceScope({
    super.key,
    required ContentSources sources,
    required super.child,
  }) : super(notifier: sources);

  static ContentSources? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ContentSourceScope>()
      ?.notifier;
}

/// Resolve only image transport URLs; models keep their original website URLs.
class ContentImage extends StatelessWidget {
  const ContentImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.errorWidget,
    this.imageBuilder,
  });

  final String imageUrl;
  final double? width, height;
  final BoxFit? fit;
  final PlaceholderWidgetBuilder? placeholder;
  final LoadingErrorWidgetBuilder? errorWidget;
  final ImageWidgetBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    final sources = ContentSourceScope.maybeOf(context);
    final urls = sources == null
        ? [imageUrl]
        : {
            for (final origin in sources.candidates)
              sources.imageUrl(imageUrl, origin: origin),
          }.toList();

    Widget render(int index) => CachedNetworkImage(
      key: ValueKey('${sources?.revision}|${urls[index]}'),
      imageUrl: urls[index],
      width: width,
      height: height,
      fit: fit,
      placeholder: placeholder,
      imageBuilder: imageBuilder,
      errorWidget: (context, _, error) {
        if (index + 1 < urls.length) {
          return render(index + 1);
        }
        return errorWidget?.call(context, imageUrl, error) ??
            const Icon(Icons.broken_image_outlined);
      },
    );

    return render(0);
  }
}
