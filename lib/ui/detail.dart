import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../services/app_controller.dart';
import '../services/app_library.dart';
import '../services/downloads.dart';
import '../services/mac_downloads.dart';
import 'components.dart';
import 'detail_components.dart';
import 'app_library_page.dart';
import 'app_library_navigation.dart';
import 'app_download_button.dart';
import 'mac_window.dart';
import 'page_components.dart';
import 'share_link_button.dart';
import 'site_page.dart';
import 'theme.dart';

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.app,
    required this.controller,
    required this.downloads,
    this.selectedPlatform = '全部',
  });
  final CatalogApp app;
  final AppController controller;
  final DownloadManager downloads;
  final String selectedPlatform;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late Future<DetailSnapshot> request;
  DetailSnapshot? lastSnapshot;
  bool loading = true;
  int _generation = 0;
  late int _sourceRevision;
  @override
  void initState() {
    super.initState();
    _sourceRevision = widget.controller.sources.revision;
    widget.controller.sources.addListener(_sourceChanged);
    request = _load();
  }

  void _sourceChanged() {
    if (!mounted || _sourceRevision == widget.controller.sources.revision) {
      return;
    }
    setState(() {
      _sourceRevision = widget.controller.sources.revision;
      lastSnapshot = null;
      loading = true;
      request = _load(refresh: true);
    });
  }

  @override
  void dispose() {
    _generation++;
    widget.controller.sources.removeListener(_sourceChanged);
    super.dispose();
  }

  Future<DetailSnapshot> _load({bool refresh = false}) async {
    final generation = ++_generation;
    try {
      final result = await widget.controller.repository.detail(
        widget.app,
        refresh: refresh,
      );
      if (mounted && generation == _generation) lastSnapshot = result;
      return result;
    } finally {
      if (mounted && generation == _generation) setState(() => loading = false);
    }
  }

  Future<void> refresh() async {
    if (!loading) {
      setState(() {
        loading = true;
        request = _load(refresh: true);
      });
    }
    try {
      await request;
    } catch (_) {
      // FutureBuilder displays the error and keeps the retry action available.
    }
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
    child: Focus(autofocus: true, child: _buildPage(context)),
  );

  Widget _buildPage(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _buildDetailPage(
      context,
      compact: constraints.maxWidth < compactLayoutBreakpoint,
    ),
  );

  Widget _buildDetailPage(
    BuildContext context, {
    required bool compact,
  }) => Scaffold(
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    body: FutureBuilder<DetailSnapshot>(
      key: ValueKey(_sourceRevision),
      future: request,
      builder: (context, state) {
        if (state.connectionState != ConnectionState.done &&
            !state.hasData &&
            lastSnapshot == null) {
          return _scrollPage([
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
          ]);
        }
        if (state.hasError && lastSnapshot == null) {
          return _scrollPage([
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.cloud_off_rounded,
                title: '详情暂时不可用',
                message: '你仍可以前往网站查看完整介绍和官方入口。',
                action: Wrap(
                  spacing: 12,
                  children: [
                    FilledButton(onPressed: refresh, child: const Text('重试')),
                    OutlinedButton(
                      onPressed: () => openLink(context, widget.app.url),
                      child: const Text('打开网页'),
                    ),
                  ],
                ),
              ),
            ),
          ]);
        }
        final snapshot = state.data ?? lastSnapshot!;
        final detail = snapshot.details;
        final colors = Theme.of(context).colorScheme;
        final hasReleaseInfo =
            detail.version?.trim().isNotEmpty == true ||
            detail.updatedAt?.trim().isNotEmpty == true;
        final description = detail.description.isNotEmpty
            ? detail.description
            : compact
            ? detail.app.description
            : '';
        final sections = <Widget>[
          if (detail.changelog.isNotEmpty || compact && hasReleaseInfo)
            DetailSection(
              title: detail.changelog.isNotEmpty ? '新功能' : '版本信息',
              trailing: detail.releaseUrl == null
                  ? null
                  : compact
                  ? IconButton(
                      tooltip: '版本记录',
                      onPressed: () => openLink(context, detail.releaseUrl!),
                      icon: const Icon(Icons.chevron_right_rounded),
                    )
                  : TextButton(
                      onPressed: () => openLink(context, detail.releaseUrl!),
                      child: const Text('版本记录'),
                    ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (compact && hasReleaseInfo)
                    AppDetailReleaseInfo(detail: detail),
                  if (detail.changelog.isNotEmpty) ...[
                    if (compact && hasReleaseInfo) const SizedBox(height: 16),
                    DetailText(detail.changelog, maxLines: 4),
                  ],
                ],
              ),
            ),
          if (detail.screenshots.isNotEmpty)
            AppScreenshotGallery(urls: detail.screenshots),
          if (description.isNotEmpty)
            DetailSection(
              title: '应用介绍',
              child: DetailText(description, maxLines: 7),
            ),
          if (detail.notices.isNotEmpty)
            DetailSection(
              title: '使用提示',
              child: DetailText(detail.notices.join('\n\n')),
            ),
          if (detail.facts.isNotEmpty)
            DetailSection(
              title: '详细信息',
              child: Column(
                children: [
                  for (final entry in detail.facts.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 100,
                            child: Text(
                              entry.key,
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(child: SelectableText(entry.value)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          DetailSection(title: '官方渠道', child: _channels(detail)),
        ];
        return _scrollPage([
          SliverList.list(
            children: [
              if (state.hasError)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '刷新失败，保留当前内容。请稍后重试。',
                    style: TextStyle(color: colors.error),
                  ),
                ),
              AppDetailHero(
                app: detail.app,
                compact: compact,
                action: _primaryAction(detail, compact: compact),
              ),
              SizedBox(height: compact ? 20 : 26),
              AppDetailMetadata(detail: detail, compact: compact),
              SizedBox(height: compact ? 12 : 24),
              for (var index = 0; index < sections.length; index++) ...[
                if (index > 0) _divider(),
                sections[index],
              ],
              _divider(),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SitePage(
                        url: detail.app.url,
                        controller: widget.controller,
                        downloads: widget.downloads,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('完整指南、来源与关联阅读'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${snapshot.cached ? '缓存内容 · ' : ''}来自 huarun.win · ${snapshot.fetchedAt.toLocal().toString().substring(0, 16)}',
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ]);
      },
    ),
  );

  Widget _scrollPage(List<Widget> slivers) => PageSafeArea(
    child: LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: PageRefreshIndicator(
            onRefresh: refresh,
            child: CustomScrollView(
              key: const ValueKey('detail-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8 + PageSafeArea.topInsetOf(context),
                    12,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: PageHeader(
                      title: '',
                      showBackButton: true,
                      actions: [
                        RefreshIconButton(
                          tooltip: '刷新详情',
                          loading: loading,
                          onPressed: refresh,
                        ),
                        ShareLinkButton(
                          url: widget.app.url,
                          title: widget.app.name,
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    constraints.maxWidth < 600 ? 16 : 40,
                    0,
                    constraints.maxWidth < 600 ? 16 : 40,
                    40,
                  ),
                  sliver: SliverMainAxisGroup(slivers: slivers),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  bool _isMacApp(AppDetails detail) =>
      detail.app.isClient &&
      Platform.isMacOS &&
      detail.app.platforms.contains('macOS');

  bool _hasStore(AppDetails detail) => [
    ...detail.downloads.map((link) => link.url),
    ...detail.officialActions.map((link) => link.url),
    detail.releaseUrl,
    detail.officialUrl,
  ].whereType<String>().any(isAppStoreUrl);

  Widget _primaryAction(AppDetails detail, {required bool compact}) {
    final colors = Theme.of(context).colorScheme;
    final style = compact && !detail.app.withdrawn
        ? FilledButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.onPrimary,
            disabledBackgroundColor: colors.primary,
            disabledForegroundColor: colors.onPrimary,
            overlayColor: colors.onPrimary,
            textStyle: const TextStyle(
              fontSize: 16,
              height: 20 / 16,
              fontWeight: FontWeight.w600,
            ),
          ).merge(downloadButtonStyle(context))
        : downloadButtonStyle(context);
    if (detail.app.withdrawn) {
      return FilledButton(
        onPressed: null,
        style: style,
        child: const Text('已下架'),
      );
    }
    if (!detail.app.isClient) {
      final action = detail.officialActions.firstOrNull;
      return FilledButton.icon(
        onPressed: () => openLink(context, action?.url ?? detail.app.url),
        style: compact ? style : null,
        icon: const Icon(Icons.north_east_rounded, size: 17),
        label: Text(action?.label ?? '查看获取方式'),
      );
    }
    return AppDownloadButton(
      app: detail.app,
      selectedPlatform: widget.selectedPlatform,
      primary: true,
      style: style,
      details: detail,
      loadDetails: () async => detail,
      manager: widget.downloads,
      onStarted: _showDownloads,
    );
  }

  Widget _divider() => const DetailSectionDivider();

  Map<String, String> _officialLinks(AppDetails detail) => {
    for (final link in detail.officialActions) link.url: link.label,
    if (detail.releaseUrl != null)
      detail.releaseUrl!: isAppStoreUrl(detail.releaseUrl!)
          ? 'App Store'
          : '官方发布页',
    if (detail.officialUrl != null) detail.officialUrl!: '官方网站',
    for (final link in detail.downloads.where((link) => !link.isPackage))
      link.url: isAppStoreUrl(link.url) ? 'App Store' : '官方获取入口',
  };

  Widget _channels(AppDetails detail) {
    if (detail.app.withdrawn) {
      return const Text('该应用已下架，保留页面供查阅历史资料。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          !detail.app.isClient
              ? '按官方说明获取、部署或导入。'
              : _hasStore(detail)
              ? 'App Store 版本由系统商店完成下载与更新。'
              : '通过官方渠道获取应用。Mac 下载任务可查看进度、取消、删除，并在完成后安装。',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            for (final link in _officialLinks(detail).entries)
              TextButton.icon(
                onPressed: () => openLink(context, link.key),
                icon: const Icon(Icons.north_east_rounded, size: 16),
                label: Text(link.value),
              ),
            if (detail.downloads.isNotEmpty)
              TextButton.icon(
                onPressed: () => _showDownloadChoices(detail),
                icon: const Icon(Icons.devices_rounded, size: 17),
                label: const Text('全部下载入口'),
              ),
            if (_isMacApp(detail))
              TextButton.icon(
                onPressed: _showDownloads,
                icon: const Icon(Icons.apps_rounded, size: 17),
                label: const Text('应用库'),
              ),
          ],
        ),
      ],
    );
  }

  void _showDownloadChoices(AppDetails detail) {
    if (detail.app.withdrawn) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: surfaceShape(28),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '获取 ${detail.app.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              for (final link in detail.downloads.where(
                (link) => link.isPackage,
              ))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(platformIcon(link.platform ?? '')),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              [
                                link.platform,
                                link.kind?.toUpperCase(),
                                link.architecture,
                              ].whereType<String>().join(' · '),
                            ),
                            Text(
                              Uri.parse(link.url).host,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _download(link, detail.app);
                        },
                        style: downloadButtonStyle(sheetContext),
                        child: Text(
                          Platform.isAndroid || Platform.isIOS ? '浏览器下载' : '下载',
                        ),
                      ),
                    ],
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  for (final link in _officialLinks(detail).entries)
                    OutlinedButton.icon(
                      onPressed: () => openLink(context, link.key),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text(link.value),
                    ),
                  if (detail.downloads.isEmpty &&
                      _officialLinks(detail).isEmpty)
                    TextButton(
                      onPressed: () => openLink(context, detail.app.url),
                      child: const Text('在网站查看获取方式'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDownloads() {
    if (AppLibraryNavigation.showDownloads(context)) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: PageSafeArea(
            child: AppLibraryPage(
              controller: widget.controller,
              manager: widget.downloads,
              showBackButton: true,
              initialSection: LibrarySection.downloads,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _download(DownloadLink link, CatalogApp app) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await openLink(context, link.url);
      return;
    }
    try {
      await widget.downloads.download(app, link);
      if (mounted) _showDownloads();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法开始下载，请使用官方页面的下载入口。')));
      }
    }
  }
}
