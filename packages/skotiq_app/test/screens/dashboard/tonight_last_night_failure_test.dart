// The dashboard's "Last night" panel must name the fault that ended a failed
// run, not the step the teardown cancelled after it.
//
// The saved run record keeps the whole error cascade in the order it happened,
// so its LAST entry is usually the cancelled teardown step ("Change Filter:
// Operation cancelled" on 2026-09-14). The cause is filed separately as
// `terminalCause`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/tonight/tonight_side_panels.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

const _rejectStorm =
    'Image grading: 3 consecutive rejects (limit 3). Sequence paused for '
    'inspection.';
const _teardown = 'Change Filter: Operation cancelled';

SequenceRun _failedRun(String statsJson) => SequenceRun(
      id: 1,
      sequenceName: 'Night',
      startedAt: DateTime.now().subtract(const Duration(hours: 2)),
      endedAt: DateTime.now().subtract(const Duration(hours: 1)),
      status: 'failed',
      statsJson: statsJson,
    );

Future<void> _pump(WidgetTester tester, SequenceRun run) async {
  await pumpAppScreen(
    tester,
    const Scaffold(body: TonightLastNightPanel()),
    size: const Size(600, 400),
    extraOverrides: [
      sequenceRunsProvider.overrideWith((ref) => Stream.value([run])),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a failed run shows its cause, not the cancelled teardown',
      (tester) async {
    final stats = SequenceRunStats()
      ..recordError(_rejectStorm)
      ..recordError(_teardown)
      ..recordTerminalError(_rejectStorm);

    await _pump(tester, _failedRun(stats.toJson()));

    expect(
      find.textContaining(_rejectStorm),
      findsOneWidget,
      reason: 'the morning panel must say why the run ended',
    );
    expect(find.textContaining(_teardown), findsNothing);
  });

  testWidgets('a run recorded without a cause still shows its last error',
      (tester) async {
    final stats = SequenceRunStats()..recordError('Slew failed: limit');

    await _pump(tester, _failedRun(stats.toJson()));

    expect(find.textContaining('Slew failed: limit'), findsOneWidget);
  });
}
