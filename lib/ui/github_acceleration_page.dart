import 'package:flutter/material.dart';

import '../services/github_acceleration.dart';
import 'page_components.dart';

class GitHubAccelerationPage extends StatefulWidget {
  const GitHubAccelerationPage({super.key, required this.acceleration});
  final GitHubAcceleration acceleration;

  @override
  State<GitHubAccelerationPage> createState() => _GitHubAccelerationPageState();
}

class _GitHubAccelerationPageState extends State<GitHubAccelerationPage> {
  bool _saving = false;

  Future<void> _select(GitHubAccessMode mode) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.acceleration.select(mode);
    } catch (_) {
      _message('未能保存 GitHub 加速设置，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _refresh() async {
    if (_saving) return;
    try {
      await widget.acceleration.reload();
      widget.acceleration.retryPrimary();
      if (widget.acceleration.mode == GitHubAccessMode.automatic) {
        _message('已清除回退保持期，下次请求优先重试 GitHub 直连。');
      }
    } catch (_) {
      _message('暂时无法读取 GitHub 加速设置，请重试。');
    }
  }

  String _status(GitHubTraffic traffic) {
    final acceleration = widget.acceleration;
    if (acceleration.mode != GitHubAccessMode.automatic) {
      return acceleration.mode.label;
    }
    final last = acceleration.lastSuccessful(traffic);
    return last == null ? '优先尝试 GitHub 直连' : '最近成功：${last.label}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: ListenableBuilder(
        listenable: widget.acceleration,
        builder: (context, _) => ContentPage(
          title: 'GitHub 加速',
          showBackButton: true,
          onRefresh: _refresh,
          children: [
            PageSection(
              title: '连接方式',
              footer: '用于 GitHub 镜像的目录、详情与图片，以及客户端更新信息和应用内文件下载。已开始的下载沿用开始时的设置。',
              children: [
                for (final mode in GitHubAccessMode.values)
                  PageRow(
                    title: mode.label,
                    subtitle: switch (mode) {
                      GitHubAccessMode.automatic =>
                        '直连失败后尝试 GH-Proxy，回退成功保持 2 小时。',
                      GitHubAccessMode.direct => '始终直连 GitHub，不使用加速服务。',
                      GitHubAccessMode.proxy => '始终通过 gh-proxy.com 获取支持的文件。',
                    },
                    trailing: widget.acceleration.mode == mode
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: _saving ? null : () => _select(mode),
                  ),
              ],
            ),
            PageSection(
              title: '连接状态',
              footer: '目录与更新信息、文件下载分别记录回退时间，普通成功请求不会延长保持期。镜像图片跟随目录与更新信息的线路，不改变保持期。到期后下一次联网重试直连；刷新本页可立即清除保持期。',
              children: [
                PageRow(
                  title: '目录与更新信息',
                  subtitle: _status(GitHubTraffic.raw),
                  icon: Icons.description_outlined,
                ),
                PageRow(
                  title: '安装包与资源下载',
                  subtitle: _status(GitHubTraffic.download),
                  icon: Icons.download_outlined,
                ),
                const PageRow(
                  title: 'GitHub 版本列表',
                  subtitle: 'GitHub 直连 · GH-Proxy 暂不支持当前列表读取方式。',
                  icon: Icons.list_alt_rounded,
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '网站与 jsDelivr 的图片、外部图片、外部网页和交给浏览器的下载不使用此加速设置。使用 GH-Proxy 时，相关请求会经过该第三方服务。',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
