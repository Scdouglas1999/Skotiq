// The TargetScheduler step's Live ranking preview ranks with the app's one
// target scorer, held to the floor the step will use: the step's own horizon,
// else the site's altitude floor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_scheduler_properties.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiFloorSample,
        ApiNightScore,
        ApiNightSky,
        ApiNightTarget,
        ApiSchedulerTarget,
        ApiScoringWeights,
        ApiTargetScoreNow;
import 'package:skotiq_core/backend.dart' show TargetScoring;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A scorer that records the floor it is given and holds the first target
/// below it.
class _FloorRecordingScoring implements TargetScoring {
  List<ApiFloorSample>? floor;

  @override
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) async {
    this.floor = floor;
    return [
      for (final (i, t) in targets.indexed)
        ApiTargetScoreNow(
          targetId: t.id,
          totalScore: 60,
          altitudeScore: 0,
          moonDistanceScore: 0,
          transitProximityScore: 0,
          darknessScore: 0,
          airmassScore: 0,
          altitudeDeg: 20,
          azimuthDeg: 90,
          airmass: 2.9,
          moonDistanceDeg: 80,
          runnable: i != 0,
          skipReason: i == 0
              ? 'altitude 20.0° below the altitude floor (35.0° at azimuth 90°)'
              : null,
        ),
    ];
  }

  @override
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) async =>
      const [];
}

void main() {
  testWidgets(
      'the preview is held to the site floor and says why a target '
      'would not run', (tester) async {
    final scoring = _FloorRecordingScoring();
    final behindTrees = TargetHeaderNode(
      targetName: 'East field',
      raHours: 12,
      decDegrees: 10,
    );
    final open = TargetHeaderNode(
      targetName: 'West field',
      raHours: 3,
      decDegrees: 10,
    );
    final scheduler = TargetSchedulerNode(
      childIds: [behindTrees.id, open.id],
    );
    final editor = CurrentSequenceNotifier()
      ..loadSequence(
        Sequence.create(
          name: 'Plan',
          nodes: {
            scheduler.id: scheduler,
            behindTrees.id: behindTrees,
            open.id: open,
          },
          rootNodeId: scheduler.id,
        ),
      );
    const floor = AltitudeFloor(horizon: null, minimumDeg: 35);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          currentSequenceProvider.overrideWith((ref) => editor),
          appObserverLocationProvider.overrideWithValue(
            const LocationSettings(latitude: 40, longitude: -74),
          ),
          altitudeFloorProvider.overrideWithValue(floor),
          targetScorerProvider.overrideWithValue(TargetScorer(scoring)),
          tickerProvider.overrideWith(
            (ref, cadence) => Stream.value(DateTime.utc(2026, 1, 15, 6)),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TargetSchedulerProperties(
                colors: SkotiqColors.dark,
                node: scheduler,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final samples = floor.asSamples();
    expect(scoring.floor!.map((s) => (s.azimuthDeg, s.altitudeDeg)), [
      for (var i = 0; i < samples.azimuths.length; i++)
        (samples.azimuths[i], samples.altitudes[i]),
    ]);
    expect(find.text('East field'), findsOneWidget);
    expect(
      find.textContaining('Will not run now: altitude 20.0° below'),
      findsOneWidget,
    );
  });
}
