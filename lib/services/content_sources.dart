import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ContentSourceMode {
  automatic('自动'),
  website('华润赢网站'),
  github('GitHub 镜像');

  const ContentSourceMode(this.label);
  final String label;
}

enum ContentOrigin {
  website('华润赢网站'),
  github('GitHub 镜像');

  const ContentOrigin(this.label);
  final String label;
  ContentOrigin get alternative => this == website ? github : website;
}

/// Transport choices never replace the original URLs in parsed content.
class ContentSources extends ChangeNotifier {
  static const mirrorRepository = 'huarunwin/huarunwin-static';
  SharedPreferences? _preferences;
  ContentSourceMode mode = ContentSourceMode.automatic;
  ContentOrigin _lastSuccessful = ContentOrigin.website;
  bool hasSuccessfulSource = false;
  int revision = 0;

  ContentOrigin get active => switch (mode) {
    ContentSourceMode.automatic => _lastSuccessful,
    ContentSourceMode.website => ContentOrigin.website,
    ContentSourceMode.github => ContentOrigin.github,
  };

  void restore(SharedPreferences preferences, {bool notify = false}) {
    _preferences = preferences;
    final nextMode =
        ContentSourceMode.values
            .where(
              (value) => value.name == preferences.getString('contentSource'),
            )
            .firstOrNull ??
        ContentSourceMode.automatic;
    final previous = preferences.getString('lastContentOrigin');
    final nextOrigin = ContentOrigin.values
        .where((value) => value.name == previous)
        .firstOrNull;
    final changed =
        mode != nextMode ||
        mode == ContentSourceMode.automatic &&
            (nextOrigin ?? ContentOrigin.website) != _lastSuccessful;
    mode = nextMode;
    _lastSuccessful = nextOrigin ?? ContentOrigin.website;
    hasSuccessfulSource = nextOrigin != null;
    if (notify && changed) {
      revision++;
      notifyListeners();
    }
  }

  Future<void> select(ContentSourceMode value) async {
    if (mode == value) return;
    final preferences = _preferences;
    if (preferences != null &&
        !await preferences.setString('contentSource', value.name)) {
      throw StateError('Unable to save the content source');
    }
    mode = value;
    revision++;
    notifyListeners();
  }

  Future<void> succeeded(
    ContentOrigin origin, {
    required int requestRevision,
    required ContentOrigin preferred,
  }) async {
    if (requestRevision != revision) return;
    // A late request from an earlier automatic choice must not undo a fallback.
    if (mode == ContentSourceMode.automatic && active != preferred) return;
    final changed = !hasSuccessfulSource || _lastSuccessful != origin;
    _lastSuccessful = origin;
    hasSuccessfulSource = true;
    if (changed) {
      try {
        await _preferences?.setString('lastContentOrigin', origin.name);
      } catch (_) {
        // A preference write failure must not hide successfully read content.
      }
      if (requestRevision == revision) notifyListeners();
    }
  }

  Uri pageUri(Uri original, ContentOrigin origin) {
    if (origin == ContentOrigin.website) return original;
    final segments = original.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      segments.add('index.html');
    } else if (!segments.last.endsWith('.html')) {
      segments[segments.length - 1] = '${segments.last}.html';
    }
    return _mirrorUri(segments, original);
  }

  Uri _mirrorUri(List<String> segments, Uri original) => Uri(
    scheme: 'https',
    host: 'raw.githubusercontent.com',
    pathSegments: ['huarunwin', 'huarunwin-static', 'main', ...segments],
    query: original.hasQuery ? original.query : null,
  );

  bool isSiteImage(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'huarun.win' &&
      !uri.hasPort &&
      uri.userInfo.isEmpty &&
      uri.pathSegments.every(
        (part) =>
            part.isNotEmpty &&
            part != '.' &&
            part != '..' &&
            !part.contains('/') &&
            !part.contains('\\'),
      ) &&
      RegExp(
        r'\.(png|jpe?g|webp|avif|gif|svg|ico)$',
        caseSensitive: false,
      ).hasMatch(uri.path);

  String imageUrl(String original, {ContentOrigin? origin}) {
    final uri = Uri.tryParse(original);
    if (uri == null ||
        !isSiteImage(uri) ||
        (origin ?? active) == ContentOrigin.website) {
      return original;
    }
    return _mirrorUri(uri.pathSegments, uri).toString();
  }
}
