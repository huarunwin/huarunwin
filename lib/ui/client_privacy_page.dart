import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/site_models.dart';
import 'page_components.dart';
import 'site_reader.dart';

class ClientPrivacyPage extends StatefulWidget {
  const ClientPrivacyPage({super.key});

  @override
  State<ClientPrivacyPage> createState() => _ClientPrivacyPageState();
}

class _ClientPrivacyPageState extends State<ClientPrivacyPage> {
  late Future<String> _document = _load();

  Future<String> _load() =>
      rootBundle.loadString('docs/privacy.md', cache: false);

  Future<void> _refresh() async {
    setState(() => _document = _load());
    try {
      await _document;
    } catch (_) {
      // The bundled document can be retried without making a network request.
    }
  }

  Future<void> _openLink(String link) async {
    final base = Uri.parse(
      'https://github.com/freephilx/huarunwin/blob/main/docs/privacy.md',
    );
    try {
      final url = base.resolve(link);
      if (url.scheme != 'https' ||
          !await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const FormatException('链接无法打开。');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法打开链接，请稍后重试。')));
      }
    }
  }

  // The bundled document uses headings, paragraphs, lists, links and inline
  // code. Render those few forms natively without a second copy of its text.
  Widget _paragraph(String text) {
    final runs = <SiteText>[];
    var offset = 0;
    for (final match in RegExp(
      r'\[([^\]]+)\]\(([^)]+)\)|`([^`]+)`',
    ).allMatches(text)) {
      if (match.start > offset) {
        runs.add(SiteText(text.substring(offset, match.start)));
      }
      runs.add(
        match[3] != null
            ? SiteText(match[3]!, code: true)
            : SiteText(match[1]!, url: match[2]),
      );
      offset = match.end;
    }
    if (offset < text.length) runs.add(SiteText(text.substring(offset)));
    return SiteRichText(runs, onLink: _openLink);
  }

  Widget _body(String document) => SelectionArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in document.trim().split(RegExp(r'\n\s*\n')))
          if (!block.startsWith('# '))
            Padding(
              padding: EdgeInsets.only(
                top: block.startsWith('## ') ? 12 : 0,
                bottom: 16,
              ),
              child: block.startsWith('## ')
                  ? Text(
                      block.substring(3),
                      style: Theme.of(context).textTheme.titleMedium,
                    )
                  : block.startsWith('- ')
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 8,
                      children: [
                        for (final line in block.split('\n'))
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('•  '),
                              Expanded(child: _paragraph(line.substring(2))),
                            ],
                          ),
                      ],
                    )
                  : _paragraph(block.replaceAll('\n', ' ')),
            ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: FutureBuilder<String>(
        future: _document,
        builder: (context, snapshot) => ContentPage(
          title: '客户端隐私',
          showBackButton: true,
          onRefresh: _refresh,
          children: [
            if (snapshot.hasData)
              _body(snapshot.data!)
            else if (snapshot.hasError)
              Column(
                children: [
                  const Text('暂时无法读取客户端隐私说明。'),
                  TextButton(onPressed: _refresh, child: const Text('重试')),
                ],
              )
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    ),
  );
}
