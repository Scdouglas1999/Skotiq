// A step's time of day reads on the clock the Sequencer prints run times on
// (Settings > Location timezone), not on this machine's zone, so "End: 22:00"
// on a target and "done ~23:10" on the run band use one zone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary_line.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_timing_section.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  // An offset no test machine runs in, so the machine's zone cannot pass.
  const site = FixedOffsetClock(
    utcOffset: Duration(hours: 13, minutes: 45),
    label: 'UTC+13:45',
  );

  testWidgets('a wait step shows its time on the site clock', (tester) async {
    final node = WaitTimeNode(waitUntil: DateTime.utc(2026, 11, 26, 8, 15));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          clockProvider.overrideWithValue(site),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: NodeSummaryLine(
              node: node,
              colors: SkotiqColors.dark,
              isMobile: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('until 22:00'), findsOneWidget);
  });

  testWidgets('the timing section shows a wait time on the site clock', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        clockProvider.overrideWithValue(site),
      ],
    );
    addTearDown(container.dispose);
    final node = WaitTimeNode(waitUntil: DateTime.utc(2026, 11, 26, 8, 15));
    container.read(currentSequenceProvider.notifier)
      ..createSequence(name: 'test')
      ..addNode(node);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: NodeTimingSection(colors: SkotiqColors.dark, node: node),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('22:00'), findsOneWidget);
    // Past the live validation's debounce, so no timer is left at dispose.
    await tester.pump(const Duration(milliseconds: 600));
  });

  test('a time picked on the site clock is that time at the site', () {
    final picked = site.nextTimeOfDay(
      22,
      0,
      now: DateTime.utc(2026, 11, 26, 6),
    );
    expect(picked.isAtSameMomentAs(DateTime.utc(2026, 11, 26, 8, 15)), isTrue);
    // Local, as a step time read back from a saved plan is.
    expect(picked.isUtc, isFalse);
  });
}
