import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/content_sources.dart';
import '../services/github_acceleration.dart';

class ContentSourceScope extends InheritedNotifier<Listenable> {
  ContentSourceScope({
    super.key,
    required this.sources,
    this.github,
    required super.child,
  }) : super(notifier: Listenable.merge([sources, github]));

  final ContentSources sources;
  final GitHubAcceleration? github;

  static ContentSourceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContentSourceScope>();
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
    final scope = ContentSourceScope.maybeOf(context);
    final urls =
        scope?.sources.imageUrls(imageUrl, github: scope.github) ?? [imageUrl];

    Widget render(int index) => CachedNetworkImage(
      key: ValueKey(
        '${scope?.sources.revision}|${scope?.github?.mode.name}|${urls[index]}',
      ),
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
