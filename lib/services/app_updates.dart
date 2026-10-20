import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_changelog.dart';
import 'installed_apps.dart';

class AppUpdateResult {
  const AppUpdateResult({required this.currentVersion, required this.feed});

  final String currentVersion;
  final AppUpdateFeed feed;

  AppRelease? get update {
    final publishedVersion = feed.publishedVersion;
    return publishedVersion != null &&
            hasNewerVersion(currentVersion, publishedVersion)
        ? feed.published
        : null;
  }

  Uri? get releaseUrl => update?.downloadUrl;
}

class AppUpdates {
  AppUpdates({
    Dio? client,
    Future<String> Function()? readVersion,
    AppUpdateChannel? channel,
    SharedPreferences? preferences,
  }) : channel = channel ?? buildChannel,
       _preferences = preferences == null ? null : Future.value(preferences),
       _client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 20),
               responseType: ResponseType.plain,
               headers: {
                 'Accept': 'application/json',
                 'Cache-Control': 'no-cache',
               },
             ),
           ),
       _readVersion = readVersion ?? _packageVersion;

  static final instance = AppUpdates();
  static const metadataUrl =
      'https://raw.githubusercontent.com/huarunwin/huarunwin-hub/main/api/updates.json';

  static AppUpdateChannel get buildChannel {
    const configured = String.fromEnvironment('HUARUNWIN_UPDATE_CHANNEL');
    return switch (configured) {
      'release' => AppUpdateChannel.release,
      'debug' => AppUpdateChannel.debug,
      '' => kDebugMode ? AppUpdateChannel.debug : AppUpdateChannel.release,
      _ => throw const FormatException('Invalid update channel'),
    };
  }

  final AppUpdateChannel channel;
  final Dio _client;
  final Future<String> Function() _readVersion;
  Future<String>? _version;
  Future<AppUpdateResult>? _pending;
  Future<SharedPreferences>? _preferences;

  String get _ignoredVersionsKey =>
      'appUpdates.ignoredVersions.${channel.name}';

  Future<SharedPreferences> _loadPreferences() async {
    try {
      return await (_preferences ??= SharedPreferences.getInstance());
    } catch (_) {
      _preferences = null;
      rethrow;
    }
  }

  Future<bool> shouldNotify(
    AppUpdateResult result, {
    bool manual = false,
  }) async {
    final update = result.update;
    if (update == null) return false;
    if (manual) return true;
    final preferences = await _loadPreferences();
    return !(preferences.getStringList(_ignoredVersionsKey) ?? const <String>[])
        .contains(update.version);
  }

  Future<void> ignoreVersion(String version) async {
    if (!AppUpdateFeed.isVersion(version)) {
      throw const FormatException('Invalid ignored version');
    }
    final preferences = await _loadPreferences();
    final ignored =
        preferences.getStringList(_ignoredVersionsKey) ?? <String>[];
    if (ignored.contains(version)) return;
    try {
      final saved = await preferences.setStringList(_ignoredVersionsKey, [
        ...ignored,
        version,
      ]);
      if (!saved) throw StateError('Could not save ignored update version');
    } catch (_) {
      await preferences.reload();
      rethrow;
    }
  }

  static Future<String> _packageVersion() async {
    // macOS native version fields are numeric; keep the full prerelease identity.
    const builtVersion = String.fromEnvironment('HUARUNWIN_VERSION');
    return builtVersion.isNotEmpty
        ? builtVersion
        : (await PackageInfo.fromPlatform()).version;
  }

  Future<String> currentVersion() => _version ??= _loadVersion();

  Future<String> _loadVersion() async {
    try {
      final version = await _readVersion();
      if (!AppUpdateFeed.isVersion(version)) {
        throw const FormatException('Invalid installed version');
      }
      return version;
    } catch (_) {
      _version = null;
      rethrow;
    }
  }

  Future<AppUpdateResult> check() async {
    if (_pending case final pending?) return pending;
    final request = _check();
    _pending = request;
    try {
      return await request;
    } finally {
      _pending = null;
    }
  }

  Future<AppUpdateResult> _check() async {
    final version = await currentVersion();
    return AppUpdateResult(currentVersion: version, feed: await loadFeed());
  }

  Future<AppUpdateFeed> loadFeed() async {
    final response = await _client.get<String>(metadataUrl);
    final body = response.data;
    if (body == null || body.length > 1024 * 1024) {
      throw const FormatException('Invalid update metadata size');
    }
    return AppUpdateFeed.decode(body, channel: channel);
  }
}
