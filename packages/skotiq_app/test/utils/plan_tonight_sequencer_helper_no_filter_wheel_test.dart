import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_app/widgets/auto_build_options_dialog.dart';
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

class _SlotlessConnectedWheel extends FilterWheelStateNotifier {
  _SlotlessConnectedWheel(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'filter-wheel-1',
      deviceName: 'Test Wheel',
    );
  }
}

const _oscProfile = EquipmentProfileModel(
  id: 1,
  name: 'OSC, no filter wheel',
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

List<Override> _overrides(
    {bool wheelConnected = false, List<String> filters = const []}) {
  final goals = _FakeGoalService();
  when(() => goals.progressForTarget(any())).thenAnswer((_) async => const []);
  return [
    inMemoryDatabaseOverride(),
    appSettingsProvider.overrideWith(_ConfiguredSettingsNotifier.new),
    activeEquipmentProfileProvider.overrideWithValue(_oscProfile),
    effectiveFiltersProvider.overrideWithValue(filters),
    if (wheelConnected)
      filterWheelStateProvider.overrideWith(_SlotlessConnectedWheel.new),
    smartNightExposureContextProvider.overrideWith(
      (ref) async => _exposureContext,
    ),
    integrationGoalServiceProvider.overrideWithValue(goals),
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

void main() {
  testWidgets(
      'framing retains emission subtype and dragged coordinates through generation',
      (tester) async {
    final result = await _withRef(
        tester,
        _overrides(filters: ['L', 'R', 'G', 'B', 'Ha', 'SII', 'OIII']),
        (ref) => buildPlanTonightTargetSequenceFromFraming(
              ref: ref,
              target: const FramingTarget(
                  name: 'NGC7380',
                  raHours: 22.8,
                  decDegrees: 58.2,
                  type: TargetType.nebula),
              sourceSuggestion: _suggestion().copyWith(
                  targetName: 'NGC7380', objectType: 'Emission Nebula'),
              rotationDegrees: 37,
            ));
    expect(result.strategy, SmartNightStrategy.narrowbandSho);
    final header =
        result.sequence.nodes.values.whereType<TargetHeaderNode>().single;
    expect(header.raHours, 22.8);
    expect(header.decDegrees, 58.2);
    expect(header.rotation, 37);
  });

  testWidgets('nautical-dawn recipe reaches the target and capture block',
      (tester) async {
    final result = await _withRef(
        tester,
        _overrides(),
        (ref) => buildPlanTonightTargetSequenceFromSuggestion(
            ref: ref,
            target: _suggestion(),
            options: const AutoBuildOptions(
                strategy: SmartNightStrategy.oscOneShot,
                end: AutoBuildEnd.nautical,
                gain: 139,
                offset: 21,
                exposures: {'': 180})));
    final nodes = result.sequence.nodes.values;
    final header = nodes.whereType<TargetHeaderNode>().single;
    final window = SmartNightService(
            suggestionService:
                TargetSuggestionService(loggingService: LoggingService()),
            logging: LoggingService())
        .calculateWindow(latitudeDeg: 40, longitudeDeg: -75);
    expect(header.endBefore, window.twilight.nauticalDawn);
    expect(nodes.whereType<LoopNode>().single.repeatUntil, header.endBefore);
    final exposure = nodes.whereType<ExposureNode>().single;
    expect(exposure.durationSecs, 180);
    expect(exposure.gain, 139);
    expect(exposure.offset, 21);
    expect(nodes.whereType<WarmCameraNode>(), hasLength(1));
    expect(nodes.whereType<ParkNode>(), hasLength(1));
  });

  testWidgets('Plan Tonight builds a sequence on a rig with no filter wheel', (
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

    expect(result.filterPlans, hasLength(1));
    expect(result.filterPlans.single.filterName, isEmpty);

    final nodes = result.sequence.nodes.values;
    expect(nodes.whereType<FilterChangeNode>(), isEmpty);
    expect(nodes.whereType<SmartExposureNode>(), isEmpty);

    final lights = nodes
        .whereType<ExposureNode>()
        .where((n) => n.frameType == FrameType.light)
        .toList();
    expect(lights, hasLength(1));
    expect(lights.single.filter, isNull);
    expect(lights.single.filterIndex, isNull);
    expect(lights.single.count, greaterThan(0));
  });

  testWidgets('summary names the unfiltered plan instead of an empty label', (
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

    expect(planTonightSequenceSummary(result), startsWith('no filter ('));
  });

  testWidgets('a connected wheel reporting no slots still fails loud', (
    tester,
  ) async {
    await _withRef(
      tester,
      _overrides(wheelConnected: true),
      (ref) async {
        await expectLater(
          buildPlanTonightTargetSequenceFromSuggestion(
            ref: ref,
            target: _suggestion(),
          ),
          throwsA(
            isA<SmartNightBuildException>().having(
              (e) => e.message,
              'message',
              contains('reports no filter slots'),
            ),
          ),
        );
      },
    );
  });
}
