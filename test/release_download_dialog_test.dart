import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_platform.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/github_releases.dart';
import 'package:huarunwin/services/mac_downloads.dart';
import 'package:huarunwin/ui/adaptive_dialog.dart';
import 'package:huarunwin/ui/release_download_dialog.dart';
import 'package:huarunwin/ui/theme.dart';

GitHubRelease release(String tag, {bool pre = false, bool latest = false}) =>
    GitHubRelease(
      page: Uri.parse('https://github.com/owner/repo/releases/tag/$tag'),
      tag: tag,
      name: tag,
      prerelease: pre,
      latest: latest,
    );

DownloadLink resource(
  String tag,
  String name, {
  String platform = 'macOS',
  String kind = 'dmg',
  String? arch = 'arm64',
}) => DownloadLink(
  url: 'https://github.com/owner/repo/releases/download/$tag/$name',
  label: name,
  platform: kind == 'resource' ? null : platform,
  kind: kind,
  architecture: arch,
  version: tag,
);

class FixtureReleases extends GitHubReleaseResolver {
  FixtureReleases() : super(MacDownloadResolver());
  List<GitHubRelease> versions = [
    release('v3-beta', pre: true),
    release('v2', latest: true),
    release('v1'),
  ];
  final resources = <String, List<DownloadLink>>{
    'v3-beta': [resource('v3-beta', 'beta-arm64.dmg')],
    'v2': [
      resource('v2', 'intel.dmg', arch: 'x64'),
      resource('v2', 'native.dmg'),
      resource('v2', 'checksums.json', kind: 'resource'),
    ],
    'v1': [resource('v1', 'old.dmg')],
    'v0': [resource('v0', 'ancient.dmg')],
  };
  final requested = <String>[];
  final pending = <String, Completer<List<DownloadLink>>>{};
  final failures = <String>{};
  bool failList = false, failMore = false;
  GitHubRelease? latest;
  int pages = 0;
  @override
  Future<GitHubRelease?> loadLatest(Uri repository) async => latest;
  @override
  Future<GitHubReleasePage> loadPage(Uri page) async {
    pages++;
    if (failList || page.hasQuery && failMore) throw StateError('offline');
    return page.hasQuery
        ? GitHubReleasePage([release('v1'), release('v0')])
        : GitHubReleasePage(
            versions,
            next: Uri.parse('https://github.com/owner/repo/releases?after=v1'),
          );
  }

  @override
  Future<List<DownloadLink>> loadResources(GitHubRelease release) async {
    requested.add(release.tag);
    if (failures.contains(release.tag)) throw StateError('offline');
    return pending[release.tag]?.future ?? resources[release.tag] ?? [];
  }
}

void main() {
  late FixtureReleases resolver;
  final selections = <ReleaseDownloadSelection?>[];
  setUp(() {
    resolver = FixtureReleases();
    selections.clear();
  });
  tearDown(() {
    resolver.source.client.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
  });

  Future<void> showPicker(
    WidgetTester tester, {
    Brightness brightness = Brightness.light,
    double scale = 1,
    ReleaseDownloadPreferences preferences = const ReleaseDownloadPreferences(
      platform: 'macOS',
      running: 'macOS',
      architecture: 'arm64',
    ),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => selections.add(
                await showAdaptiveForm<ReleaseDownloadSelection>(
                  context: context,
                  builder: (context) => ReleaseDownloadDialog(
                    appName: 'Example',
                    source: Uri.parse('https://github.com/owner/repo'),
                    resolver: resolver,
                    preferences: preferences,
                  ),
                ),
              ),
              child: const Text('下载'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pickVersion(
    WidgetTester tester,
    String tag, {
    bool cancel = false,
  }) async {
    await tester.tap(find.byKey(const ValueKey('release-version')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(ListTile, tag));
    await tester.pump();
    await tester.tap(find.text(cancel ? '取消' : '确认').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  const androidPreferences = ReleaseDownloadPreferences(
    platform: 'Android',
    running: 'Android',
    architecture: 'arm64',
  );
  void androidResources() {
    resolver.resources['v2'] = [
      resource('v2', 'app.apk', platform: 'Android', kind: 'apk'),
      resource('v2', 'checksums.json', kind: 'resource'),
    ];
  }

  Future<void> revealResign(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('resign-apk')),
      120,
      scrollable: find
          .descendant(
            of: find.byType(ReleaseDownloadDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  void signingKeys(List<MethodCall> calls, {bool existing = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          const key = {
            'id': 'key',
            'label': '本机密钥 Fixture',
            'certificateSha256': 'aabbcc',
          };
          return switch (call.method) {
            'apkSigningKeys' => existing ? [key] : [],
            'createApkSigningKey' => {...key, 'exportable': true},
            'resolveApkSigningKey' => {
              ...key,
              'exportable': !existing,
              'created': !existing,
            },
            _ => throw StateError('Unexpected operation: ${call.method}'),
          };
        });
  }

  testWidgets(
    'Android APK resign is off by default; enabling and cancelling creates no key',
    (tester) async {
      androidResources();
      final calls = <MethodCall>[];
      signingKeys(calls);
      await showPicker(tester, preferences: androidPreferences);
      await revealResign(tester);
      expect(calls, isEmpty);
      expect(find.textContaining('后续更新需使用同一密钥'), findsNothing);
      expect(find.textContaining('管理密钥'), findsNothing);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const ValueKey('resign-apk')))
            .value,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('resign-apk')));
      await tester.pumpAndSettle();
      expect(find.text('选择重签密钥'), findsNothing);
      expect(find.text('管理密钥'), findsOneWidget);
      expect(calls.map((c) => c.method), ['apkSigningKeys']);
      expect(find.text('下载并重签'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selections, [null]);
      expect(calls.map((c) => c.method), ['apkSigningKeys']);
    },
  );

  for (final existing in [true, false]) {
    testWidgets(
      'key ${existing ? 'selection' : 'creation'} only attaches resign intent to confirmed download',
      (tester) async {
        androidResources();
        final calls = <MethodCall>[];
        signingKeys(calls, existing: existing);
        await showPicker(tester, preferences: androidPreferences);
        await revealResign(tester);
        await tester.tap(find.byKey(const ValueKey('resign-apk')));
        await tester.pumpAndSettle();
        expect(find.text('选择重签密钥'), findsNothing);
        expect(find.text('下载并重签'), findsOneWidget);
        expect(selections, isEmpty);
        expect(calls.map((c) => c.method), ['apkSigningKeys']);
        await tester.tap(find.text('下载并重签'));
        await tester.pumpAndSettle();
        if (!existing) {
          expect(find.text('备份签名密钥'), findsOneWidget);
          expect(selections, isEmpty);
          await tester.tap(find.text('稍后'));
          await tester.pumpAndSettle();
        }
        expect(calls.map((c) => c.method), [
          'apkSigningKeys',
          'resolveApkSigningKey',
        ]);
        expect(
          calls.last.arguments,
          existing
              ? {'keyId': 'key', 'expectedCertificateSha256': 'aabbcc'}
              : isEmpty,
        );
        expect(selections.single!.resignKey!.id, 'key');
        expect(selections.single!.resource!.kind, 'apk');
      },
    );
  }

  testWidgets('switching to an ordinary resource discards resign intent', (
    tester,
  ) async {
    androidResources();
    final calls = <MethodCall>[];
    signingKeys(calls, existing: true);
    await showPicker(tester, preferences: androidPreferences);
    await revealResign(tester);
    await tester.tap(find.byKey(const ValueKey('resign-apk')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('显示全部资源'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('显示全部资源'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('checksums.json'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('checksums.json'));
    await tester.pumpAndSettle();
    expect(find.text('下载并重签'), findsNothing);
    expect(find.byKey(const ValueKey('resign-apk')), findsNothing);
    await tester.tap(find.text('确认下载'));
    await tester.pumpAndSettle();
    expect(selections.single!.resignKey, isNull);
    expect(selections.single!.resource!.kind, 'resource');
  });

  for (final changeVersion in [false, true]) {
    testWidgets(
      '${changeVersion ? 'version' : 'another APK'} change clears the draft without creating a key',
      (tester) async {
        androidResources();
        final alternate = resource(
          'v2',
          'other.apk',
          platform: 'Android',
          kind: 'apk',
        );
        resolver.resources['v2']!.add(alternate);
        resolver.resources['v1'] = [
          resource('v1', 'old.apk', platform: 'Android', kind: 'apk'),
        ];
        final calls = <MethodCall>[];
        signingKeys(calls);
        await showPicker(tester, preferences: androidPreferences);
        await revealResign(tester);
        await tester.tap(find.byKey(const ValueKey('resign-apk')));
        await tester.pumpAndSettle();
        if (changeVersion) {
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('release-version')),
            -150,
            scrollable: find.byType(Scrollable).first,
          );
          await pickVersion(tester, 'v1');
        } else {
          await tester.ensureVisible(find.byKey(ValueKey(alternate.url)));
          await tester.tap(find.byKey(ValueKey(alternate.url)));
          await tester.pumpAndSettle();
        }
        expect(find.text('下载并重签'), findsNothing);
        await tester.tap(find.text('确认下载'));
        await tester.pumpAndSettle();
        expect(selections.single!.resignKey, isNull);
        expect(
          selections.single!.resource!.label,
          changeVersion ? 'old.apk' : 'other.apk',
        );
        expect(calls.map((call) => call.method), ['apkSigningKeys']);
      },
    );
  }

  testWidgets(
    'turning resign off collapses key management and keeps the existing key',
    (tester) async {
      androidResources();
      final calls = <MethodCall>[];
      signingKeys(calls, existing: true);
      await showPicker(tester, preferences: androidPreferences);
      await revealResign(tester);
      await tester.tap(find.byKey(const ValueKey('resign-apk')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('manage-signing-key')),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('仅本机 · 不可备份'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('manage-signing-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('下载并重签'), findsOneWidget);
      await revealResign(tester);
      await tester.tap(find.byKey(const ValueKey('resign-apk')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('manage-signing-key')), findsNothing);
      expect(find.textContaining('后续更新需使用同一密钥'), findsNothing);
      expect(find.text('确认下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('resign-apk')));
      await tester.pumpAndSettle();
      expect(find.textContaining('本机密钥 Fixture'), findsOneWidget);
      expect(calls.map((call) => call.method), [
        'apkSigningKeys',
        'apkSigningKeys',
        'apkSigningKeys',
      ]);
    },
  );

  testWidgets(
    'desktop selection of Android APK cannot enable local resigning',
    (tester) async {
      androidResources();
      await showPicker(
        tester,
        preferences: const ReleaseDownloadPreferences(
          platform: 'Android',
          running: 'macOS',
          architecture: 'arm64',
        ),
      );
      expect(find.byKey(const ValueKey('resign-apk')), findsNothing);
    },
  );

  testWidgets(
    'small Android phone with large text keeps resign and confirmation reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      androidResources();
      final calls = <MethodCall>[];
      signingKeys(calls, existing: true);
      await showPicker(tester, preferences: androidPreferences, scale: 1.8);
      await revealResign(tester);
      expect(
        find.byKey(const ValueKey('resign-apk')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('resign-apk')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('下载并重签').hitTestable(), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selections, [null]);
    },
  );

  testWidgets(
    'newest stable and matching native asset are pending until confirmation',
    (tester) async {
      await showPicker(tester);
      expect(resolver.requested, ['v2']);
      expect(find.text('v2 · 稳定版'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'native.dmg'))
            .selected,
        isTrue,
      );
      expect(find.textContaining('推荐'), findsOneWidget);
      expect(find.text('checksums.json'), findsNothing);
      expect(selections, isEmpty);
      await tester.tap(find.text('确认下载'));
      await tester.pumpAndSettle();
      expect(selections.single!.resource!.label, 'native.dmg');
    },
  );

  testWidgets(
    'version cancellation keeps assets; confirmed older version resets the selection',
    (tester) async {
      await showPicker(tester);
      await pickVersion(tester, 'v1', cancel: true);
      expect(resolver.requested, ['v2']);
      expect(find.text('native.dmg'), findsOneWidget);
      await pickVersion(tester, 'v1');
      expect(resolver.requested, ['v2', 'v1']);
      expect(find.text('native.dmg'), findsNothing);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'old.dmg'))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('确认下载'));
      await tester.pumpAndSettle();
      expect(selections.single!.resource!.version, 'v1');
      expect(selections.single!.resource!.label, 'old.dmg');
    },
  );

  testWidgets(
    'all resources allows an ordinary file without giving it installer metadata',
    (tester) async {
      await showPicker(tester);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();
      final resource = find.widgetWithText(ListTile, 'checksums.json');
      await tester.scrollUntilVisible(
        resource,
        100,
        scrollable: find
            .descendant(
              of: find.byType(ReleaseDownloadDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(resource);
      await tester.pump();
      expect(selections, isEmpty);
      await tester.tap(find.text('确认下载'));
      await tester.pumpAndSettle();
      expect(selections.single!.resource!.kind, 'resource');
      expect(selections.single!.resource!.isPackage, isFalse);
    },
  );

  testWidgets(
    'manual prerelease remains visibly marked and cancel starts nothing',
    (tester) async {
      await showPicker(tester);
      await pickVersion(tester, 'v3-beta');
      expect(find.text('v3-beta · 预发布'), findsOneWidget);
      expect(find.text('beta-arm64.dmg'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selections, [null]);
    },
  );

  testWidgets(
    'default version skips releases without a suitable platform asset',
    (tester) async {
      resolver.resources['v2'] = [
        resource('v2', 'windows.exe', platform: 'Windows', kind: 'exe'),
      ];
      await showPicker(tester);
      expect(resolver.requested, ['v2', 'v1']);
      expect(find.text('v1 · 稳定版'), findsOneWidget);
      expect(find.text('old.dmg'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'designated stable release takes priority over a page full of prereleases',
    (tester) async {
      resolver.versions = [release('v3-beta', pre: true)];
      resolver.latest = release('v2', latest: true);
      await showPicker(tester);
      expect(resolver.requested, ['v2']);
      expect(find.text('v2 · 稳定版'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'repository with only prereleases keeps its default visibly marked',
    (tester) async {
      resolver.versions = [release('v3-beta', pre: true)];
      await showPicker(tester);
      expect(find.text('v3-beta · 预发布'), findsOneWidget);
      expect(find.text('beta-arm64.dmg'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'asset load failure retries the same release without silently using an older version',
    (tester) async {
      resolver.failures.add('v2');
      await showPicker(tester);
      expect(resolver.requested, ['v2']);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认下载'))
            .onPressed,
        isNull,
      );
      resolver.failures.clear();
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(resolver.requested, ['v2', 'v2']);
      expect(find.text('native.dmg'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'unavailable history offers explicit website fallback and no download',
    (tester) async {
      resolver.failList = true;
      await showPicker(tester);
      expect(selections, isEmpty);
      expect(find.text('使用网站提供的下载入口'), findsOneWidget);
      await tester.tap(find.text('使用网站提供的下载入口'));
      await tester.pumpAndSettle();
      expect(selections.single!.websiteFallback, isTrue);
      expect(resolver.requested, isEmpty);
    },
  );

  testWidgets(
    'history pagination deduplicates versions, retries, and only fetches selected assets',
    (tester) async {
      await showPicker(tester);
      await tester.tap(find.byKey(const ValueKey('release-version')));
      await tester.pumpAndSettle();
      resolver.failMore = true;
      await tester.tap(find.text('载入更多版本'));
      await tester.pumpAndSettle();
      expect(
        find.text('无法读取 GitHub 版本或资源，请重试或使用网站提供的下载入口。 已载入版本仍可选择。'),
        findsOneWidget,
      );
      resolver.failMore = false;
      await tester.tap(find.text('重试载入更多版本'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'v1'), findsOneWidget);
      await tester.ensureVisible(find.widgetWithText(ListTile, 'v0'));
      await tester.tap(find.widgetWithText(ListTile, 'v0'));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(resolver.requested, ['v2', 'v0']);
      expect(find.text('ancient.dmg'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('late resource response cannot override a newly chosen version', (
    tester,
  ) async {
    final pending = resolver.pending['v1'] = Completer<List<DownloadLink>>();
    await showPicker(tester);
    await pickVersion(tester, 'v1');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认下载'))
          .onPressed,
      isNull,
    );
    await pickVersion(tester, 'v3-beta');
    pending.complete([resource('v1', 'late.dmg')]);
    await tester.pumpAndSettle();
    expect(find.text('v3-beta · 预发布'), findsOneWidget);
    expect(find.text('beta-arm64.dmg'), findsOneWidget);
    expect(find.text('late.dmg'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'cancel while loading never returns a resource or updates a disposed dialog',
    (tester) async {
      final pending = resolver.pending['v2'] = Completer<List<DownloadLink>>();
      await showPicker(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      pending.complete([resource('v2', 'late.dmg')]);
      await tester.pumpAndSettle();
      expect(selections, [null]);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'small phone with large text can change versions and confirm ($brightness)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await showPicker(tester, brightness: brightness, scale: 1.6);
        await pickVersion(tester, 'v1');
        await tester.scrollUntilVisible(
          find.widgetWithText(ListTile, 'old.dmg'),
          100,
          scrollable: find
              .descendant(
                of: find.byType(ReleaseDownloadDialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('old.dmg').hitTestable(), findsOneWidget);
        await tester.tap(find.text('old.dmg'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('确认下载'));
        await tester.pumpAndSettle();
        expect(selections.single!.resource!.label, 'old.dmg');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
