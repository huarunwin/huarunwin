import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:share_plus_platform_interface/share_plus_platform_interface.dart'
    show SharePlatform;

import 'adaptive_dialog.dart';

class ShareLinkButton extends StatefulWidget {
  const ShareLinkButton({super.key, required this.url, required this.title});

  final String url, title;

  @override
  State<ShareLinkButton> createState() => _ShareLinkButtonState();
}

class _ShareLinkButtonState extends State<ShareLinkButton> {
  bool sharing = false;

  Future<void> _share() async {
    if (sharing) return;
    final box = context.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    final url = widget.url;
    final title = widget.title.trim();
    setState(() => sharing = true);
    try {
      // These plugin fallbacks open email instead of a system share sheet.
      if (Platform.isLinux ||
          SharePlatform.instance is SharePlusWindowsPlugin) {
        await _copyLinkDialog(url);
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          text: title.isEmpty ? url : '$title\n$url',
          title: title.isEmpty ? '分享链接' : title,
          subject: title.isEmpty ? null : title,
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      if (mounted) await _copyLinkDialog(url);
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  Future<void> _copyLinkDialog(String url) async {
    final copy = await showAdaptiveForm<bool>(
      context: context,
      builder: (dialogContext) => AdaptiveDialog(
        title: '分享链接',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('暂时无法打开系统分享，可复制链接。'),
            const SizedBox(height: 12),
            SelectableText(url),
          ],
        ),
        actions: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('复制链接'),
              ),
            ),
          ],
        ),
      ),
    );
    if (copy != true || !mounted) return;
    String message;
    try {
      await Clipboard.setData(ClipboardData(text: url));
      message = '已复制链接';
    } catch (_) {
      message = '暂时无法复制链接，请稍后重试。';
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '分享链接',
    onPressed: sharing ? null : _share,
    icon: const Icon(Icons.ios_share_rounded),
  );
}
