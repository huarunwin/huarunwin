import 'package:flutter/material.dart';

import '../data/site_parser.dart';
import 'web_page.dart';

class CorrectionsPage extends StatelessWidget {
  const CorrectionsPage({super.key});

  static final uri = Uri.parse('${SiteRoutes.origin}/corrections/app');

  @override
  Widget build(BuildContext context) =>
      WebPage(uri: uri, title: '纠错', syncCorrectionTheme: true);
}
