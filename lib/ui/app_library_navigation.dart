import 'package:flutter/widgets.dart';

/// Lets download actions on pushed routes return to the shared library tab.
class AppLibraryNavigation extends InheritedWidget {
  const AppLibraryNavigation({
    super.key,
    required this.onShowDownloads,
    required super.child,
  });

  final VoidCallback onShowDownloads;

  static bool showDownloads(BuildContext context) {
    final navigation = context
        .getInheritedWidgetOfExactType<AppLibraryNavigation>();
    if (navigation == null) return false;
    navigation.onShowDownloads();
    return true;
  }

  @override
  bool updateShouldNotify(AppLibraryNavigation oldWidget) =>
      oldWidget.onShowDownloads != onShowDownloads;
}
