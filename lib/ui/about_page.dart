import 'package:flutter/material.dart';

import '../data/site_parser.dart';
import '../services/app_controller.dart';
import '../services/downloads.dart';
import 'client_privacy_page.dart';
import 'components.dart';
import 'licenses_page.dart';
import 'page_components.dart';
import 'site_page.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({
    super.key,
    required this.controller,
    required this.downloads,
  });

  final AppController controller;
  final DownloadManager downloads;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: ContentPage(
        title: '关于华润赢',
        showBackButton: true,
        children: [
          PageSection(
            title: '隐私与许可',
            children: [
              PageRow(
                title: '客户端隐私',
                icon: Icons.privacy_tip_outlined,
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ClientPrivacyPage(),
                  ),
                ),
              ),
              PageRow(
                title: '软件许可',
                icon: Icons.code_rounded,
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(builder: (_) => const LicensesPage()),
                ),
              ),
            ],
          ),
          PageSection(
            title: '网站说明',
            children: [
              for (final path in const [
                '/about',
                '/editorial-policy',
                '/privacy',
                '/terms',
              ])
                PageRow(
                  title: path == '/privacy'
                      ? '网站隐私'
                      : SiteRoutes.sections[path]!,
                  icon: switch (path) {
                    '/editorial-policy' => Icons.fact_check_outlined,
                    '/privacy' => Icons.privacy_tip_outlined,
                    '/terms' => Icons.description_outlined,
                    _ => Icons.info_outline_rounded,
                  },
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SitePage(
                        url: '${SiteRoutes.origin}$path',
                        controller: controller,
                        downloads: downloads,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          PageSection(
            title: '网站',
            children: [
              PageRow(
                title: '访问网站',
                icon: Icons.language_rounded,
                trailing: const Icon(Icons.open_in_new_rounded, size: 16),
                onTap: () => openLink(context, SiteRoutes.origin),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
