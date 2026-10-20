// The action bar: what pressing a button does, why a disabled one is
// disabled, Cancel while busy, and how the hint and sub-labels fold.
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/manual_action_bar.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';

import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

void main() {
  testWidgets('pressing an action opens its panel tab and starts nothing',
      (tester) async {
    final api = FakeNightActionApi();
    final container = await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), api: api),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    expect(container.read(nightPanelTabProvider), NightPanelTab.overview);

    await tester.tap(find.text('Autofocus'));
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.focus);

    await tester.ensureVisible(find.text('Dither'));
    await tester.pump();
    await tester.tap(find.text('Dither'));
    await tester.pump();
    expect(container.read(nightPanelTabProvider), NightPanelTab.guide);
    expect(api.ran, isEmpty);
  });

  testWidgets('an action that cannot run gives its reason and opens its tab',
      (tester) async {
    final handle = tester.ensureSemantics();
    final api = FakeNightActionApi();
    final container = await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), api: api),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    const reason = "The run's meridian trigger owns flips";
    final flip = find.bySemanticsLabel('Flip now');
    expect(flip, findsOneWidget);
    final data = tester.getSemantics(flip).getSemanticsData();
    expect(data.hint, reason);
    expect(data.flagsCollection.isEnabled, Tristate.isTrue);
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == reason),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Flip now'));
    await tester.pump();
    await tester.tap(find.text('Flip now'));
    await tester.pump();
    expect(api.ran, isEmpty);
    expect(container.read(nightPanelTabProvider), NightPanelTab.mount);
    handle.dispose();
  });

  testWidgets('the running action is marked and Cancel shows while busy',
      (tester) async {
    final api = FakeNightActionApi();
    final board = NightFixtures.autofocus();
    await pumpCenter(
      tester,
      centerOverrides(board, api: api),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    expect(find.text('running'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(api.cancels, 1);
  });

  testWidgets('no Cancel when nothing is busy', (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running()),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    expect(find.text('Cancel'), findsNothing);
  });

  testWidgets('wide: the hint is text and sub-labels show', (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running()),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    expect(
      find.text('Manual actions pause the run, then resume it'),
      findsOneWidget,
    );
    expect(find.text('5 s'), findsOneWidget);
  });

  testWidgets('744: the hint folds into an info icon and sub-labels hide',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running()),
      child: const ManualActionBar(),
      size: const Size(744, ManualActionBar.height),
    );
    expect(
      find.text('Manual actions pause the run, then resume it'),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            w.message == 'Manual actions pause the run, then resume it',
      ),
      findsOneWidget,
    );
    expect(find.text('5 s'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a run the hint says actions run right away',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.ready()),
      child: const ManualActionBar(),
      size: const Size(1000, ManualActionBar.height),
    );
    expect(
      find.text('Nothing is running · actions run right away'),
      findsOneWidget,
    );
    // Tracking and the cooler live in the Mount and Camera tabs.
    expect(find.text('Track'), findsNothing);
    expect(find.text('Cooler'), findsNothing);
  });
}
