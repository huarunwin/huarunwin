import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/app_changelog.dart';
import 'package:huarunwin/services/app_updates.dart';
import 'package:shared_preferences/shared_preferences.dart';

String changelog({
  String published = '0.1.0',
  List<Map<String, Object>>? releases,
}) => jsonEncode({
  'publishedVersion': published,
  'releases':
      releases ??
      [
        {
          'version': '0.2.0',
          'changes': ['Future changes'],
        },
        {
          'version': '0.1.0',
          'changes': ['Initial release'],
        },
      ],
});

AppUpdateFeed feed({
  String published = '0.1.0',
  List<Map<String, Object>>? releases,
}) {
  final data = jsonDecode(changelog(published: published, releases: releases));
  for (final entry in data['releases'] as List) {
    entry['downloadUrl'] =
        'https://downloads.example.com/huarunwin/${entry['version']}';
  }
  return AppUpdateFeed.decode(
    jsonEncode({'release': data}),
    channel: AppUpdateChannel.release,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('future notes never select the available update', () {
    final data = feed();
    final current = AppUpdateResult(currentVersion: '0.1.0', feed: data);
    expect(current.update, isNull);
    final older = AppUpdateResult(currentVersion: '0.0.9', feed: data);
    expect(older.update?.version, '0.1.0');
    expect(older.update?.changes, ['Initial release']);
    expect(
      older.releaseUrl.toString(),
      'https://downloads.example.com/huarunwin/0.1.0',
    );
  });

  test('only changing publishedVersion promotes the prepared notes', () {
    final data = feed(published: '0.2.0');
    expect(
      AppUpdateResult(currentVersion: '0.1.0', feed: data).update?.version,
      '0.2.0',
    );
    expect(AppUpdateResult(currentVersion: '0.3.0', feed: data).update, isNull);
  });

  test('numeric version order and prerelease precedence are preserved', () {
    final data = feed(
      published: '0.10.0',
      releases: [
        {
          'version': '0.10.0',
          'changes': ['Release'],
        },
      ],
    );
    for (final installed in ['0.9.0', '0.10.0-rc.10']) {
      expect(
        AppUpdateResult(currentVersion: installed, feed: data).update,
        isNotNull,
      );
    }
  });

  test('missing published notes, duplicates and empty changes are invalid', () {
    final invalid = [
      changelog(published: '9.9.9'),
      changelog(
        releases: [
          {
            'version': '0.1.0',
            'changes': ['First'],
          },
          {
            'version': '0.1.0',
            'changes': ['Duplicate'],
          },
        ],
      ),
      changelog(
        releases: [
          {'version': '0.1.0', 'changes': <String>[]},
        ],
      ),
      changelog(
        releases: [
          {
            'version': '0.1.0',
            'changes': ['   '],
          },
        ],
      ),
    ];
    for (final source in invalid) {
      expect(() => AppChangelog.decode(source), throwsFormatException);
    }
  });

  test(
    'version identities require three numeric parts and valid prereleases',
    () {
      for (final version in ['0.1.0', '1.10.0', '2.0.0-beta.10']) {
        expect(AppChangelog.isVersion(version), isTrue);
      }
      for (final version in [
        'v0.1.0',
        '0.1',
        '01.0.0',
        '1.0.0-01',
        '1.0.0+42',
        '1.0.0\n',
      ]) {
        expect(AppChangelog.isVersion(version), isFalse);
      }
    },
  );

  Map<String, Object?> channelData({
    String? published = '0.1.0',
    String url = 'https://downloads.example.com/0.1.0',
  }) => {
    'publishedVersion': published,
    'releases': [
      {
        'version': '0.1.0',
        'changes': ['Initial release'],
        'downloadUrl': url,
      },
    ],
  };

  test('unpublished channels do not promote prepared versions', () {
    final data = AppUpdateFeed.decode(
      jsonEncode({'release': channelData(published: null)}),
      channel: AppUpdateChannel.release,
    );
    final result = AppUpdateResult(currentVersion: '0.0.9', feed: data);
    expect(result.update, isNull);
    expect(result.releaseUrl, isNull);
  });

  test('a missing selected channel never falls back to release', () {
    expect(
      () => AppUpdateFeed.decode(
        jsonEncode({'release': channelData()}),
        channel: AppUpdateChannel.debug,
      ),
      throwsFormatException,
    );
  });

  test('remote download links must be explicit absolute HTTPS URLs', () {
    for (final url in [
      '',
      '/download',
      'http://example.com/file',
      'file:///tmp/app',
      'https://user:password@example.com/file',
    ]) {
      expect(
        () => AppUpdateFeed.decode(
          jsonEncode({'release': channelData(url: url)}),
          channel: AppUpdateChannel.release,
        ),
        throwsFormatException,
      );
    }
    final missing = channelData();
    (missing['releases'] as List).single.remove('downloadUrl');
    expect(
      () => AppUpdateFeed.decode(
        jsonEncode({'release': missing}),
        channel: AppUpdateChannel.release,
      ),
      throwsFormatException,
    );
  });

  test(
    'checks the hub and uses only the selected channel download link',
    () async {
      final client = Dio();
      addTearDown(client.close);
      Uri? requested;
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested = options.uri;
            handler.resolve(
              Response(
                requestOptions: options,
                data: jsonEncode({
                  'release': channelData(url: 'https://example.com/formal'),
                  'debug': channelData(url: 'https://example.com/testing'),
                }),
              ),
            );
          },
        ),
      );
      final updates = AppUpdates(
        client: client,
        readVersion: () async => '0.0.9',
        channel: AppUpdateChannel.debug,
      );
      final result = await updates.check();
      expect(requested.toString(), AppUpdates.metadataUrl);
      expect(requested?.path, '/huarunwin/huarunwin-hub/main/api/updates.json');
      expect(result.releaseUrl.toString(), 'https://example.com/testing');
      expect(result.update?.version, '0.1.0');
    },
  );

  test('ignored versions persist and manual checks still show them', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final updates = AppUpdates(
      channel: AppUpdateChannel.release,
      preferences: preferences,
    );
    final result = AppUpdateResult(currentVersion: '0.0.9', feed: feed());
    expect(await updates.shouldNotify(result), isTrue);
    await updates.ignoreVersion('0.1.0');
    await preferences.reload();
    final restored = AppUpdates(channel: AppUpdateChannel.release);
    expect(await restored.shouldNotify(result), isFalse);
    expect(await restored.shouldNotify(result, manual: true), isTrue);
  });

  test(
    'ignoring a version leaves later versions and other channels enabled',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final release = AppUpdates(
        channel: AppUpdateChannel.release,
        preferences: preferences,
      );
      final debug = AppUpdates(
        channel: AppUpdateChannel.debug,
        preferences: preferences,
      );
      final first = AppUpdateResult(currentVersion: '0.0.9', feed: feed());
      final next = AppUpdateResult(
        currentVersion: '0.0.9',
        feed: feed(published: '0.2.0'),
      );
      await release.ignoreVersion('0.1.0');
      expect(await release.shouldNotify(first), isFalse);
      expect(await release.shouldNotify(next), isTrue);
      expect(await debug.shouldNotify(first), isTrue);
      await release.ignoreVersion('0.2.0');
      expect(await release.shouldNotify(next), isFalse);
      expect(await release.shouldNotify(first), isFalse);
      expect(await debug.shouldNotify(next), isTrue);
    },
  );
}
