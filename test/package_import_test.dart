import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';

class ImportPicker extends FilePickerPlatform {
  Object? error;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (error case final error?) throw error;
    return null;
  }
}

void main() {
  late Directory directory;
  late DownloadManager manager;
  late FilePickerPlatform originalPicker;
  late ImportPicker picker;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('huarun-import-test');
    manager = DownloadManager(directory);
    originalPicker = FilePickerPlatform.instance;
    picker = ImportPicker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() {
    FilePickerPlatform.instance = originalPicker;
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    manager.dispose();
    directory.deleteSync(recursive: true);
  });

  for (final code in ['ENTITLEMENT_NOT_FOUND', 'other']) {
    testWidgets('picker $code is not reported as an unreadable package', (
      tester,
    ) async {
      picker.error = PlatformException(code: code);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await tester.tap(find.text('选择本地安装包'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          code == 'ENTITLEMENT_NOT_FOUND'
              ? '文件选择器缺少读取权限配置，请更新客户端后重试。'
              : '无法打开文件选择窗口，请重试。',
        ),
        findsOneWidget,
      );
      expect(manager.tasks, isEmpty);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    }, skip: !Platform.isMacOS);
  }

  testWidgets('cancelling the picker creates no task or error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadsPage(manager: manager)),
      ),
    );
    await tester.tap(find.text('选择本地安装包'));
    await tester.pumpAndSettle();
    expect(manager.tasks, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  }, skip: !Platform.isMacOS);
}
