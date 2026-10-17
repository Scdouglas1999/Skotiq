// The filters measured from the observing site must be dead when there is no
// site.
//
// Measured against the release bundle on a fresh profile: Plan Tonight's body
// read "Location not configured — Set your observing latitude and longitude in
// Settings before using the planner", while the chip row above it offered a
// live "Alt now: any" that opened a "Minimum altitude right now" slider with
// Clear and Apply, and "Moon: any" beside it. Both limits are evaluated against
// each candidate's visibility record, which is computed from the site, so the
// screen was offering to apply a constraint it could not evaluate — on the very
// screen that had just said so. The accessibility tree showed them without
// [DISABLED] and without a reason in the name.
//
// Driven through the chips directly rather than through PlannerScreen: the
// planner runs a 1 s periodic sky clock, so `pumpAndSettle` never returns there.
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  Future<void> pumpChips(WidgetTester tester, LocationSettings? site) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appObserverLocationProvider.overrideWithValue(site)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: plannerSiteFilterChipsForTest(
                  SkotiqColors.of(context),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The chip's accessible name, as a pattern.
  ///
  /// The chip's own label and the label of the `Text` it wraps are merged into
  /// one node, so the name carries both — matching a prefix rather than the
  /// whole string keeps this test about the refusal and not about that merge.
  RegExp namedForRefusal(String label) =>
      RegExp('^${RegExp.escape('$label — $kPlannerSiteFilterRefusal')}');

  testWidgets('with no site both chips carry the reason and refuse the tap',
      (tester) async {
    final handle = tester.ensureSemantics();

    await pumpChips(tester, null);

    for (final label in const ['Alt now: any', 'Moon: any']) {
      final name = namedForRefusal(label);
      expect(
        find.bySemanticsLabel(name),
        findsOneWidget,
        reason: 'the refusal has to be in the NAME: the Linux AT-SPI bridge '
            'drops tooltips, so a reason only a pointer can reach is none',
      );
      final data =
          tester.getSemantics(find.bySemanticsLabel(name)).getSemanticsData();
      expect(
        data.flagsCollection.isEnabled,
        Tristate.isFalse,
        reason: 'a chip that cannot be applied must not read as available',
      );
      expect(data.hasAction(SemanticsAction.tap), isFalse);
    }

    await tester.tap(find.text('Alt now: any'));
    await tester.pumpAndSettle();
    expect(
      find.text('Minimum altitude right now'),
      findsNothing,
      reason: 'this is the slider the fresh install opened over its own '
          '"Location not configured" message',
    );

    await tester.tap(find.text('Moon: any'));
    await tester.pumpAndSettle();
    expect(find.text('Minimum moon separation'), findsNothing);

    handle.dispose();
  });

  testWidgets('with a site set both chips are live again', (tester) async {
    final handle = tester.ensureSemantics();

    await pumpChips(
      tester,
      const LocationSettings(latitude: 40.7, longitude: -74.0),
    );

    final data = tester
        .getSemantics(
          find.bySemanticsLabel(RegExp('^${RegExp.escape('Moon: any')}')),
        )
        .getSemanticsData();
    expect(
      data.flagsCollection.isEnabled,
      Tristate.isTrue,
      reason: 'the gate is the missing site and nothing else',
    );
    expect(
      find.bySemanticsLabel(namedForRefusal('Moon: any')),
      findsNothing,
    );

    await tester.tap(find.text('Moon: any'));
    await tester.pumpAndSettle();
    expect(find.text('Minimum moon separation'), findsOneWidget);

    handle.dispose();
  });
}
