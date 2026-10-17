// One minimum altitude per site.
//
// Plan Tonight > Schedule > Scoring weights showed "Min altitude 25.00°" and
// the decision panel rejected with "below site minimum 25.0°", while "Review in
// Sequencer" on the same screen refused with "no usable imaging window ... at
// min altitude 30°" and the altitude charts drew their threshold at 30. A
// target at 27° was therefore eligible for the autopilot and un-sequenceable at
// the same time. The scheduler's configured minimum is now the authority
// (siteMinimumAltitudeDegProvider) and the builder reads it instead of the
// SmartNightSettings default.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show TargetVisibilityInfo;
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _ConfiguredSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

class _FakeGoalService extends Mock implements IntegrationGoalService {}

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'OSC',
  focalLength: 250,
  aperture: 51,
  cameraName: 'ZWO ASI2600MC Pro',
);

const _exposureContext = SmartNightExposureContext(
  camera: CameraExposureSpec(readNoiseE: 1.5, fullWellE: 51000, qePeak: 0.91),
  bortleClass: 5,
  focalLengthMm: 250,
  apertureMm: 51,
  pixelSizeMicrons: 3.76,
  userCapSeconds: 300,
  floorSeconds: 10,
);

TargetSuggestion _suggestion() {
  return TargetSuggestion(
    targetId: 42,
    targetName: 'M31',
    raHours: 0.712,
    decDegrees: 41.2,
    totalScore: 82,
    objectType: 'Galaxy',
    visibility: TargetVisibilityInfo(
      currentAltitude: 55,
      currentAzimuth: 90,
      airmass: 1.2,
      peakAltitude: 70,
      // Circumpolar on purpose (no crossings): the usable-window helper
      // treats a target with neither rise nor set as up for the whole dark
      // window, which is the semantics this test needs WITHOUT depending on
      // when the suite runs. Concrete now()-relative crossings made the
      // test time-of-day-flaky: the sidereal projection collapses an
      // impossible 48h "up period" (or the original now+12h one, run
      // mid-morning) to minutes of overlap → "no usable imaging window".
      riseTime: null,
      setTime: null,
      moonDistance: 90,
      hoursAboveMinAlt: 6,
    ),
  );
}

List<Override> _overrides({double? siteMinAltitude}) {
  final goals = _FakeGoalService();
  when(() => goals.progressForTarget(any())).thenAnswer((_) async => const []);
  return [
    inMemoryDatabaseOverride(),
    appSettingsProvider.overrideWith(_ConfiguredSettingsNotifier.new),
    activeEquipmentProfileProvider.overrideWithValue(_profile),
    effectiveFiltersProvider.overrideWithValue(const <String>[]),
    smartNightExposureContextProvider.overrideWith(
      (ref) async => _exposureContext,
    ),
    integrationGoalServiceProvider.overrideWithValue(goals),
    if (siteMinAltitude != null)
      // Override the DURABLE scheduler row, not the derived provider, so the
      // test covers the whole chain the operator's slider actually writes.
      schedulerPersistedConfigProvider.overrideWith(
        (ref) => SchedulerConfig.defaults.copyWith(
          minAltitudeDegrees: siteMinAltitude,
        ),
      ),
  ];
}

Future<T> _withRef<T>(
  WidgetTester tester,
  List<Override> overrides,
  Future<T> Function(WidgetRef ref) body,
) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return body(captured);
}

TargetHeaderNode _header(SingleTargetSequenceResult result) {
  return result.sequence.nodes.values.whereType<TargetHeaderNode>().single;
}

void main() {
  testWidgets('the built sequence gates on the SITE minimum altitude', (
    tester,
  ) async {
    final result = await _withRef(
      tester,
      _overrides(siteMinAltitude: 42),
      (ref) => buildPlanTonightTargetSequenceFromSuggestion(
        ref: ref,
        target: _suggestion(),
      ),
    );

    final header = _header(result);
    expect(
      header.minAltitude,
      42,
      reason: 'the operator set 42 deg on the scheduler; the builder must not '
          'substitute its own default',
    );
    final start = (header.startWhen as AndTrigger).children;
    final end = (header.endWhen as OrTrigger).children;
    expect(start.whereType<AltitudeAboveTrigger>().single.altitudeDeg, 42);
    expect(end.whereType<AltitudeBelowTrigger>().single.altitudeDeg, 42);
    expect(start.whereType<TimeAfterTrigger>().single.unixSeconds,
        header.startAfter!.millisecondsSinceEpoch ~/ 1000);
    expect(end.whereType<TimeAfterTrigger>().single.unixSeconds,
        header.endBefore!.millisecondsSinceEpoch ~/ 1000);
  });

  testWidgets('with no scheduler row saved, builder and scheduler agree', (
    tester,
  ) async {
    final result = await _withRef(
      tester,
      _overrides(),
      (ref) => buildPlanTonightTargetSequenceFromSuggestion(
        ref: ref,
        target: _suggestion(),
      ),
    );

    expect(
      _header(result).minAltitude,
      SchedulerConfig.defaults.minAltitudeDegrees,
      reason: 'the default the scheduler enforces IS the default the builder '
          'plans against',
    );
  });
}
