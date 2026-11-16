// The run's finish time is on the app's clock, like every other time the app
// shows: the operator's time zone, and a clock a test or replay can fix.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/sequence_progress_bar.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _StoppedClock implements Clock {
  const _StoppedClock(this.at);

  final DateTime at;

  @override
  DateTime now() => at;

  @override
  DateTime nowUtc() => at.toUtc();

  @override
  Duration get utcOffset => at.timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

void main() {
  testWidgets('the finish time is the app clock plus what remains',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clockProvider.overrideWithValue(
            _StoppedClock(DateTime(2026, 11, 15, 23, 47, 12)),
          ),
          runRecordProvider.overrideWith(
            (ref) => RunRecordNotifier(
              ref,
              const RunRecord(
                lifecycle: SequenceExecutionState.running,
                progress: SequenceProgress(
                  state: SequenceExecutionState.running,
                  currentNodeId: 'lrgb',
                  currentNodeName: 'LRGB',
                  totalExposures: 760,
                  completedExposures: 359,
                  estimatedRemainingSecs: 3600,
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (ctx) => Scaffold(
              body: SequenceProgressBar(colors: SkotiqColors.of(ctx)),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.textContaining('done ~00:47:12'), findsOneWidget);
  });
}
