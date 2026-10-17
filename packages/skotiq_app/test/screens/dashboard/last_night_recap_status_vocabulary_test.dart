// The Dashboard's "Last night" card must not print the raw state-machine token
// — "New Sequence / Paused-stopped · 1 hour ago". It shares the run-status
// vocabulary the History chips and the Session Report title ("Stopped
// (resumable)") use; a private status→copy mapping whose default arm just
// capitalises the token is a second implementation of one label, and it is the
// one on screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/last_night_recap_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _app(List<SequenceRun> runs) => ProviderScope(
      overrides: [
        sequenceRunsProvider.overrideWith((ref) => Stream.value(runs)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: const LastNightRecapCard(colors: SkotiqColors.dark),
        ),
      ),
    );

SequenceRun _run(String status) => SequenceRun(
      id: 1,
      sequenceName: 'New Sequence',
      startedAt: DateTime.now().subtract(const Duration(hours: 1)),
      endedAt: DateTime.now(),
      status: status,
      statsJson: '',
    );

void main() {
  testWidgets('a stopped run is not reported as "Paused-stopped"',
      (tester) async {
    await tester.pumpWidget(_app([_run('paused-stopped')]));
    await tester.pump();

    expect(find.textContaining('Paused-stopped'), findsNothing);
    expect(find.textContaining('Stopped (resumable)'), findsOneWidget);
  });

  testWidgets('an unmapped status still degrades to something readable',
      (tester) async {
    await tester.pumpWidget(_app([_run('cleanup_failed')]));
    await tester.pump();

    expect(find.textContaining('Cleanup failed'), findsOneWidget);
  });
}
