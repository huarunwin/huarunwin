import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'components.dart';
import 'page_components.dart';

class LicensesPage extends StatefulWidget {
  const LicensesPage({super.key});

  @override
  State<LicensesPage> createState() => _LicensesPageState();
}

class _LicensesPageState extends State<LicensesPage> {
  late Future<Map<String, List<LicenseEntry>>> request = _licenses();

  Future<Map<String, List<LicenseEntry>>> _licenses() async {
    final packages = <String, List<LicenseEntry>>{};
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        (packages[package] ??= []).add(entry);
      }
    }
    return packages;
  }

  Future<void> _refresh() async {
    setState(() {
      request = _licenses();
    });
    try {
      await request;
    } catch (_) {
      // The page displays the failure and allows another pull or retry.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: FutureBuilder<Map<String, List<LicenseEntry>>>(
            future: request,
            builder: (context, snapshot) {
              final packages = snapshot.data?.keys.toList() ?? [];
              packages.sort((a, b) {
                final aIsProject = a == '华润赢客户端';
                final bIsProject = b == '华润赢客户端';
                if (aIsProject != bIsProject) return aIsProject ? -1 : 1;
                return a.toLowerCase().compareTo(b.toLowerCase());
              });
              return PageRefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        28 + PageSafeArea.topInsetOf(context),
                        20,
                        0,
                      ),
                      sliver: const SliverToBoxAdapter(
                        child: PageHeader(title: '软件许可', showBackButton: true),
                      ),
                    ),
                    if (snapshot.connectionState != ConnectionState.done &&
                        !snapshot.hasData)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (snapshot.hasError)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.description_outlined,
                          title: '暂时无法读取许可',
                          message: '请重试读取应用内的软件许可。',
                          action: FilledButton(
                            onPressed: _refresh,
                            child: const Text('重试'),
                          ),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                        sliver: SliverList.builder(
                          itemCount: packages.length,
                          itemBuilder: (context, index) {
                            final package = packages[index];
                            return PageRow(
                              title: package,
                              icon: Icons.code_rounded,
                              trailing: const Icon(Icons.chevron_right_rounded),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => Scaffold(
                                    body: PageSafeArea(
                                      child: ContentPage(
                                        title: package,
                                        showBackButton: true,
                                        children: [
                                          for (final entry
                                              in snapshot.data![package]!)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 28,
                                              ),
                                              child: SelectionArea(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment
                                                          .stretch,
                                                  children: [
                                                    for (final paragraph
                                                        in entry.paragraphs)
                                                      Padding(
                                                        padding: EdgeInsets.only(
                                                          left:
                                                              paragraph.indent >
                                                                  0
                                                              ? paragraph
                                                                        .indent *
                                                                    16.0
                                                              : 0,
                                                          bottom: 12,
                                                        ),
                                                        child: Text(
                                                          paragraph.text,
                                                          textAlign:
                                                              paragraph
                                                                      .indent ==
                                                                  LicenseParagraph
                                                                      .centeredIndent
                                                              ? TextAlign.center
                                                              : TextAlign.start,
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
