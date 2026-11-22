// A phone header whose actions leave the title less room than its icon drops
// the icon and ellipsizes the title instead of overflowing (the Guiding header
// at 360 px with its "Not guiding" chip).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('a squeezed title gives up its icon, not the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: PageHeader(
            icon: Icons.explore,
            title: 'Guiding',
            actions: [SizedBox(width: 290, height: 32)],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.explore), findsNothing);
    expect(find.text('Guiding'), findsOneWidget);
  });

  testWidgets('a title with room keeps its icon', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: PageHeader(icon: Icons.explore, title: 'Guiding'),
        ),
      ),
    );

    expect(find.byIcon(Icons.explore), findsOneWidget);
  });
}
