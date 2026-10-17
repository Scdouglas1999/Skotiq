import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_app/screens/collaborative_sky/widgets/shared_library_card.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  testWidgets('empty summary pitches never shooting the same dark twice',
      (tester) async {
    await tester.pumpWidget(host(SharedLibraryCard(
      summary: const SharedLibrarySummary(publishedCount: 0, pulledCount: 0),
      onOpen: () {},
    )));
    await tester.pumpAndSettle();

    expect(
        find.textContaining('Never shoot the same dark twice'), findsOneWidget);
    expect(find.text('0'), findsNWidgets(2));
    expect(find.text('Open calibration library'), findsOneWidget);
  });

  testWidgets('populated summary surfaces shared + pulled counts',
      (tester) async {
    await tester.pumpWidget(host(SharedLibraryCard(
      summary: const SharedLibrarySummary(publishedCount: 3, pulledCount: 5),
      onOpen: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.textContaining('trust what you pull'), findsOneWidget);
  });

  testWidgets('tapping Open fires the callback', (tester) async {
    var opened = false;
    await tester.pumpWidget(host(SharedLibraryCard(
      summary: const SharedLibrarySummary(publishedCount: 1, pulledCount: 1),
      onOpen: () => opened = true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open calibration library'));
    expect(opened, isTrue);
  });
}
