// The headless `POST /api/sequencer/load` -> `POST /api/sequencer/start` path
// must seed the executor's RuntimeConfig from the operator's settings, like
// every other launch path.
//
// Measured against the release bundle (2026-08-17): `image_grading_enabled` =
// true and `image_grading_star_count_min` = 100000 persisted in `app_settings`
// AND read back through `GET /api/settings`, and a sim night driven through
// load -> start still accepted twelve of twelve 43-star frames, graded them
// all `pass`, left `Reject/` empty and never logged a single
// `Updating sequencer default_quality_check` line. Pushing the identical
// thresholds by hand through `POST /api/sequencer/update-default-quality-check`
// on the SAME live process rejected all twelve on the next run — so the
// thresholds worked, and nothing was sending them.
//
// The bare path does not call `SequenceExecutor.start()`, and the seed lived
// only inside it. These tests pin the shared entry point that replaced the
// divergence: what it pushes, and that both launch paths push the same thing.
//
// The last group pins the other half of the same night's honesty — a target
// dropped by its own `end_when` states its reason on the run record instead of
// only in the Rust log.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so the whole seed runs end to end without stubbing every push.
class _PermissiveBackend extends MockBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final result = super.noSuchMethod(invocation);
    return result ?? Future<void>.value();
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettingsNotifier extends AppSettingsNotifier {
  _FixedSettingsNotifier(this._value);
  final AppSettingsState _value;

  @override
  Future<AppSettingsState> build() async => _value;
}

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    setConnecting('simulator:camera-1', 'Test Camera');
    setConnected();
  }
}

SequenceValidatorService _passingValidator(Ref ref) => SequenceValidatorService(
  ref: ref,
  syncRules: const [],
  refAwareRules: const [],
  asyncRules: const [],
);

Sequence _buildSequence() {
  final root = InstructionSetNode(id: 'root', name: 'Sequence');
  return Sequence.create(
    name: 'runtime config',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

/// The operator has switched grading on and set a floor no frame this rig
/// produces can clear. Nothing about this is ambiguous, and it is exactly the
/// configuration the appliance ignored.
const _gradingOn = AppSettingsState(
  enableImageGrading: true,
  imageGradingStarCountMin: 100000,
  imageGradingMaxConsecutiveRejects: 9999,
  imageGradingHfrThresholdPx: 4.25,
  imageGradingRejectFolderPath: '/captures/rejects',
);

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late List<Map<Symbol, Object?>> pushedQualityChecks;
  late List<String?> pushedRejectFolders;
  ProviderContainer? container;

  ProviderContainer buildContainer({AppSettingsState? settings}) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sequenceValidatorProvider.overrideWith(_passingValidator),
        cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        if (settings != null)
          appSettingsProvider.overrideWith(
            () => _FixedSettingsNotifier(settings),
          ),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    pushedQualityChecks = [];
    pushedRejectFolders = [];
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    when(
      () => backend.sequencerSetActiveSequenceRunId(any()),
    ).thenAnswer((_) async {});
    when(
      () => backend.sequencerUpdateDefaultQualityCheck(
        hfrThreshold: any(named: 'hfrThreshold'),
        hfrBaselinePercent: any(named: 'hfrBaselinePercent'),
        eccentricityThreshold: any(named: 'eccentricityThreshold'),
        starCountMin: any(named: 'starCountMin'),
        maxConsecutiveRejects: any(named: 'maxConsecutiveRejects'),
        enabled: any(named: 'enabled'),
      ),
    ).thenAnswer((inv) async {
      pushedQualityChecks.add(inv.namedArguments);
    });
    when(() => backend.sequencerUpdateRejectFolderPath(any())).thenAnswer((
      inv,
    ) async {
      pushedRejectFolders.add(inv.positionalArguments.first as String?);
    });
    // `stop()` waits for the authoritative terminal event, so the fake
    // executor has to send one back or the test hangs on teardown.
    when(() => backend.sequencerStop(origin: any(named: 'origin'))).thenAnswer((
      _,
    ) async {
      scheduleMicrotask(() {
        if (!eventController.isClosed) {
          eventController.add(
            bridge_event.SkotiqEvent(
              timestamp: DateTime.now().millisecondsSinceEpoch,
              severity: bridge_event.EventSeverity.info,
              category: bridge_event.EventCategory.sequencer,
              eventType: 'Stopped',
              data: const {},
            ),
          );
        }
      });
    });
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    container?.dispose();
    if (!eventController.isClosed) {
      await eventController.close();
    }
    await db.close();
  });

  group('A. the headless start path seeds the runtime config', () {
    test('the operator grading thresholds reach the executor', () async {
      final c = buildContainer(settings: _gradingOn);
      final executor = c.read(sequenceExecutorProvider);

      await executor.seedRuntimeConfigForNativeStart();

      expect(
        pushedQualityChecks,
        hasLength(1),
        reason:
            'the bare load->start path pushed nothing at all, so grading was '
            'inert on every headless night',
      );
      final pushed = pushedQualityChecks.single;
      expect(pushed[#enabled], isTrue);
      expect(pushed[#starCountMin], 100000);
      expect(pushed[#maxConsecutiveRejects], 9999);
      expect(pushed[#hfrThreshold], 4.25);
      expect(pushedRejectFolders, ['/captures/rejects']);
    });

    test('grading switched OFF is pushed as OFF, not left unsaid', () async {
      final c = buildContainer(
        settings: const AppSettingsState(enableImageGrading: false),
      );
      final executor = c.read(sequenceExecutorProvider);

      await executor.seedRuntimeConfigForNativeStart();

      expect(pushedQualityChecks, hasLength(1));
      expect(
        pushedQualityChecks.single[#enabled],
        isFalse,
        reason:
            'a previous run may have left grading armed in the executor; the '
            'seed states the operator setting either way',
      );
    });

    test(
      'a failed push refuses the launch instead of running on defaults',
      () async {
        when(
          () => backend.sequencerUpdateDefaultQualityCheck(
            hfrThreshold: any(named: 'hfrThreshold'),
            hfrBaselinePercent: any(named: 'hfrBaselinePercent'),
            eccentricityThreshold: any(named: 'eccentricityThreshold'),
            starCountMin: any(named: 'starCountMin'),
            maxConsecutiveRejects: any(named: 'maxConsecutiveRejects'),
            enabled: any(named: 'enabled'),
          ),
        ).thenThrow(StateError('executor rejected the quality check'));
        final c = buildContainer(settings: _gradingOn);
        final executor = c.read(sequenceExecutorProvider);

        await expectLater(
          executor.seedRuntimeConfigForNativeStart(),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('A2. saved sequencer defaults reach a cold start', () {
    // Found by the simulator soak (tools/harness/sim_night_soak): a headless
    // start pushed dither 5 px / settle 30 s / timeout 120 s and autofocus
    // every 25 frames -- the library defaults -- with the operator's 3 px /
    // 3 s / 30 s and every-60-frames saved in app_settings. The seed read
    // `sequencerDefaultsProvider` synchronously, and on a start that is the
    // provider's first read its load from the database has not run yet.
    test(
      'the saved dither and autofocus cadence are pushed, not the defaults',
      () async {
        await db.settingsDao.setSettings({
          'sequencer_autofocus_interval_frames': '60',
          'sequencer_dither_pixels': '3.0',
          'sequencer_dither_settle_pixels': '1.5',
          'sequencer_dither_settle_time': '3.0',
          'sequencer_dither_settle_timeout': '30.0',
        });
        final pushedIntervals = <int>[];
        final pushedDither = <Map<Symbol, Object?>>[];
        when(() => backend.sequencerUpdateAutofocusInterval(any())).thenAnswer((
          inv,
        ) async {
          pushedIntervals.add(inv.positionalArguments.first as int);
        });
        when(
          () => backend.sequencerUpdateDitherConfig(
            pixels: any(named: 'pixels'),
            settlePixels: any(named: 'settlePixels'),
            settleTime: any(named: 'settleTime'),
            settleTimeout: any(named: 'settleTimeout'),
            raOnly: any(named: 'raOnly'),
          ),
        ).thenAnswer((inv) async {
          pushedDither.add(inv.namedArguments);
        });
        final c = buildContainer(
          settings: _gradingOn.copyWith(
            settleThreshold: 0.8,
            settleTime: 7,
            settleTimeout: 40,
          ),
        );
        final executor = c.read(sequenceExecutorProvider);

        await executor.seedRuntimeConfigForNativeStart();

        expect(pushedIntervals, [60]);
        expect(pushedDither, hasLength(1));
        expect(pushedDither.single[#pixels], 3.0);
        // The guider settle settings are the run's one settle bar, for
        // dithers as for the guiding restarts after autofocus and a flip.
        expect(pushedDither.single[#settlePixels], 0.8);
        expect(pushedDither.single[#settleTime], 7.0);
        expect(pushedDither.single[#settleTimeout], 40.0);
      },
    );
  });

  group('B. both launch paths seed identically', () {
    test(
      'start() pushes the same quality check the native seed does',
      () async {
        final c = buildContainer(settings: _gradingOn);
        c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
        final executor = c.read(sequenceExecutorProvider);

        await executor.start();
        final viaStart = List<Map<Symbol, Object?>>.from(pushedQualityChecks);
        await executor.stop();
        pushedQualityChecks.clear();

        await executor.seedRuntimeConfigForNativeStart();

        expect(viaStart, hasLength(1));
        expect(
          pushedQualityChecks.single,
          viaStart.single,
          reason:
              'one seed site, so a field added for the editor path cannot go '
              'missing on the headless one',
        );
      },
    );
  });

  group('C. a target dropped by its end_when says so on the run record', () {
    /// What the headless start handler does for a natively-loaded sequence.
    Future<void> startNativeRun(SequenceExecutor executor) async {
      await executor.openRunRecordsForNativeStart(sequenceName: 'end_when');
      await executor.attachHostListenersForNativeRun();
    }

    void emitTriggerFired({
      required String triggerId,
      required String triggerName,
      required String action,
    }) {
      eventController.add(
        bridge_event.SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: bridge_event.EventSeverity.info,
          category: bridge_event.EventCategory.sequencer,
          eventType: 'TriggerFired',
          data: {
            'trigger_id': triggerId,
            'trigger_name': triggerName,
            'action': action,
          },
        ),
      );
    }

    test(
      'the skip lands in the run warnings, naming target and condition',
      () async {
        final c = buildContainer(settings: const AppSettingsState());
        final executor = c.read(sequenceExecutorProvider);
        await startNativeRun(executor);

        emitTriggerFired(
          triggerId: kTargetEndWhenTriggerId,
          triggerName:
              'The end condition on "Dusk Field" (time ≥ 2026-08-17 12:38 UTC)',
          action: kTargetEndWhenSkipAction,
        );
        await Future<void>.delayed(Duration.zero);

        final stats = c.read(liveSequenceStatsProvider);
        expect(stats, isNotNull);
        expect(stats!.warningMessages, hasLength(1));
        expect(stats.warningMessages.single, contains('Dusk Field'));
        expect(
          stats.warningMessages.single,
          contains('2026-08-17 12:38 UTC'),
          reason: 'the operator has to be able to see WHEN the window closed',
        );
        expect(
          stats.warningMessages.single,
          contains('no frames were captured'),
        );
        expect(
          stats.errorMessages,
          isEmpty,
          reason:
              'the target was skipped exactly as configured; calling it an error '
              'would push the phone a failure for a healthy night',
        );
        expect(
          c.read(sequenceExecutionStateProvider),
          isNot(SequenceExecutionState.recovering),
          reason: 'nothing is being recovered from',
        );
        expect(stats.triggerFires, 1);
      },
    );

    test('a re-entered target does not stack duplicate warnings', () async {
      final c = buildContainer(settings: const AppSettingsState());
      final executor = c.read(sequenceExecutorProvider);
      await startNativeRun(executor);

      for (var i = 0; i < 3; i++) {
        emitTriggerFired(
          triggerId: kTargetEndWhenTriggerId,
          triggerName: 'The end condition on "Dusk Field" (time ≥ noon)',
          action: kTargetEndWhenSkipAction,
        );
        await Future<void>.delayed(Duration.zero);
      }

      expect(c.read(liveSequenceStatsProvider)!.warningMessages, hasLength(1));
    });

    test(
      'a run that skipped its target and imaged nothing is not completed',
      () async {
        final c = buildContainer(settings: const AppSettingsState());
        final executor = c.read(sequenceExecutorProvider);
        await startNativeRun(executor);

        emitTriggerFired(
          triggerId: kTargetEndWhenTriggerId,
          triggerName:
              'The end condition on "NGC0891" (time ≥ 2026-10-22 09:48 UTC)',
          action: kTargetEndWhenSkipAction,
        );
        eventController.add(
          bridge_event.SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: bridge_event.EventSeverity.info,
            category: bridge_event.EventCategory.sequencer,
            eventType: 'Completed',
            data: const {},
          ),
        );
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final result = c.read(sequenceTerminalRunResultProvider);
        expect(result?.runStatus, 'failed');
        expect(
          c.read(liveSequenceStatsProvider)?.errorMessages ?? const <String>[],
          anyElement(contains('Nothing was imaged')),
        );
      },
    );

    test('an ordinary trigger fire is still not a warning', () async {
      final c = buildContainer(settings: const AppSettingsState());
      final executor = c.read(sequenceExecutorProvider);
      await startNativeRun(executor);

      emitTriggerFired(
        triggerId: 'hfr_degradation',
        triggerName: 'HFR degradation',
        action: 'Autofocus',
      );
      await Future<void>.delayed(Duration.zero);

      final stats = c.read(liveSequenceStatsProvider)!;
      expect(stats.triggerFires, 1);
      expect(stats.warningMessages, isEmpty);
    });
  });
}
