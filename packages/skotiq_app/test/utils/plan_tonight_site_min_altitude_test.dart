// A target built from Plan Tonight is planned against the site's altitude
// floor (`altitudeFloorProvider`): the horizon when one is set, otherwise the
// minimum altitude. The step carries no altitude of its own; the run holds
// every target to the floor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show TargetVisibilityInfo;
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

/// A target 1 degree from the pole: from latitude 40 it stands between 39
/// and 41 degrees up, due north, at every hour of every night.
TargetSuggestion _suggestion() {
  return TargetSuggestion(
    targetId: 42,
    targetName: 'Polar field',
    raHours: 0.712,
    decDegrees: 89,
    totalScore: 82,
    objectType: 'Galaxy',
    visibility: TargetVisibilityInfo(
      currentAltitude: 40,
      currentAzimuth: 0,
      airmass: 1.5,
      peakAltitude: 41,
      moonDistance: 90,
      hoursAboveMinAlt: 6,
    ),
  );
}

List<Override> _overrides({double? siteMinAltitude, String? horizonJson}) {
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
    if (horizonJson != null)
      horizonProfileProvider.overrideWithValue(
        SiteHorizonProfile.fromJson(horizonJson),
      ),
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
  Future<SingleTargetSequenceResult> build(
    WidgetTester tester,
    List<Override> overrides,
  ) => _withRef(
        tester,
        overrides,
        (ref) => buildPlanTonightTargetSequenceFromSuggestion(
          ref: ref,
          target: _suggestion(),
        ),
      );

  testWidgets('the built step names no altitude: the run holds it to the '
      'site floor', (tester) async {
    final header = _header(await build(tester, _overrides()));
    expect(header.minAltitude, isNull);
    expect(header.startWhen, isNull);
    expect(header.endWhen, isNull);
    expect(header.startAfter, isNotNull);
    expect(header.endBefore, isNotNull);
  });

  testWidgets('with no horizon the minimum altitude decides', (tester) async {
    // 30 degrees is below where the field stands; 45 is above it.
    await build(tester, _overrides(siteMinAltitude: 30));
    await expectLater(
      build(tester, _overrides(siteMinAltitude: 45)),
      throwsA(isA<SmartNightBuildException>()),
    );
  });

  testWidgets('a horizon replaces the minimum, direction by direction', (
    tester,
  ) async {
    // Trees to 60 degrees in the north hide the field, whatever the minimum.
    await expectLater(
      build(
        tester,
        _overrides(siteMinAltitude: 10, horizonJson: '{"N":60,"NW":60,"NE":60}'),
      ),
      throwsA(isA<SmartNightBuildException>()),
    );
    // Trees in the south do not, and a minimum of 45 no longer applies.
    await build(
      tester,
      _overrides(siteMinAltitude: 45, horizonJson: '{"S":60}'),
    );
  });
}
