import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/repository.dart';
import 'services/app_controller.dart';
import 'services/download_locations.dart';
import 'services/downloads.dart';
import 'services/download_foreground.dart';
import 'services/github_acceleration.dart';
import 'ui/home.dart';
import 'ui/content_image.dart';
import 'ui/app_updates.dart';
import 'ui/app_library_navigation.dart';
import 'ui/android_incoming_apks.dart';
import 'ui/mac_window.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      '华润赢客户端',
    ], await rootBundle.loadString('LICENSE'));
  });
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(const [
        'Android apksig',
      ], await rootBundle.loadString('assets/licenses/apksig.txt'));
      yield LicenseEntryWithLineBreaks(const [
        'ARSCLib',
      ], await rootBundle.loadString('assets/licenses/arsclib.txt'));
      yield LicenseEntryWithLineBreaks(const [
        'Bouncy Castle (bcprov, bcpkix, bcutil)',
      ], await rootBundle.loadString('assets/licenses/bouncycastle.txt'));
    });
  }
  final support = await getApplicationSupportDirectory();
  final preferences = await SharedPreferences.getInstance();
  final github = GitHubAcceleration.instance..restore(preferences);
  final controller = AppController(
    CatalogRepository(
      Directory(p.join(support.path, 'content')),
      github: github,
    ),
    preferences,
  );
  final legacyDownloads = Directory(p.join(support.path, 'downloads'));
  DownloadLocations? downloadLocations;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    Directory? systemDownloads;
    try {
      systemDownloads = await getDownloadsDirectory();
    } catch (_) {
      // A desktop without a configured Downloads folder keeps the old default.
    }
    downloadLocations = await DownloadLocations.load(
      preferences: preferences,
      legacyDirectory: legacyDownloads,
      defaultDirectory: systemDownloads == null
          ? legacyDownloads
          : Directory(p.join(systemDownloads.path, 'huarunwin')),
    );
  }
  final downloads = DownloadManager(
    legacyDownloads,
    locations: downloadLocations,
    github: github,
    foreground: Platform.isAndroid ? AndroidDownloadForeground() : null,
  );
  await downloads.restore();
  runApp(
    HuarunApp(
      controller: controller,
      downloads: downloads,
      onReady: (context) =>
          checkAppUpdate(context, manager: downloads, silent: true),
    ),
  );
  controller.load();
  await showMacWindowAfterFirstFrame();
}

class HuarunApp extends StatefulWidget {
  const HuarunApp({
    super.key,
    required this.controller,
    required this.downloads,
    this.onReady,
  });
  final AppController controller;
  final DownloadManager downloads;
  final void Function(BuildContext context)? onReady;
  @override
  State<HuarunApp> createState() => _HuarunAppState();
}

class _HuarunAppState extends State<HuarunApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _libraryRequests = ValueNotifier(0);

  void _showDownloads() {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    _libraryRequests.value++;
  }

  @override
  void dispose() {
    widget.downloads.foreground?.onOpen = null;
    _libraryRequests.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.downloads.foreground?.onOpen = _showDownloads;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(widget.downloads.foreground?.consumeOpenRequest());
      final context = _navigatorKey.currentContext;
      if (mounted && context != null) widget.onReady?.call(context);
    });
  }

  @override
  Widget build(BuildContext context) => ContentSourceScope(
    sources: widget.controller.sources,
    github: widget.controller.repository.github,
    child: _buildApp(context),
  );

  Widget _buildApp(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) => MaterialApp(
        navigatorKey: _navigatorKey,
        title: '华润赢',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light, width: constraints.maxWidth),
        darkTheme: appTheme(Brightness.dark, width: constraints.maxWidth),
        scrollBehavior: const MaterialScrollBehavior().copyWith(
          physics: usesMobileDesignForWidth(constraints.maxWidth)
              ? const ClampingScrollPhysics()
              : null,
        ),
        themeMode: widget.controller.themeMode,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) {
          Widget page = NotificationListener<ScrollStartNotification>(
            onNotification: (notification) {
              if (usesMobileDesign(context) &&
                  notification.dragDetails != null &&
                  notification.context
                          ?.findAncestorWidgetOfExactType<EditableText>() ==
                      null) {
                final focus = FocusManager.instance.primaryFocus;
                // Dismiss an editor without taking focus away from route
                // shortcuts when the user is only scrolling the page.
                if (focus?.context
                        ?.findAncestorStateOfType<EditableTextState>() !=
                    null) {
                  focus?.unfocus(
                    disposition: UnfocusDisposition.previouslyFocusedChild,
                  );
                }
              }
              return false;
            },
            child: MacWindowInsets(child: child!),
          );
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
            page = AndroidIncomingApks(
              manager: widget.downloads,
              navigatorKey: _navigatorKey,
              child: page,
            );
          }
          final dark = Theme.of(context).brightness == Brightness.dark;
          return AppLibraryNavigation(
            onShowDownloads: _showDownloads,
            child: AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                systemNavigationBarColor: Colors.transparent,
                systemNavigationBarDividerColor: Colors.transparent,
                statusBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: dark ? Brightness.dark : Brightness.light,
                systemNavigationBarIconBrightness: dark
                    ? Brightness.light
                    : Brightness.dark,
                systemStatusBarContrastEnforced: false,
                systemNavigationBarContrastEnforced: false,
              ),
              child: page,
            ),
          );
        },
        home: HomePage(
          controller: widget.controller,
          downloads: widget.downloads,
          libraryRequests: _libraryRequests,
        ),
      ),
    ),
  );
}
