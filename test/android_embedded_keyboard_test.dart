import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/ui/airport_catalog.dart';
import 'package:huarunwin/ui/reading_catalog.dart';
import 'package:huarunwin/ui/theme.dart';

void main() {
  for (final reading in [false, true]) {
    testWidgets(
      '${reading ? 'reading' : 'service'} search keeps results above the keyboard in the home page',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        const item = SiteItem(
          title: 'Fixture',
          url: 'https://huarun.win/jichang/fixture',
        );
        const document = SiteDocument(
          title: 'Fixture directory',
          url: 'https://huarun.win/jichang',
          directory: true,
        );
        final page = reading
            ? ReadingCatalog(
                kind: SiteReadingKind.person,
                document: document,
                items: const [item],
                embedded: true,
                loading: false,
                collecting: false,
                allLoaded: true,
                actions: const [],
                onRefresh: () async {},
                onOpen: (_) {},
                onCollect: () {},
                onStop: () {},
              )
            : AirportCatalog(
                document: document,
                items: const [item],
                embedded: true,
                loading: false,
                collecting: false,
                allLoaded: true,
                actions: const [],
                footer: const SizedBox.shrink(),
                onRefresh: () async {},
                onOpen: (_) {},
                onCollect: () {},
                onStop: () {},
              );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(body: page),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Fixture');
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(CustomScrollView).last).height, 544);
        expect(
          find.text('Fixture', findRichText: false).last.hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
