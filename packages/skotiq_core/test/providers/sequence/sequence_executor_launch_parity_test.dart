// What `start()` and `resumeFromCheckpoint()` must agree on, and what happens
// when a mid-run configuration push fails.
//
// The two launch paths used to build the same ordered set of resources — run
// row, live stats, native run id, per-run timers, the event subscription, and
// the launch-authoritative config push — as two hand-maintained copies. A fix
// applied to one had to be remembered for the other, which is how the resume
// path came to push the raw safety fail mode and abort itself within ~100 ms.
// These tests pin the agreement itself, so the copies cannot come back.
//
// The mid-run group pins a separate contract: every backend push made from a
// `_ref.listen` callback is now awaited, so a rejected push reaches the
// operator as a run warning instead of the zone as an unhandled async error.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

/// A backend whose unstubbed members answer with a completed `Future<void>`,
/// so the deep launch push runs end to end without stubbing 30 calls.
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

/// Settings a test can change mid-run, so the `_ref.listen` watchers the
/// executor installs at start actually fire.
class _MutableSettingsNotifier extends AppSettingsNotifier {
  _MutableSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;

  void push(AppSettingsState next) => state = AsyncData(next);
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
    name: 'launch parity',
    nodes: {root.id: root},
    rootNodeId: root.id,
  );
}

/// A profile configured entirely through the LEGACY generic optics fields —
/// `telescopeAperture` / `telescopeFocalLength` unset, the real values in
/// `aperture` / `focalLength`. The fallback that reads them is the one the
/// observer-profile derivation had two copies of.
const _legacyOpticsProfile = EquipmentProfileModel(
  name: 'Legacy optics',
  cameraName: 'ZWO ASI2600MM Pro',
  telescopeName: 'Esprit 100',
  focalLength: 550.0,
  aperture: 100.0,
);

void main() {
  setUpAll(registerMocktailFallbackValues);

  late _PermissiveBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;
  late List<String?> pushedSavePaths;
  late List<Map<Symbol, Object?>> pushedDevices;
  late List<Map<Symbol, Object?>> pushedObserverProfiles;
  late List<int> pushedRunIds;
  ProviderContainer? container;

  ProviderContainer buildContainer({
    AppSettingsNotifier Function()? settings,
    bool cameraConnected = true,
    EquipmentProfileModel? profile,
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sequenceValidatorProvider.overrideWith(_passingValidator),
        if (settings != null) appSettingsProvider.overrideWith(settings),
        if (cameraConnected)
          cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
        if (profile != null)
          activeEquipmentProfileProvider.overrideWithValue(profile),
      ],
    );
    container = c;
    return c;
  }

  setUp(() {
    container = null;
    pushedSavePaths = [];
    pushedDevices = [];
    pushedObserverProfiles = [];
    pushedRunIds = [];
    backend = _PermissiveBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(() => backend.sequencerStart()).thenAnswer((_) async {});
    when(() => backend.resumeFromCheckpoint()).thenAnswer((_) async {});
    when(() => backend.getCheckpointInfo()).thenAnswer(
      (_) async => CheckpointInfo(
        sequenceName: 'launch parity',
        timestamp: DateTime.now(),
        completedExposures: 3,
        completedIntegrationSecs: 6.0,
        canResume: true,
        ageSeconds: 12,
      ),
    );
    when(() => backend.sequencerSetSavePath(any())).thenAnswer((inv) async {
      pushedSavePaths.add(inv.positionalArguments.first as String?);
    });
    when(
      () => backend.sequencerSetDevices(
        cameraId: any(named: 'cameraId'),
        mountId: any(named: 'mountId'),
        focuserId: any(named: 'focuserId'),
        filterwheelId: any(named: 'filterwheelId'),
        rotatorId: any(named: 'rotatorId'),
      ),
    ).thenAnswer((inv) async {
      pushedDevices.add(inv.namedArguments);
    });
    when(
      () => backend.sequencerUpdateObserverProfile(
        observerName: any(named: 'observerName'),
        siteElevationM: any(named: 'siteElevationM'),
        cameraMake: any(named: 'cameraMake'),
        cameraModel: any(named: 'cameraModel'),
        telescopeName: any(named: 'telescopeName'),
        telescopeFocalLengthMm: any(named: 'telescopeFocalLengthMm'),
        telescopeApertureMm: any(named: 'telescopeApertureMm'),
      ),
    ).thenAnswer((inv) async {
      pushedObserverProfiles.add(inv.namedArguments);
    });
    when(() => backend.sequencerSetActiveSequenceRunId(any())).thenAnswer((
      inv,
    ) async {
      pushedRunIds.add(inv.positionalArguments.first as int);
    });
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

  Future<void> pumpEvents() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void emitExposureCompleted() {
    eventController.add(
      bridge_event.SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.info,
        category: bridge_event.EventCategory.sequencer,
        eventType: 'ExposureCompleted',
        data: const {'frame': 1, 'total': 4, 'duration_secs': 30.0},
      ),
    );
  }

  group('A. both launch paths open the same run records', () {
    test('start opens a run row, live stats and a native run id', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(c.read(currentRunIdProvider), isNotNull);
      expect(c.read(liveSequenceStatsProvider), isNotNull);
      expect(
        pushedRunIds,
        [c.read(currentRunIdProvider)],
        reason: 'every DecisionEvent the executor emits is stamped with this',
      );

      await executor.stop();
    });

    test('resume opens exactly the same records', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        c.read(currentRunIdProvider),
        isNotNull,
        reason: 'a resumed run is a run; its frames need a row to land in',
      );
      expect(c.read(liveSequenceStatsProvider), isNotNull);
      expect(pushedRunIds, [c.read(currentRunIdProvider)]);

      await executor.stop();
    });

    test('a resumed run starts its per-run timers, like a fresh one', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        c.read(sequenceExecutionStateProvider),
        SequenceExecutionState.running,
      );
      expect(
        executor.isListeningToNativeEventsForTest,
        isTrue,
        reason: 'nothing would turn a resumed frame into a captured_images row',
      );

      await executor.stop();
    });
  });

  group('B. exactly one listener handles each native event', () {
    test('a started run counts one frame per ExposureCompleted', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      emitExposureCompleted();
      await pumpEvents();

      expect(
        c.read(liveSequenceStatsProvider)!.framesCaptured,
        1,
        reason: 'a second live subscription would count the frame twice',
      );

      await executor.stop();
    });

    test('a resumed run counts one frame per ExposureCompleted', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();
      emitExposureCompleted();
      await pumpEvents();

      expect(c.read(liveSequenceStatsProvider)!.framesCaptured, 1);

      await executor.stop();
    });

    test('re-attaching over a live run replaces, never doubles', () async {
      final c = buildContainer();
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      // The headless route calls this directly; it can land on an executor
      // that already has a subscription.
      await executor.attachHostListenersForNativeRun();
      emitExposureCompleted();
      await pumpEvents();

      expect(c.read(liveSequenceStatsProvider)!.framesCaptured, 1);

      await executor.stop();
    });
  });

  group('C. the two launch differences that are real are preserved', () {
    test('an empty save path is pushed as null on start', () async {
      final c = buildContainer(
        settings: () => _MutableSettingsNotifier(const AppSettingsState()),
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(
        pushedSavePaths,
        [null],
        reason: 'a fresh run must not inherit the previous run save path',
      );

      await executor.stop();
    });

    test('an empty save path is left alone on resume', () async {
      final c = buildContainer(
        settings: () => _MutableSettingsNotifier(const AppSettingsState()),
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        pushedSavePaths,
        isEmpty,
        reason:
            'null means "do not save"; pushing it would clobber the path the '
            'checkpoint restored and the resumed run would write nothing',
      );

      await executor.stop();
    });

    test('resume pushes no device ids while the camera is offline', () async {
      final c = buildContainer(cameraConnected: false);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.resumeFromCheckpoint();

      expect(
        pushedDevices,
        isEmpty,
        reason:
            'in crash-recovery-at-startup the snapshot ids are the best '
            'information there is; nulls would strand the resumed run',
      );

      await executor.stop();
    });

    test('start pushes device ids even with nothing connected', () async {
      final c = buildContainer(cameraConnected: false);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();

      expect(pushedDevices, hasLength(1));
      expect(pushedDevices.single[#cameraId], isNull);

      await executor.stop();
    });
  });

  group('D. one observer-profile derivation feeds every caller', () {
    test('the legacy optics fallback survives into the mid-run push', () async {
      final settings = _MutableSettingsNotifier(
        const AppSettingsState(observerName: 'Ada'),
      );
      final c = buildContainer(
        settings: () => settings,
        profile: _legacyOpticsProfile,
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      expect(pushedObserverProfiles, hasLength(1));

      settings.push(const AppSettingsState(observerName: 'Grace'));
      await pumpEvents();

      expect(
        pushedObserverProfiles,
        hasLength(2),
        reason: 'the observer-name watcher must re-push the profile',
      );
      final seeded = pushedObserverProfiles.first;
      final midRun = pushedObserverProfiles.last;
      expect(seeded[#telescopeApertureMm], 100.0);
      expect(seeded[#telescopeFocalLengthMm], 550.0);
      expect(
        midRun[#telescopeApertureMm],
        seeded[#telescopeApertureMm],
        reason:
            'the aperture fallback was written twice; a fix to one copy left '
            'the other emitting FOCALLEN with no APTDIA',
      );
      expect(midRun[#telescopeFocalLengthMm], seeded[#telescopeFocalLengthMm]);
      expect(midRun[#cameraMake], 'ZWO');
      expect(midRun[#cameraModel], 'ASI2600MM Pro');
      expect(midRun[#observerName], 'Grace');

      await executor.stop();
    });
  });

  group('E. a failed mid-run push reaches the operator', () {
    test('a rejected location push becomes a run warning', () async {
      final settings = _MutableSettingsNotifier(
        const AppSettingsState(latitude: 40.0, longitude: -74.0),
      );
      // Armed only after start: the run-start seed pushes the same call, and
      // a failure there aborts start() instead of exercising the watcher.
      var backendGone = false;
      when(
        () => backend.sequencerUpdateLocation(
          latitude: any(named: 'latitude'),
          longitude: any(named: 'longitude'),
        ),
      ).thenAnswer((_) async {
        if (backendGone) throw StateError('backend went away');
      });
      final c = buildContainer(settings: () => settings);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      backendGone = true;
      settings.push(const AppSettingsState(latitude: 41.0, longitude: -75.0));
      await pumpEvents();

      // A failed mid-run push must reach the operator through the run's
      // warnings: fire-and-forget makes it an unhandled zone error, and the
      // run goes on using the stale location for its altitude and flip maths.
      expect(
        c.read(liveSequenceStatsProvider)!.warningMessages,
        contains(
          allOf(
            contains('the observing location'),
            contains('still using the previous value'),
          ),
        ),
      );

      await executor.stop();
    });

    test('a rejected observer-profile push becomes a run warning', () async {
      final settings = _MutableSettingsNotifier(
        const AppSettingsState(observerName: 'Ada'),
      );
      var backendGone = false;
      when(
        () => backend.sequencerUpdateObserverProfile(
          observerName: any(named: 'observerName'),
          siteElevationM: any(named: 'siteElevationM'),
          cameraMake: any(named: 'cameraMake'),
          cameraModel: any(named: 'cameraModel'),
          telescopeName: any(named: 'telescopeName'),
          telescopeFocalLengthMm: any(named: 'telescopeFocalLengthMm'),
          telescopeApertureMm: any(named: 'telescopeApertureMm'),
        ),
      ).thenAnswer((_) async {
        if (backendGone) throw StateError('backend went away');
      });
      final c = buildContainer(
        settings: () => settings,
        profile: _legacyOpticsProfile,
      );
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      backendGone = true;
      settings.push(const AppSettingsState(observerName: 'Grace'));
      await pumpEvents();

      // This one sat inside a try/catch that could never fire, because the
      // call it guarded was never awaited.
      expect(
        c.read(liveSequenceStatsProvider)!.warningMessages,
        contains(contains('the observer profile')),
      );

      await executor.stop();
    });

    test('a push that succeeds raises no warning', () async {
      final settings = _MutableSettingsNotifier(
        const AppSettingsState(latitude: 40.0, longitude: -74.0),
      );
      final c = buildContainer(settings: () => settings);
      c.read(currentSequenceProvider.notifier).loadSequence(_buildSequence());
      final executor = c.read(sequenceExecutorProvider);

      await executor.start();
      settings.push(const AppSettingsState(latitude: 41.0, longitude: -75.0));
      await pumpEvents();

      expect(
        c.read(liveSequenceStatsProvider)!.warningMessages,
        isNot(contains(contains('could not be sent'))),
      );

      await executor.stop();
    });
  });
}
