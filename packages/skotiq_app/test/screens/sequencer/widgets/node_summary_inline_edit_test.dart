// WIDGET round-trip tests for the inline quick-edit affordance wired into the
// sequencer tree: editors, summary line and tree wiring.
//
// These pin the END-TO-END inline-edit contract through the real SequenceTree:
//   * Tapping an editable summary chip opens its anchored editor and committing
//     a value round-trips through `currentSequenceProvider.notifier.updateNode`
//     (proven by reading the mutated node back out of the provider).
//   * The filter edit writes BOTH `filter` and `filterIndex` (panel parity).
//   * The count stepper increments the node by one.
//   * While the sequence is LOCKED (running), an editable chip degrades to a
//     plain, non-tappable chip — tapping it opens no editor and never mutates.
//
// Harness mirrors sequence_tree_watchdog_badge_test.dart exactly:
// UncontrolledProviderScope + SkotiqTheme.dark + createSequence/addNode,
// pumping 600ms past the liveValidationProvider debounce timer so no pending
// Timer trips the binding at teardown. An active EquipmentProfile is seeded so
// the filter editor renders a closed dropdown of the profile's filter names
// (mirrors exposure_properties_recommendation_test.dart's profile seeding).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequencer_density.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _profile = EquipmentProfileModel(
  name: 'Test rig',
  focalLength: 384,
  aperture: 80,
  filterNames: ['Lum', 'Ha', 'OIII'],
  defaultGain: 100,
  defaultOffset: 50,
);

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      activeEquipmentProfileProvider.overrideWithValue(_profile),
      // The editable summary chips live on the comfortable card's summary
      // line; the ledger row has fixed readout columns, not chips.
      sequencerDensityProvider
          .overrideWith((ref) => SequencerDensity.comfortable),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpTreeWithNode(
  WidgetTester tester,
  ProviderContainer container,
  SequenceNode node, {
  SequenceExecutionState? lockAfterSeed,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 700);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  // Seed an active sequence (creates the root) and attach the node — done while
  // the execution state is still idle so the editor's lock-gate does not reject
  // the seeding writes.
  container.read(currentSequenceProvider.notifier).createSequence(name: 'test');
  container.read(currentSequenceProvider.notifier).addNode(node);

  // Optionally flip the sequence into a locked execution state AFTER seeding so
  // canEditSequenceProvider reads false for the lock-gate test.
  if (lockAfterSeed != null) {
    container.read(sequenceExecutionStateProvider.notifier).state =
        lockAfterSeed;
  }

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: SequenceTree(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  // liveValidationProvider debounces validation with a 500ms one-shot Timer on
  // mutation. Advance past it so the timer fires/clears before teardown.
  await tester.pump(const Duration(milliseconds: 600));
}

ExposureNode _exposureFrom(ProviderContainer container) => container
    .read(currentSequenceProvider)!
    .nodes
    .values
    .whereType<ExposureNode>()
    .first;

void main() {
  testWidgets(
    'tapping the filter chip and picking a filter round-trips through updateNode',
    (tester) async {
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(count: 5, durationSecs: 120, filter: 'Lum'),
      );

      // The editable filter chip shows the current filter name and is exposed
      // as a button via Semantics(label: 'filter').
      final filterChip = find.ancestor(
        of: find.text('Lum'),
        matching: find.byType(InkWell),
      );
      expect(filterChip, findsWidgets);
      await tester.tap(filterChip.first);
      await tester.pumpAndSettle();

      // The anchored editor opens a menu listing the profile's filters. Pick Ha.
      expect(find.text('Ha'), findsOneWidget);
      await tester.tap(find.text('Ha'));
      await tester.pumpAndSettle();
      // The edit re-arms the live-validation debounce timer; advance past it so
      // no pending Timer trips the binding at teardown.
      await tester.pump(const Duration(milliseconds: 600));

      final updated = _exposureFrom(container);
      expect(updated.filter, 'Ha');
      // Index of 'Ha' in ['Lum','Ha','OIII'] is 1 — written for reliability.
      expect(updated.filterIndex, 1);
    },
  );

  testWidgets(
    'tapping the count chip and pressing + increments ExposureNode.count',
    (tester) async {
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(count: 5, durationSecs: 120, filter: 'Lum'),
      );

      expect(_exposureFrom(container).count, 5);

      // The count chip carries Semantics(label: 'exposure count'); its value
      // text ('5') is wrapped by the tappable InkWell. Tap the value text so we
      // land squarely on the chip's tap target.
      final countChip = find.ancestor(
        of: find.text('5'),
        matching: find.byType(InkWell),
      );
      expect(countChip, findsWidgets);
      await tester.tap(countChip.first);
      await tester.pumpAndSettle();

      // The stepper exposes its plus button as Semantics(label: 'Increase').
      final plus = find.bySemanticsLabel('Increase');
      expect(plus, findsOneWidget);
      await tester.tap(plus);
      await tester.pump();
      // Advance past the re-armed live-validation debounce timer.
      await tester.pump(const Duration(milliseconds: 600));

      expect(_exposureFrom(container).count, 6);
    },
  );

  testWidgets(
    'the count stepper keeps incrementing on repeated + taps',
    (tester) async {
      // Building the popup from the node SNAPSHOT captured when the chip was
      // tapped makes every '+' recompute `snapshot.count + 1`: a stepper opened
      // on 4 goes 4 -> 5 and then eight more '+' taps change nothing while the
      // popup still reads '4'. One tap cannot catch this, which is why the test
      // above does not.
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(count: 5, durationSecs: 120, filter: 'Lum'),
      );

      final countChip = find.ancestor(
        of: find.text('5'),
        matching: find.byType(InkWell),
      );
      await tester.tap(countChip.first);
      await tester.pumpAndSettle();

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.bySemanticsLabel('Increase'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
      }

      expect(_exposureFrom(container).count, 8);
      // The popup must also SHOW the value it committed, not the stale one.
      expect(find.text('8'), findsWidgets);
    },
  );

  testWidgets(
    'tapping the gain chip and typing a value round-trips through updateNode',
    (tester) async {
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(
          count: 5,
          durationSecs: 120,
          filter: 'Lum',
          gain: 100,
        ),
      );

      expect(_exposureFrom(container).gain, 100);

      // The gain chip renders 'gain 100' and carries Semantics(label: 'gain').
      final gainChip = find.ancestor(
        of: find.text('gain 100'),
        matching: find.byType(InkWell),
      );
      expect(gainChip, findsWidgets);
      await tester.tap(gainChip.first);
      await tester.pumpAndSettle();

      // The anchored editor opens a numeric field titled 'Gain' (decimals: 0).
      expect(find.text('Gain'), findsOneWidget);
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      // Overtype the auto-selected text; the field commits clamped-on-change.
      await tester.enterText(field, '220');
      await tester.pump();
      // Advance past the re-armed live-validation debounce timer.
      await tester.pump(const Duration(milliseconds: 600));

      expect(_exposureFrom(container).gain, 220);
    },
  );

  testWidgets(
    'tapping the binning chip and picking a mode round-trips through updateNode',
    (tester) async {
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(
          count: 5,
          durationSecs: 120,
          filter: 'Lum',
          binning: BinningMode.one,
        ),
      );

      expect(_exposureFrom(container).binning, BinningMode.one);

      // The binning chip renders the current mode label ('1x1').
      final binningChip = find.ancestor(
        of: find.text('1x1'),
        matching: find.byType(InkWell),
      );
      expect(binningChip, findsWidgets);
      await tester.tap(binningChip.first);
      await tester.pumpAndSettle();

      // The anchored editor opens a 'Binning' menu listing every BinningMode.
      // Pick 2x2.
      expect(find.text('Binning'), findsOneWidget);
      expect(find.text('2x2'), findsOneWidget);
      await tester.tap(find.text('2x2'));
      await tester.pumpAndSettle();
      // Advance past the re-armed live-validation debounce timer.
      await tester.pump(const Duration(milliseconds: 600));

      expect(_exposureFrom(container).binning, BinningMode.two);
    },
  );

  testWidgets(
    'while the sequence is LOCKED, tapping an editable chip opens no editor and '
    'does not mutate the node',
    (tester) async {
      final container = _container();

      await _pumpTreeWithNode(
        tester,
        container,
        ExposureNode(count: 5, durationSecs: 120, filter: 'Lum'),
        lockAfterSeed: SequenceExecutionState.running,
      );

      // Sanity: the lock gate is closed.
      expect(container.read(canEditSequenceProvider), isFalse);

      // The locked chip degrades to a plain, non-tappable chip with NO
      // chevron and NO button Semantics, so there is no fake affordance.
      expect(find.bySemanticsLabel('filter'), findsNothing);
      expect(find.bySemanticsLabel('exposure count'), findsNothing);

      // The filter name is still rendered (read-only), but tapping it does
      // nothing: no editor opens.
      final filterText = find.text('Lum');
      expect(filterText, findsOneWidget);
      await tester.tap(filterText, warnIfMissed: false);
      await tester.pumpAndSettle();

      // No menu opened — 'Ha' from the (would-be) dropdown is absent.
      expect(find.text('Ha'), findsNothing);

      // The node is untouched.
      final node = _exposureFrom(container);
      expect(node.filter, 'Lum');
      expect(node.count, 5);
    },
  );
}
