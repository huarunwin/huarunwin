import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart'
    as windows;

import 'components.dart';
import 'mac_window.dart';
import 'page_components.dart';
import 'theme.dart';

class WebPage extends StatefulWidget {
  const WebPage({
    super.key,
    required this.uri,
    required this.title,
    this.syncCorrectionTheme = false,
  });

  final Uri uri;
  final String title;
  final bool syncCorrectionTheme;

  @override
  State<WebPage> createState() => _WebPageState();
}

class _WebPageState extends State<WebPage> {
  final scroll = ScrollController();
  WebViewController? controller;
  windows.WebviewController? windowsController;
  final windowsSubscriptions = <StreamSubscription<dynamic>>[];
  bool missingWindowsRuntime = false;
  late Uri pageUri = widget.uri;
  bool loading = true;
  String? error;
  double webScrollY = 0;
  Completer<void>? reloadFinished;
  Brightness webBrightness = Brightness.light;
  Color webBackground = Colors.transparent;

  Uri get _initialUri => widget.syncCorrectionTheme
      ? widget.uri.replace(
          queryParameters: {
            ...widget.uri.queryParameters,
            'theme': webBrightness.name,
          },
        )
      : widget.uri;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    if (webBrightness == theme.brightness &&
        webBackground == theme.colorScheme.surface) {
      return;
    }
    webBrightness = theme.brightness;
    webBackground = theme.colorScheme.surface;
    _applyAppearance();
  }

  Future<void> _applyAppearance() async {
    final web = controller;
    final desktop = windowsController;
    if (web == null && desktop?.value.isInitialized != true) return;
    try {
      // Apply theme changes without navigating away from an unfinished form.
      final script =
          '''
        if (location.pathname === '/corrections/app' ||
            location.pathname === '/corrections/app/') {
          document.documentElement.classList.toggle(
            'dark', ${webBrightness == Brightness.dark});
        }
      ''';
      if (web != null) {
        await web.setBackgroundColor(webBackground);
        if (widget.syncCorrectionTheme) await web.runJavaScript(script);
      } else if (desktop != null) {
        await desktop.setBackgroundColor(webBackground);
        if (widget.syncCorrectionTheme) await desktop.executeScript(script);
      }
    } catch (_) {
      // Appearance updates must not replace a usable form with an error.
    }
  }

  @override
  void dispose() {
    _finishReload();
    unawaited(_disposeWindowsWebView());
    scroll.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    if (WebViewPlatform.instance == null) {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        await _initializeWindows();
        return;
      }
      _failed('当前平台暂不支持应用内网页。');
      return;
    }
    try {
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await web.addJavaScriptChannel(
          'HuarunPageScroll',
          onMessageReceived: (message) {
            final offset = double.tryParse(message.message);
            if (offset != null && offset.isFinite) _followScroll(offset);
          },
        );
      } else {
        await web.setOnScrollPositionChange(
          (position) => _followScroll(position.y),
        );
      }
      await web.setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              pageUri = Uri.parse(url);
              webScrollY = 0;
              loading = true;
              error = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => loading = false);
            _finishReload();
            _applyAppearance();
            if (defaultTargetPlatform == TargetPlatform.macOS) {
              _observeMacScroll(web);
            }
          },
          onWebResourceError: (failure) {
            if (failure.isForMainFrame == true) _failed();
          },
          onHttpError: (failure) {
            if (failure.request?.uri.removeFragment() ==
                pageUri.removeFragment()) {
              _failed();
            }
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && const ['https', 'http'].contains(uri.scheme)) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
        ),
      );
      await web.setBackgroundColor(webBackground);
      if (!mounted) return;
      setState(() {
        controller = web;
        pageUri = _initialUri;
      });
      await web.loadRequest(pageUri);
    } catch (_) {
      _failed();
    }
  }

  Future<void> _disposeWindowsWebView() async {
    final web = windowsController;
    windowsController = null;
    final subscriptions = List.of(windowsSubscriptions);
    windowsSubscriptions.clear();
    // Start native disposal immediately; a delayed stream cancellation must
    // not retain the browser after its route has gone away.
    await Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
      if (web != null) web.dispose(),
    ]);
  }

  Future<void> _initializeWindows() async {
    try {
      missingWindowsRuntime =
          await windows.WebviewController.getWebViewVersion() == null;
      if (!mounted) return;
      if (missingWindowsRuntime) {
        _failed('此电脑缺少 Microsoft Edge WebView2 运行时，请安装网页组件后重试。');
        return;
      }
      final web = windowsController = windows.WebviewController();
      await web.initialize();
      if (!mounted) return;
      await web.setPopupWindowPolicy(windows.WebviewPopupWindowPolicy.deny);
      await web.setDefaultContextMenusEnabled(true);
      await web.setBackgroundColor(webBackground);
      if (!mounted) return;
      windowsSubscriptions.addAll([
        web.url.listen((url) {
          final uri = Uri.tryParse(url);
          if (!mounted || uri == null) return;
          if (const ['https', 'http'].contains(uri.scheme)) {
            pageUri = uri;
          }
        }),
        web.loadingState.listen((state) {
          if (!mounted) return;
          if (state == windows.LoadingState.loading) {
            setState(() {
              loading = true;
              error = null;
              webScrollY = 0;
            });
          } else if (state == windows.LoadingState.navigationCompleted) {
            setState(() => loading = false);
            _finishReload();
            if (error == null) _applyAppearance();
          }
        }),
        web.onLoadError.listen((failure) {
          if (failure != windows.WebErrorStatus.operationCanceled) _failed();
        }),
        web.webMessage.listen((message) {
          if (message is Map && message['type'] == 'huarun-page-back') {
            _back();
            return;
          }
          if (message is Map && message['type'] == 'huarun-page-scroll') {
            final offset = message['y'];
            if (offset is num && offset.isFinite) {
              _followScroll(offset.toDouble());
            }
          }
        }),
      ]);
      await web.addScriptToExecuteOnDocumentCreated('''
        if (window === window.top) {
          window.addEventListener('scroll', () => {
            window.chrome.webview.postMessage({
              type: 'huarun-page-scroll', y: window.scrollY
            });
          }, {passive: true});
          // WebView2 owns native keyboard focus while editing the form.
          window.addEventListener('keydown', (event) => {
            if (event.key === 'Escape' && !event.defaultPrevented &&
                !event.isComposing &&
                !document.querySelector('dialog[open], [role="dialog"][aria-modal="true"]')) {
              window.chrome.webview.postMessage({type: 'huarun-page-back'});
            }
          });
        }
      ''');
      if (!mounted) return;
      setState(() {
        pageUri = _initialUri;
      });
      await web.loadUrl(pageUri.toString());
    } catch (failure) {
      await _disposeWindowsWebView();
      if (failure is PlatformException &&
          failure.code == 'unsupported_platform') {
        _failed('应用内${widget.title}需要 Windows 10 1809 或更新版本及可用的图形驱动。');
      } else if (failure is MissingPluginException) {
        _failed('Windows 网页组件尚未载入，请重新编译并启动客户端。');
      } else {
        _failed('Windows 网页组件未能启动，请检查 WebView2 运行时后重试。');
      }
    }
  }

  void _followScroll(double y) {
    if (!mounted) return;
    webScrollY = y;
    if (!scroll.hasClients) return;
    final scale = defaultTargetPlatform == TargetPlatform.android
        ? View.of(context).devicePixelRatio
        : 1.0;
    final offset = (y / scale)
        .clamp(0.0, scroll.position.maxScrollExtent)
        .toDouble();
    if ((scroll.offset - offset).abs() > .5) scroll.jumpTo(offset);
  }

  Future<void> _observeMacScroll(WebViewController web) async {
    // webview_flutter's native scroll callback is unavailable on macOS.
    try {
      await web.runJavaScript('''
        if (!window.__huarunPageScroll) {
          window.__huarunPageScroll = true;
          window.addEventListener('scroll', () => {
            HuarunPageScroll.postMessage(String(window.scrollY));
          }, {passive: true});
        }
      ''');
    } catch (_) {
      // A scroll observer failure must not hide a usable page.
    }
  }

  void _failed([String? message]) {
    if (!mounted) return;
    if (scroll.hasClients) scroll.jumpTo(0);
    setState(() {
      loading = false;
      error = message ?? '${widget.title}页面暂时无法加载，请检查网络后重试。';
      webScrollY = 0;
    });
    _finishReload();
  }

  void _finishReload() {
    reloadFinished?.complete();
    reloadFinished = null;
  }

  Future<void> _reload() async {
    if (reloadFinished != null) return reloadFinished!.future;
    if (loading) return;
    final finished = reloadFinished = Completer<void>();
    final failed = error != null;
    setState(() {
      loading = true;
      error = null;
    });
    if (scroll.hasClients) scroll.jumpTo(0);
    try {
      if (windowsController case final web?) {
        if (failed) {
          await web.loadUrl(pageUri.toString());
        } else {
          await web.reload();
        }
      } else if (controller == null) {
        await _initialize();
      } else if (failed) {
        await controller!.loadRequest(pageUri);
      } else {
        await controller!.reload();
      }
    } catch (_) {
      _failed();
    }
    await finished.future;
  }

  void _back() {
    if (ModalRoute.isCurrentOf(context) == true) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): _back,
      if (hasMacWindowControls)
        const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
            _back,
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        body: PageSafeArea(
          child: PageRefreshIndicator(
            onRefresh: _reload,
            child: CustomScrollView(
              controller: scroll,
              // Keep the first delta when the WebView yields a fast pull.
              dragStartBehavior: usesMobileDesign(context)
                  ? DragStartBehavior.down
                  : DragStartBehavior.start,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16 + PageSafeArea.topInsetOf(context),
                      16,
                      0,
                    ),
                    child: PageHeader(
                      title: widget.title,
                      showBackButton: true,
                      actions: [
                        RefreshIconButton(
                          loading: loading,
                          onPressed: _reload,
                          tooltip: '刷新${widget.title}页面',
                        ),
                      ],
                    ),
                  ),
                ),
                SliverFillRemaining(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (controller != null)
                        WebViewWidget(
                          controller: controller!,
                          gestureRecognizers: {
                            if (usesMobileDesign(context))
                              Factory<_WebViewRefreshGestureRecognizer>(
                                () => _WebViewRefreshGestureRecognizer(
                                  canRefresh: () =>
                                      !loading &&
                                      webScrollY <= 0 &&
                                      (!scroll.hasClients ||
                                          scroll.offset <= 0),
                                ),
                              )
                            else
                              Factory<EagerGestureRecognizer>(
                                EagerGestureRecognizer.new,
                              ),
                          },
                        ),
                      if (windowsController case final web?
                          when web.value.isInitialized)
                        windows.Webview(web),
                      if (error != null)
                        ColoredBox(
                          color: Theme.of(context).colorScheme.surface,
                          child: EmptyState(
                            icon: Icons.cloud_off_rounded,
                            title: '无法打开${widget.title}页面',
                            message: error!,
                            action: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton(
                                  onPressed: _reload,
                                  child: const Text('重试'),
                                ),
                                if (missingWindowsRuntime)
                                  OutlinedButton(
                                    onPressed: () => openLink(
                                      context,
                                      'https://developer.microsoft.com/microsoft-edge/webview2/',
                                    ),
                                    child: const Text('安装网页组件'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Give a downward drag at the top to Flutter; keep other gestures in the form.
class _WebViewRefreshGestureRecognizer extends PrimaryPointerGestureRecognizer {
  _WebViewRefreshGestureRecognizer({required this.canRefresh})
    : super(
        deadline: kLongPressTimeout,
        preAcceptSlopTolerance: null,
        postAcceptSlopTolerance: null,
      );

  final bool Function() canRefresh;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    if (event.pointer != primaryPointer || !canRefresh()) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    if (event is PointerMoveEvent) {
      final delta = event.position - initialPosition!.global;
      final slop = gestureSettings?.touchSlop ?? kTouchSlop;
      if (delta.dy < -slop / 2 || delta.dx.abs() > slop) {
        resolve(GestureDisposition.accepted);
      } else if (delta.dy > slop) {
        resolve(GestureDisposition.rejected);
      }
    } else if (event is PointerUpEvent) {
      resolve(GestureDisposition.accepted);
    } else if (event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
    }
  }

  @override
  void didExceedDeadline() => resolve(GestureDisposition.accepted);

  @override
  String get debugDescription => 'WebView scrolling and pull to refresh';
}
