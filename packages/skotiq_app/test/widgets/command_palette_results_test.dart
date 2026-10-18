// The palette's results panel: as tall as what it lists, and one row per
// setting.
//
// Live (1920x1080): "polar" listed six results in a panel that kept its full
// results height, leaving ~150 px of empty panel under the last row. The same
// search listed the Sequencer's "Polar alignment stale after" twice, once by
// its title and once by the first words of its description.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/command_palette/command_palette.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(TextField), query);
    await tester.pump();
  }

  double paletteHeight(WidgetTester tester) => tester
      .getSize(
        find
            .descendant(
              of: find.byType(CommandPalette),
              matching: find.byType(Container),
            )
            .first,
      )
      .height;

  testWidgets('a short result list makes a short panel', (tester) async {
    await pumpAppScreen(tester, const CommandPalette(),
        size: const Size(1920, 1080));

    await search(tester, 'mosaic');
    final short = paletteHeight(tester);

    expect(
      short,
      lessThan(CommandPalette.inputHeight + CommandPalette.maxResultsHeight),
      reason: 'the panel kept the full results height for a short list',
    );

    await search(tester, 'a');
    final long = paletteHeight(tester);
    expect(long, greaterThan(short));
    expect(
      long,
      lessThanOrEqualTo(
        CommandPalette.inputHeight + CommandPalette.maxResultsHeight + 2,
      ),
      reason: 'a long list still stops at the maximum and scrolls',
    );
  });

  testWidgets('a setting found by its description is listed once, by name', (
    tester,
  ) async {
    await pumpAppScreen(tester, const CommandPalette(),
        size: const Size(1920, 1080));

    await search(tester, 'polar');

    expect(find.text('Polar alignment stale after'), findsOneWidget);
    expect(
      find.text('If the last polar alignment is older than'),
      findsNothing,
      reason: 'the description of a row is not a second setting',
    );
    expect(find.text('Polar alignment max age'), findsOneWidget);
    expect(
      find.textContaining('Sequence pre-flight flags the polar alignment'),
      findsNothing,
    );
  });

  testWidgets('a query that only the description matches still finds the row',
      (tester) async {
    await pumpAppScreen(tester, const CommandPalette(),
        size: const Size(1920, 1080));

    await search(tester, 'if the last polar');
    expect(find.text('Polar alignment stale after'), findsOneWidget);
  });
}
