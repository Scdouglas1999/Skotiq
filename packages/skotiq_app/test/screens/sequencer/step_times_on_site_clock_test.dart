// A step's time of day reads on the clock the Sequencer prints run times on
// (Settings > Location timezone), not on this machine's zone, so "End: 22:00"
// on a target and "done ~23:10" on the run band use one zone.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary_line.dart';
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

  test('a time picked on the site clock is that time at the site', () {
    final picked = site.nextTimeOfDay(
      22,
      0,
      now: DateTime.utc(2026, 11, 26, 6),
    );
    expect(picked.isAtSameMomentAs(DateTime.utc(2026, 11, 26, 8, 15)), isTrue);
  });
}
