// The floating "Build tonight's plan?" nudge is drawn OVER the dashboard, so at
// the bottom of the scroll extent it can cover the Moon card — the Moonrise
// row's value hidden while "Moonset 20:34" stays visible (nudge x 537-920 /
// y 537-645 over a Moon card at x 258-722).
//
// A floating overlay has to be paid for in the scroll view it floats above:
// while the prompt is up, the dashboard's scroll extent keeps its band clear so
// the last card can be scrolled out from under it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/glass_card.dart';
import 'package:skotiq_app/screens/dashboard/widgets/smart_night_prompt_card.dart'
    show floatingPromptOwnersProvider, kFloatingPromptReservedHeight;
import 'package:skotiq_ui/skotiq_ui.dart';

Future<double> _bottomPadding(WidgetTester tester,
    {required bool promptShowing}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        floatingPromptOwnersProvider.overrideWith(
          (_) => promptShowing
              ? {'test-card': kFloatingPromptReservedHeight}
              : const <String, double>{},
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: DashboardScrollView(
            padding: EdgeInsets.all(16),
            child: SizedBox(height: 2000, child: Text('Moon')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final scrollView = tester.widget<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  );
  return (scrollView.padding! as EdgeInsets).bottom;
}

void main() {
  testWidgets('the scroll extent reserves the floating prompt band', (
    tester,
  ) async {
    expect(
      await _bottomPadding(tester, promptShowing: true),
      greaterThanOrEqualTo(16 + kFloatingPromptReservedHeight),
      reason: 'the last card could not be scrolled clear of the nudge',
    );
  });

  testWidgets('and gives the space back when the prompt is not up', (
    tester,
  ) async {
    expect(await _bottomPadding(tester, promptShowing: false), 16);
  });
}
