import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/focuser_backlash_progress.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/focuser_backlash_calibration_provider.dart';
import 'package:skotiq_core/src/providers/focuser_backlash_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

import '../harness/in_memory_database.dart';
import 'fixtures.dart';

class CalibrationBackend extends DisconnectedBackend {
  CalibrationBackend({this.outcomeJson, this.error, this.planJson});

  final String? outcomeJson;
  final Object? error;
  final String? planJson;

  final events = StreamController<SkotiqEvent>.broadcast();
  final started = Completer<void>();
  String? lastConfigJson;
  int cancelCalls = 0;
  int? lastPlanCentre;

  /// Held until a test releases it, so progress frames can be delivered while
  /// the run is still in flight.
  final release = Completer<void>();

  @override
  Stream<SkotiqEvent> get eventStream => events.stream;

  @override
  Future<String> focuserBacklashCalibrationStart({
    required String deviceId,
    required String cameraId,
    required String configJson,
  }) async {
    lastConfigJson = configJson;
    if (!started.isCompleted) started.complete();
    await release.future;
    if (error != null) throw error!;
    return outcomeJson!;
  }

  @override
  Future<void> focuserBacklashCalibrationCancel() async {
    cancelCalls++;
  }

  @override
  Future<String> focuserBacklashCalibrationPlan({
    required String configJson,
    required int centerPosition,
  }) async {
    lastPlanCentre = centerPosition;
    return planJson!;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this.settings);

  final AppSettingsState settings;

  @override
  Future<AppSettingsState> build() async => settings;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

ProviderContainer buildContainer(CalibrationBackend backend) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
      appSettingsProvider.overrideWith(
        () => _FixedSettings(const AppSettingsState()),
      ),
      activeEquipmentProfileProvider.overrideWithValue(null),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(backend.events.close);
  return container;
}

void seedConnectedEquipment(ProviderContainer container) {
  container
      .read(cameraStateProvider.notifier)
      .setConnecting('zwo-asi2600mm-1', 'Camera');
  container.read(cameraStateProvider.notifier).setConnected();
  container
      .read(focuserStateProvider.notifier)
      .setConnecting('zwo-eaf-1', 'ZWO EAF');
  container.read(focuserStateProvider.notifier).setConnected();
  container.read(focuserStateProvider.notifier).updatePosition(6600);
}

SkotiqEvent progressEvent(Map<String, dynamic> frame) => SkotiqEvent(
  category: EventCategory.equipment,
  eventType: 'FocuserBacklashCalibrationProgress',
  severity: EventSeverity.info,
  timestamp: DateTime.now().millisecondsSinceEpoch,
  data: {'device_id': 'zwo-eaf-1', 'detail': jsonEncode(frame)},
);

Map<String, dynamic> scanFrame({
  required String phase,
  required int point,
  required List<List<num>> points,
}) => {
  'type': 'focuser_backlash_progress',
  'phase': phase,
  'point': point,
  'total_points': 13,
  'position': points.last[0].toInt(),
  'hfr': points.last[1].toDouble(),
  'star_count': 41,
  'scan_range': {'min': 6440, 'max': 6800},
  'points': [
    for (final p in points) {'position': p[0].toInt(), 'hfr': p[1].toDouble()},
  ],
};

void main() {
  test(
    'a measured run ends complete, with the figure and its evidence',
    () async {
      final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
      final container = buildContainer(backend);
      await container.read(appSettingsProvider.future);
      seedConnectedEquipment(container);
      final notifier = container.read(
        focuserBacklashCalibrationProvider.notifier,
      );

      final run = notifier.run();
      await backend.started.future;
      expect(
        container.read(focuserBacklashCalibrationProvider).isRunning,
        isTrue,
      );
      backend.release.complete();
      await run;

      final state = container.read(focuserBacklashCalibrationProvider);
      expect(state.phase, FocuserBacklashPhase.complete);
      expect(state.progress, 100);
      expect(state.isRunning, isFalse);
      expect(state.errorMessage, isNull);
      expect(state.result!.calibration!.steps, 105);
      expect(state.status, contains('105 steps'));
      expect(state.status, contains('6620'));
      expect(state.isSaved, isFalse);
    },
  );

  test(
    'the centre the operator left the focuser at is what gets sent',
    () async {
      final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
      final container = buildContainer(backend);
      await container.read(appSettingsProvider.future);
      seedConnectedEquipment(container);

      backend.release.complete();
      await container.read(focuserBacklashCalibrationProvider.notifier).run();

      final config =
          jsonDecode(backend.lastConfigJson!) as Map<String, dynamic>;
      // Null means "wherever the focuser is", which is the operator's rough
      // focus — the only place the measurement is worth taking.
      expect(config['center_position'], isNull);
    },
  );

  test('saving writes the record for the focuser it was measured on', () async {
    final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    backend.release.complete();
    await notifier.run();
    await notifier.save();

    expect(container.read(focuserBacklashCalibrationProvider).isSaved, isTrue);
    final stored = await container
        .read(settingsDaoProvider)
        .getFocuserBacklashCalibration('zwo-eaf-1');
    expect(stored!.steps, 105);
    expect(stored.measuredAtPosition, 6620);
    // And nothing was written for any other focuser.
    final all = await container
        .read(settingsDaoProvider)
        .getFocuserBacklashCalibrations();
    expect(all.keys, ['zwo-eaf-1']);
  });

  test('discarding throws the figure away and keeps the plan', () async {
    final backend = CalibrationBackend(
      outcomeJson: measuredOutcomeJson(),
      planJson: jsonEncode({
        'points_per_scan': 13,
        'total_exposures': 52,
        'scan_low_position': 6440,
        'scan_high_position': 6800,
        'travel_low_position': 6040,
        'travel_high_position': 7200,
        'estimated_duration_secs': 330.0,
        'reversal_budget_steps': 760,
        'reversal_budget_at_vertex_steps': 580,
      }),
    );
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    await notifier.loadPlan();
    expect(backend.lastPlanCentre, 6600);
    backend.release.complete();
    await notifier.run();
    notifier.discard();

    final state = container.read(focuserBacklashCalibrationProvider);
    expect(state.result, isNull);
    expect(state.phase, FocuserBacklashPhase.idle);
    expect(state.plan!.totalExposures, 52);
    expect(
      await container
          .read(settingsDaoProvider)
          .getFocuserBacklashCalibration('zwo-eaf-1'),
      isNull,
    );
  });

  test('a refusal is a result, not an error', () async {
    final backend = CalibrationBackend(
      outcomeJson: refusedOutcomeJson(
        refusal: const {
          'code': 'poor_fit',
          'direction': 'from_above',
          'r_squared': 0.41,
          'required': 0.9,
        },
        message:
            'The from above scan fitted R² 0.410, below the 0.900 required '
            'to locate an optimum',
        remedy:
            'Start from rough focus and wait for steadier seeing — the '
            'samples did not trace a focus curve.',
      ),
    );
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    backend.release.complete();
    await notifier.run();

    final state = container.read(focuserBacklashCalibrationProvider);
    expect(state.phase, FocuserBacklashPhase.refused);
    expect(state.errorMessage, isNull);
    expect(state.result!.refusal!.code, 'poor_fit');
    // The operator reads native's own words, not a Dart paraphrase.
    expect(state.status, state.result!.refusal!.message);

    // Nothing to save, and asking does nothing.
    await notifier.save();
    expect(
      await container
          .read(settingsDaoProvider)
          .getFocuserBacklashCalibration('zwo-eaf-1'),
      isNull,
    );
  });

  test('the operator cancelling is not reported as a failure', () async {
    final backend = CalibrationBackend(error: SkotiqError.cancelled());
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    final run = notifier.run();
    await backend.started.future;
    await notifier.cancel();
    expect(backend.cancelCalls, 1);
    backend.release.complete();
    await run;

    final state = container.read(focuserBacklashCalibrationProvider);
    expect(state.phase, FocuserBacklashPhase.idle);
    expect(state.errorMessage, isNull);
    expect(state.result, isNull);
    expect(state.isRunning, isFalse);
    expect(state.status, contains('at your request'));
  });

  test('a run that could not happen is reported as a failure', () async {
    final backend = CalibrationBackend(
      error: StateError('Focuser move rejected by the driver'),
    );
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    backend.release.complete();
    await notifier.run();

    final state = container.read(focuserBacklashCalibrationProvider);
    expect(state.phase, FocuserBacklashPhase.failed);
    expect(state.errorMessage, contains('rejected by the driver'));
    expect(state.result, isNull);
  });

  test('refuses to start with no camera connected', () async {
    final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    container
        .read(focuserStateProvider.notifier)
        .setConnecting('zwo-eaf-1', 'ZWO EAF');
    container.read(focuserStateProvider.notifier).setConnected();
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    await notifier.run();

    final state = container.read(focuserBacklashCalibrationProvider);
    expect(state.phase, FocuserBacklashPhase.failed);
    expect(state.errorMessage, contains('No camera connected'));
  });

  group('progress frames', () {
    test('the two scans build two separate curves', () async {
      final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
      final container = buildContainer(backend);
      await container.read(appSettingsProvider.future);
      seedConnectedEquipment(container);
      final notifier = container.read(
        focuserBacklashCalibrationProvider.notifier,
      );
      final run = notifier.run();
      await backend.started.future;

      backend.events.add(
        progressEvent(
          scanFrame(
            phase: 'from_below',
            point: 2,
            points: [
              [6440, 11.2],
              [6470, 8.9],
            ],
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      var state = container.read(focuserBacklashCalibrationProvider);
      expect(state.phase, FocuserBacklashPhase.scanningFromBelow);
      expect(state.belowPoints.map((p) => p.position), [6440, 6470]);
      expect(state.abovePoints, isEmpty);
      expect(state.currentPoint, 2);
      expect(state.totalPoints, 13);
      expect(state.scanRange!.min, 6440);
      expect(state.progress, greaterThan(0));
      expect(state.progress, lessThan(50));
      expect(state.status, contains('from below'));

      backend.events.add(
        progressEvent(
          scanFrame(
            phase: 'from_above',
            point: 1,
            points: [
              [6800, 11.0],
            ],
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(focuserBacklashCalibrationProvider);
      expect(state.phase, FocuserBacklashPhase.scanningFromAbove);
      // The from-below curve is still there to compare against; the second
      // scan starts its own list rather than appending to the first.
      expect(state.belowPoints.map((p) => p.position), [6440, 6470]);
      expect(state.abovePoints.map((p) => p.position), [6800]);
      expect(state.progress, greaterThan(48));
      expect(state.status, contains('from above'));

      backend.events.add(
        progressEvent(const {
          'type': 'focuser_backlash_progress',
          'phase': 'analysing',
        }),
      );
      await Future<void>.delayed(Duration.zero);

      state = container.read(focuserBacklashCalibrationProvider);
      expect(state.phase, FocuserBacklashPhase.analysing);
      expect(state.progress, 96);
      expect(state.isRunning, isTrue);
      // The analysing frame carries no points, and must not erase either curve.
      expect(state.belowPoints, hasLength(2));
      expect(state.abovePoints, hasLength(1));

      backend.release.complete();
      await run;
    });

    test('the terminal result frame settles the run on its own', () async {
      final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
      final container = buildContainer(backend);
      await container.read(appSettingsProvider.future);
      seedConnectedEquipment(container);
      final notifier = container.read(
        focuserBacklashCalibrationProvider.notifier,
      );
      final run = notifier.run();
      await backend.started.future;

      backend.events.add(
        progressEvent({
          'type': 'focuser_backlash_result',
          'result': jsonDecode(measuredOutcomeJson()),
        }),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(focuserBacklashCalibrationProvider).phase,
        FocuserBacklashPhase.complete,
      );
      expect(
        container
            .read(focuserBacklashCalibrationProvider)
            .result!
            .calibration!
            .steps,
        105,
      );

      // The run's own return value then lands on the same outcome, and must
      // not restate it as a second result.
      backend.release.complete();
      await run;
      expect(
        container.read(focuserBacklashCalibrationProvider).phase,
        FocuserBacklashPhase.complete,
      );
    });

    test('an unrelated equipment event is ignored', () async {
      final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
      final container = buildContainer(backend);
      await container.read(appSettingsProvider.future);
      seedConnectedEquipment(container);
      final notifier = container.read(
        focuserBacklashCalibrationProvider.notifier,
      );
      final run = notifier.run();
      await backend.started.future;

      backend.events.add(
        SkotiqEvent(
          category: EventCategory.equipment,
          eventType: 'AutofocusProgress',
          severity: EventSeverity.info,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          data: const {'detail': '{"type":"autofocus_progress","point":1}'},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(focuserBacklashCalibrationProvider).phase,
        FocuserBacklashPhase.scanningFromBelow,
      );
      expect(
        container.read(focuserBacklashCalibrationProvider).belowPoints,
        isEmpty,
      );

      backend.release.complete();
      await run;
    });
  });

  test('a measured run then feeds the wire and the resolver', () async {
    final backend = CalibrationBackend(outcomeJson: measuredOutcomeJson());
    final container = buildContainer(backend);
    await container.read(appSettingsProvider.future);
    seedConnectedEquipment(container);
    final notifier = container.read(
      focuserBacklashCalibrationProvider.notifier,
    );

    backend.release.complete();
    await notifier.run();
    await notifier.save();
    await container.read(savedFocuserBacklashProvider.future);

    expect(container.read(measuredFocuserBacklashStepsProvider), 105);
    expect(
      container.read(effectiveFocuserBacklashProvider).origin,
      FocuserBacklashOrigin.measured,
    );
    expect(container.read(effectiveFocuserBacklashProvider).steps, 105);
  });
}
