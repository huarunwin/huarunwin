import 'package:flutter/material.dart';

import '../services/app_download_status.dart';
import '../services/app_library.dart';
import 'components.dart';
import 'page_components.dart';

/// Application information and file controls share the management page's scroll.
class AppLibraryOverview extends StatelessWidget {
  const AppLibraryOverview({
    super.key,
    required this.item,
    required this.onOpenInstallation,
    required this.checking,
    this.action,
    this.warning,
    this.onCheckUpdates,
    this.onViewDetails,
  });

  final LibraryItem item;
  final ValueChanged<AppDownloadStatus> onOpenInstallation;
  final bool checking;
  final Widget? action;
  final String? warning;
  final VoidCallback? onCheckUpdates, onViewDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = item.installations;
    final details = item.status?.details;
    final available = item.platform == null
        ? null
        : details?.versionForPlatform(item.platform!);
    final updateFailed = item.status?.updateCheckFailed == true;
    final localLabel = installed.length > 1
        ? '${installed.length} 个已安装身份'
        : installed.isNotEmpty
        ? '本机版本：${installed.single.version ?? '未读取到版本'}'
        : item.hasPendingPackage
        ? '有待安装的安装包'
        : '尚未确认本机安装状态';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SurfacePanel(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (item.app case final app?)
                    AppIcon(app, size: 56)
                  else
                    const IconWell(Icons.apps_rounded, size: 56),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(item.name, style: theme.textTheme.titleLarge),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText(localLabel),
              if (installed.length == 1) ...[
                const SizedBox(height: 4),
                SelectableText(
                  installed.single.installedPackage ??
                      installed.single.installedPath ??
                      '',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (available != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  !updateFailed && item.updateVersion != null
                      ? '可更新至 ${item.updateVersion}'
                      : '${updateFailed ? '上次读取的公开版本' : '公开版本'}：$available',
                ),
              ] else if (item.app != null) ...[
                const SizedBox(height: 8),
                Text(details == null ? '尚未取得更新信息' : '暂无该平台的公开版本'),
              ],
              if (warning != null || updateFailed) ...[
                const SizedBox(height: 8),
                Text(
                  warning ?? '更新检查失败，已保留上次结果，请重试。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 16), action!],
              if (installed.length > 1)
                for (final installation in installed) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              installation.installedPackage ??
                                  installation.installedPath ??
                                  '',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '本机版本：${installation.version ?? '未读取到版本'}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => onOpenInstallation(installation),
                        child: const Text('打开'),
                      ),
                    ],
                  ),
                ],
              if (onCheckUpdates != null || onViewDetails != null) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    if (onCheckUpdates != null)
                      TextButton(
                        onPressed: checking ? null : onCheckUpdates,
                        child: Text(checking ? '检查中…' : '检查更新'),
                      ),
                    if (onViewDetails != null)
                      TextButton(
                        onPressed: onViewDetails,
                        child: const Text('查看应用介绍'),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        Text('安装包与资源（${item.files.length}）', style: theme.textTheme.titleSmall),
      ],
    );
  }
}
