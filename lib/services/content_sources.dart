import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ContentSourceMode {
  automatic('自动'),
  website('华润赢网站'),
  github('GitHub 镜像'),
  jsdelivr('jsDelivr 镜像');

  const ContentSourceMode(this.label);
  final String label;
}

enum ContentOrigin {
  website('华润赢网站'),
  github('GitHub 镜像'),
  jsdelivr('jsDelivr 镜像');

  const ContentOrigin(this.label);
  final String label;
}

typedef ContentSourceRequest = ({
  int revision,
  int selection,
  List<ContentOrigin> candidates,
});

/// Transport choices never replace the original URLs in parsed content.
class ContentSources extends ChangeNotifier {
  static const mirrorRepository = 'huarunwin/huarunwin-static';
  static const mirrorBranch = 'main';
  static const fallbackDuration = Duration(hours: 2);
  SharedPreferences? _preferences;
  ContentSourceMode mode = ContentSourceMode.automatic;
  ContentOrigin _lastSuccessful = ContentOrigin.website;
  DateTime? _fallbackStartedAt;
  int _selection = 0;
  Future<void>? _stateWrite;
  bool hasSuccessfulSource = false;
  int revision = 0;

  ContentOrigin get active => switch (mode) {
    ContentSourceMode.automatic => _lastSuccessful,
    ContentSourceMode.website => ContentOrigin.website,
    ContentSourceMode.github => ContentOrigin.github,
    ContentSourceMode.jsdelivr => ContentOrigin.jsdelivr,
  };

  // Images and cached content keep the last working source until HTML succeeds.
  List<ContentOrigin> get candidates => _candidates(active);

  List<ContentOrigin> _candidates(ContentOrigin preferred) => [
    preferred,
    if (mode == ContentSourceMode.automatic)
      for (final origin in ContentOrigin.values)
        if (origin != preferred) origin,
  ];

  ContentSourceRequest beginRequest() {
    if (mode == ContentSourceMode.automatic && _fallbackStartedAt != null) {
      final elapsed = DateTime.now().toUtc().difference(_fallbackStartedAt!);
      if (elapsed.isNegative || elapsed >= fallbackDuration) {
        _fallbackStartedAt = null;
        _selection++;
        unawaited(_persistState());
      }
    }
    return (
      revision: revision,
      selection: _selection,
      candidates: _candidates(
        mode == ContentSourceMode.automatic && _fallbackStartedAt == null
            ? ContentOrigin.website
            : active,
      ),
    );
  }

  /// Called once per user refresh, before its catalog and detail requests.
  void retryPrimary() {
    if (mode != ContentSourceMode.automatic) return;
    _fallbackStartedAt = null;
    _selection++;
    unawaited(_persistState());
  }

  Future<void> reload() async {
    final preferences = _preferences;
    if (preferences == null) return;
    final selection = _selection;
    await _stateWrite;
    await preferences.reload();
    // Settings may be refreshed while another request chooses a new source.
    if (selection == _selection) restore(preferences, notify: true);
  }

  @override
  void dispose() {
    _selection++;
    revision++;
    super.dispose();
  }

  void restore(SharedPreferences preferences, {bool notify = false}) {
    _preferences = preferences;
    final nextMode =
        ContentSourceMode.values
            .where(
              (value) => value.name == preferences.getString('contentSource'),
            )
            .firstOrNull ??
        ContentSourceMode.automatic;
    var previous = preferences.getString('lastContentOrigin');
    DateTime? fallbackStartedAt;
    final stored = preferences.get('contentSourceState');
    if (stored is String) {
      try {
        final state = jsonDecode(stored);
        if (state is Map<String, dynamic> && state['origin'] is String) {
          previous = state['origin'] as String;
          if (state['fallbackStartedAt'] case final String value) {
            fallbackStartedAt = DateTime.tryParse(value)?.toUtc();
          }
        }
      } on FormatException {
        // Older installations only have lastContentOrigin, with no hold time.
      }
    }
    final nextOrigin = ContentOrigin.values
        .where((value) => value.name == previous)
        .firstOrNull;
    if (nextOrigin == null || nextOrigin == ContentOrigin.website) {
      fallbackStartedAt = null;
    }
    final changed =
        mode != nextMode ||
        hasSuccessfulSource != (nextOrigin != null) ||
        (nextOrigin ?? ContentOrigin.website) != _lastSuccessful ||
        fallbackStartedAt != _fallbackStartedAt;
    mode = nextMode;
    _lastSuccessful = nextOrigin ?? ContentOrigin.website;
    _fallbackStartedAt = fallbackStartedAt;
    hasSuccessfulSource = nextOrigin != null;
    if (changed) _selection++;
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
    _fallbackStartedAt = null;
    _selection++;
    revision++;
    unawaited(_persistState());
    notifyListeners();
  }

  Future<void> succeeded(
    ContentOrigin origin, {
    required ContentSourceRequest request,
  }) async {
    // A late result must not undo a manual retry, recovery or source change.
    if (request.revision != revision || request.selection != _selection) return;
    final fallbackStartedAt =
        mode == ContentSourceMode.automatic && origin != ContentOrigin.website
        ? (origin != request.candidates.first || _fallbackStartedAt == null
              ? DateTime.now().toUtc()
              : _fallbackStartedAt)
        : null;
    final changed =
        !hasSuccessfulSource ||
        _lastSuccessful != origin ||
        _fallbackStartedAt != fallbackStartedAt;
    _lastSuccessful = origin;
    _fallbackStartedAt = fallbackStartedAt;
    hasSuccessfulSource = true;
    if (changed) {
      _selection++;
      await _persistState();
      if (request.revision == revision) notifyListeners();
    }
  }

  Future<void> _persistState() {
    final preferences = _preferences;
    // Keep the source and hold start together, and serialize concurrent writes.
    final state = jsonEncode({
      'origin': hasSuccessfulSource ? _lastSuccessful.name : null,
      'fallbackStartedAt': _fallbackStartedAt?.toIso8601String(),
    });
    final write = (_stateWrite ?? Future<void>.value()).then((_) async {
      try {
        await preferences?.setString('contentSourceState', state);
      } catch (_) {
        // A preference write failure must not hide successfully read content.
      }
    });
    _stateWrite = write;
    return write.whenComplete(() {
      if (identical(_stateWrite, write)) _stateWrite = null;
    });
  }

  Uri pageUri(Uri original, ContentOrigin origin) {
    if (origin == ContentOrigin.website) return original;
    final segments = original.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      segments.add('index.html');
    } else if (!segments.last.endsWith('.html')) {
      segments[segments.length - 1] = '${segments.last}.html';
    }
    return _mirrorUri(segments, original, origin);
  }

  Uri _mirrorUri(List<String> segments, Uri original, ContentOrigin origin) {
    final (host, prefix) = switch (origin) {
      ContentOrigin.github => (
        'raw.githubusercontent.com',
        '$mirrorRepository/$mirrorBranch',
      ),
      ContentOrigin.jsdelivr => (
        'cdn.jsdelivr.net',
        'gh/$mirrorRepository@$mirrorBranch',
      ),
      ContentOrigin.website => throw ArgumentError.value(origin),
    };
    return Uri(
      scheme: 'https',
      host: host,
      pathSegments: [...prefix.split('/'), ...segments],
      query: original.hasQuery ? original.query : null,
    );
  }

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
    return _mirrorUri(uri.pathSegments, uri, origin ?? active).toString();
  }
}
