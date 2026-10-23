import 'package:flutter/material.dart';

import '../data/app_changelog.dart';
import '../services/app_updates.dart';
import '../services/downloads.dart';
import '../services/installed_apps.dart';
import 'app_update_dialog.dart';
import 'app_update_installation.dart';
import 'page_components.dart';

bool _showingUpdate = false;

Future<void> checkAppUpdate(
  BuildContext context, {
  required DownloadManager manager,
  bool silent = false,
}) async {
  try {
    final updates = AppUpdates.instance;
    final result = await updates.check(refresh: !silent);
    if (!context.mounted) return;
    final update = result.update;
    if (update == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.feed.publishedVersion == null
                  ? '当前渠道尚未发布版本'
                  : '当前已是最新版本（${result.currentVersion}）',
            ),
          ),
        );
      }
      return;
    }
    if (!await updates.shouldNotify(result, manual: !silent) ||
        !context.mounted ||
        _showingUpdate) {
      return;
    }
    _showingUpdate = true;
    try {
      final action = await showAppUpdateDialog(
        context: context,
        release: update,
        channel: updates.channel,
      );
      if (action == AppUpdateAction.ignore) {
        try {
          await updates.ignoreVersion(update.version);
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('暂时无法保存忽略记录，请稍后重试。')));
          }
        }
      } else if (action == AppUpdateAction.download && context.mounted) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => AppUpdateDownloadPage(
              release: update,
              channel: updates.channel,
              manager: manager,
            ),
          ),
        );
      }
    } finally {
      _showingUpdate = false;
    }
  } catch (_) {
    if (!silent && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法检查更新，请检查网络后重试。')));
    }
  }
}

class AppVersionRows extends StatefulWidget {
  const AppVersionRows({super.key, required this.manager});
  final DownloadManager manager;

  @override
  State<AppVersionRows> createState() => _AppVersionRowsState();
}

class _AppVersionRowsState extends State<AppVersionRows> {
  late final _version = AppUpdates.instance.currentVersion();
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await checkAppUpdate(context, manager: widget.manager);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FutureBuilder<String>(
        future: _version,
        builder: (context, snapshot) => PageRow(
          title: '华润赢',
          subtitle: snapshot.hasData
              ? '版本 ${snapshot.data}'
              : snapshot.hasError
              ? '暂时无法读取版本'
              : '正在读取版本…',
          leading: Image.asset(
            'assets/brand/huarun-icon.png',
            width: 32,
            height: 32,
            excludeFromSemantics: true,
          ),
        ),
      ),
      _divider(context),
      PageRow(
        title: '检查更新',
        icon: Icons.system_update_alt_rounded,
        trailing: _checking
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: _checking ? null : _check,
      ),
      _divider(context),
      PageRow(
        title: '更新日志',
        icon: Icons.history_rounded,
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const _ChangelogPage()),
        ),
      ),
    ],
  );

  Widget _divider(BuildContext context) => Divider(
    height: 1,
    thickness: 1 / MediaQuery.devicePixelRatioOf(context),
    indent: 60,
    endIndent: 16,
  );
}

class _ChangelogPage extends StatefulWidget {
  const _ChangelogPage();

  @override
  State<_ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<_ChangelogPage> {
  late Future<AppUpdateFeed> _changelog = AppUpdates.instance.loadFeed();

  Future<void> _refresh() async {
    final request = AppUpdates.instance.loadFeed(refresh: true);
    setState(() => _changelog = request);
    try {
      await request;
    } catch (_) {
      // The page displays the failure and offers another retry.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: FutureBuilder<AppUpdateFeed>(
        future: _changelog,
        builder: (context, snapshot) => ContentPage(
          title: '更新日志',
          showBackButton: true,
          onRefresh: _refresh,
          children: [
            if (snapshot.hasData && snapshot.data!.releases.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('当前渠道暂无更新日志。'),
              )
            else if (snapshot.hasData)
              for (final release in snapshot.data!.releases)
                PageSection(
                  title:
                      snapshot.data!.publishedVersion == null ||
                          hasNewerVersion(
                            snapshot.data!.publishedVersion!,
                            release.version,
                          )
                      ? '${release.version} · 尚未发布'
                      : release.version,
                  dividerIndent: 16,
                  children: [
                    for (final change in release.changes)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('• $change'),
                      ),
                  ],
                )
            else if (snapshot.hasError)
              Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Text('暂时无法读取更新日志，请检查网络后重试。'),
                    TextButton(onPressed: _refresh, child: const Text('重试')),
                  ],
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}
