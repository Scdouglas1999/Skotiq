// The "In this sequence" section of the Targets panel.
//
// The tab used to be called Queue and showed only the planetarium wishlist, so
// loading the bundled "Mono LRGB M51" starter — a sequence with a target in it
// — produced a panel reading "Your target queue is empty." These tests pin the
// repair: the panel lists the sequence's own target headers, in the order the
// canvas bar counts them, with the coordinates and the planned capture the
// tree row carries, and a tap that selects the header and scrolls the tree to
// it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/plan_math.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_tree.dart'
    show treeNodeKeyRegistryProvider;
import 'package:skotiq_app/screens/sequencer/widgets/target_queue_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// How far down the fake tree the second target's row sits. Larger than the
/// viewport so a tap that scrolls to it must move the offset off zero.
const double _fakeTreeRowOffset = 2000;

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    tickerProvider(TickerCadence.thirtySeconds).overrideWith(
      (ref) => Stream.value(DateTime.utc(2024, 6, 15, 22)),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// `TargetHeader → Exposure(count × durationSecs)`, appended to the sequence.
TargetHeaderNode _seedTarget(
  ProviderContainer container, {
  required String name,
  required double raHours,
  required double decDegrees,
  int count = 0,
  double durationSecs = 60,
}) {
  final editor = container.read(currentSequenceProvider.notifier);
  final target = TargetHeaderNode(
    name: name,
    targetName: name,
    raHours: raHours,
    decDegrees: decDegrees,
  );
  editor.addNode(target);
  if (count > 0) {
    editor.addNode(
      ExposureNode(
        name: 'Lights',
        durationSecs: durationSecs,
        count: count,
      ),
      parentId: target.id,
    );
  }
  return target;
}

Future<void> _pumpPanel(
  WidgetTester tester,
  ProviderContainer container, {
  ScrollController? treeController,
  Map<String, GlobalKey> treeKeys = const {},
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(builder: (context) {
          final colors = SkotiqColors.of(context);
          return Scaffold(
            body: Row(
              children: [
                SizedBox(width: 320, child: TargetQueuePanel(colors: colors)),
                // Stands in for the sequence tree: a scroll view carrying the
                // registered row keys, so the panel's jump exercises the real
                // `Scrollable.ensureVisible` path rather than a stub.
                Expanded(
                  child: SingleChildScrollView(
                    controller: treeController,
                    child: SizedBox(
                      height: _fakeTreeRowOffset + 400,
                      child: Stack(
                        children: [
                          for (final entry in treeKeys.entries)
                            Positioned(
                              top: _fakeTreeRowOffset,
                              child: SizedBox(
                                key: entry.value,
                                height: 28,
                                width: 200,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('targetPlanSummary', () {
    test('counted frames read as frames and integration', () {
      const planned = PlannedCapture(
        frames: 12,
        integrationSecs: 720,
        integrationSecsByFilter: {'L': 720},
        hasOpenEndedLoop: false,
        openEndedBudgetSecs: 0,
        hasUnboundedRepeat: false,
      );
      expect(targetPlanSummary(planned), '12 frames · 12m');
    });

    test('a single frame is not pluralised', () {
      const planned = PlannedCapture(
        frames: 1,
        integrationSecs: 60,
        integrationSecsByFilter: {'L': 60},
        hasOpenEndedLoop: false,
        openEndedBudgetSecs: 0,
        hasUnboundedRepeat: false,
      );
      expect(targetPlanSummary(planned), '1 frame · 1m');
    });

    test('an unbounded loop makes the count a per-pass figure', () {
      const planned = PlannedCapture(
        frames: 4,
        integrationSecs: 240,
        integrationSecsByFilter: {'L': 240},
        hasOpenEndedLoop: false,
        openEndedBudgetSecs: 0,
        hasUnboundedRepeat: true,
      );
      expect(targetPlanSummary(planned), '4 frames · 4m per pass');
    });

    test('an open-ended loop is described, never counted as zero', () {
      const planned = PlannedCapture(
        frames: 0,
        integrationSecs: 0,
        integrationSecsByFilter: {},
        hasOpenEndedLoop: true,
        openEndedBudgetSecs: 7200,
        hasUnboundedRepeat: false,
      );
      expect(targetPlanSummary(planned), 'Looping up to 2h 0m');
    });

    test('a target with nothing under it says so', () {
      expect(targetPlanSummary(PlannedCapture.empty), 'No exposures yet');
    });
  });

  group('Targets panel — In this sequence', () {
    testWidgets('lists target headers in order, with chips and summaries',
        (tester) async {
      final container = _container();
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'Mono LRGB M51');
      _seedTarget(container,
          name: 'M51', raHours: 13.5, decDegrees: 47.0, count: 12);
      _seedTarget(container,
          name: 'NGC 7000', raHours: 20.5, decDegrees: -5.5, count: 3);

      await _pumpPanel(tester, container);

      expect(find.text('IN THIS SEQUENCE'), findsOneWidget);
      expect(find.byKey(const ValueKey('in_sequence_target_list')),
          findsOneWidget);

      expect(find.text('13h30m'), findsOneWidget);
      expect(find.text("+47°00'"), findsOneWidget);
      expect(find.text('12 frames · 12m'), findsOneWidget);

      expect(find.text('20h30m'), findsOneWidget);
      expect(find.text("-05°30'"), findsOneWidget);
      expect(find.text('3 frames · 3m'), findsOneWidget);

      // Tree order, not alphabetical and not queue order.
      final m51 = tester.getTopLeft(find.text('M51')).dy;
      final ngc = tester.getTopLeft(find.text('NGC 7000')).dy;
      expect(m51, lessThan(ngc));
    });

    testWidgets('a target with no coordinates shows the warning chip',
        (tester) async {
      final container = _container();
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'unset');
      _seedTarget(container, name: 'New target', raHours: 0, decDegrees: 0);

      await _pumpPanel(tester, container);

      expect(find.text('Not set'), findsOneWidget);
      // The placeholder pointing is never dressed up as a real one.
      expect(find.text('00h00m'), findsNothing);
      expect(find.text("+00°00'"), findsNothing);
    });

    testWidgets('tapping a row selects the header and scrolls the tree to it',
        (tester) async {
      final container = _container();
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'jump');
      final target = _seedTarget(container,
          name: 'M51', raHours: 13.5, decDegrees: 47.0, count: 12);

      final key = GlobalKey();
      final treeController = ScrollController();
      addTearDown(treeController.dispose);
      container.read(treeNodeKeyRegistryProvider.notifier).state = {
        target.id: key,
      };

      await _pumpPanel(
        tester,
        container,
        treeController: treeController,
        treeKeys: {target.id: key},
      );

      expect(container.read(selectedNodeIdProvider), isNull);
      expect(treeController.offset, 0);

      await tester.tap(find.text('M51'));
      await tester.pumpAndSettle();

      expect(container.read(selectedNodeIdProvider), target.id);
      expect(treeController.offset, greaterThan(0));
    });

    testWidgets('an empty sequence says what to do, in one sentence',
        (tester) async {
      final container = _container();
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'empty');

      await _pumpPanel(tester, container);

      expect(
        find.text('No targets in this sequence yet. Drop a Target from the '
            'Nodes tab, or pick one below.'),
        findsOneWidget,
      );
      // The wishlist section stays visible so its purpose is readable even
      // with nothing in either list.
      expect(find.text('SAVED FOR LATER'), findsOneWidget);
    });

    testWidgets('with no sequence loaded the section still explains itself',
        (tester) async {
      final container = _container();

      await _pumpPanel(tester, container);

      expect(find.text('IN THIS SEQUENCE'), findsOneWidget);
      expect(
        find.text('No targets in this sequence yet. Drop a Target from the '
            'Nodes tab, or pick one below.'),
        findsOneWidget,
      );
    });
  });
}
