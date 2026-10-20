import 'package:flutter/material.dart';

import '../services/android_package.dart';
import '../services/downloads.dart';
import 'components.dart';

/// Caches display information for one file; installation always inspects again.
class ApkFileDetails extends StatefulWidget {
  const ApkFileDetails({
    super.key,
    required this.task,
    required this.package,
    required this.manager,
    required this.revision,
    required this.readable,
    required this.fingerprint,
  });

  final DownloadTask task;
  final DownloadPackage package;
  final DownloadManager manager;
  final int revision;
  final bool readable;
  final String fingerprint;

  @override
  State<ApkFileDetails> createState() => _ApkFileDetailsState();
}

class _ApkFileDetailsState extends State<ApkFileDetails> {
  Future<AndroidApkDetails>? _details;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _details = widget.readable
        ? widget.manager.readApkDetails(widget.task, widget.package)
        : null;
  }

  @override
  void didUpdateWidget(covariant ApkFileDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.manager != widget.manager ||
        oldWidget.task != widget.task ||
        oldWidget.package != widget.package ||
        oldWidget.revision != widget.revision ||
        oldWidget.fingerprint != widget.fingerprint ||
        !oldWidget.readable && widget.readable) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AndroidApkDetails>(
    future: _details,
    builder: (context, snapshot) {
      final colors = Theme.of(context).colorScheme;
      final style = Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: colors.onSurfaceVariant);
      final details = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      final info = details?.info;
      final certificates = info?.certificateSha256 ?? const <String>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details == null && !snapshot.hasError)
            Text(
              widget.readable ? '正在读取包名、版本、大小与签名…' : '包名与签名待文件空闲后读取',
              style: style,
            ),
          if (snapshot.hasError || details?.error != null)
            TextButton.icon(
              onPressed: widget.readable ? () => setState(_load) : null,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('包信息读取失败，点击重试'),
            ),
          if (details != null) ...[
            SelectableText(
              '包名：${info?.packageName ?? (details.error == null ? '需在 Android 上读取' : '未取得')}',
              style: style,
            ),
            const SizedBox(height: 4),
            Text(
              '版本：${info?.version ?? '未取得'} · APK · ${bytesLabel(details.bytes)}',
              style: style,
            ),
            if (certificates.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('签名：未取得证书信息', style: style),
              )
            else
              ExpansionTile(
                key: ValueKey(certificates.join()),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                dense: true,
                title: Text('签名证书 SHA-256', style: style),
                subtitle: Text(
                  certificates.map(_abbreviate).join('\n'),
                  style: style,
                ),
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SelectableText(
                      certificates.join('\n'),
                      style: style,
                    ),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );

  String _abbreviate(String digest) => digest.length <= 28
      ? digest
      : '${digest.substring(0, 12)}…${digest.substring(digest.length - 12)}';
}
