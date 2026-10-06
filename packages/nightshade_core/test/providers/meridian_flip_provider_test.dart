// Tests for the meridian flip subsystem wire-up.
//
// Covers:
//   1. Global -> per-node merge in the sequence executor's MeridianFlipConfig
//      builder (useGlobalDefaults true pulls from settings; explicit
//      `useGlobalDefaults: false` makes the per-node values sticky). The UX
//      heuristic that auto-flips the flag when the user edits any meridian
//      field lives in `applyMeridianFlipEdit(...)` in nightshade_app's editor
//      layer; see `meridian_flip_edit_helper_test.dart` in nightshade_app.
//   2. Standalone monitor lifecycle: toggling
//      `standaloneMonitoringEnabled` starts/stops the watcher and the
//      evaluator only fires when conditions are met.
//   3. Disconnect guard: mount disconnect during a flip transitions
//      `flipExecutionStateProvider` to `aborted` with the documented error.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart'
    show AstronomyCalculations;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, NightshadeBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const MeridianFlipSettings());
  });

  group('Remote meridian-flip authority', () {
    test('loads and writes the complete imaging-host snapshot', () async {
      final backend = _MockNetworkBackend();
      const hostSettings = MeridianFlipSettings(
        standaloneMonitoringEnabled: true,
        triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
        hourAngleThreshold: 1.25,
        recenterAfterFlip: false,
        maxRetries: 6,
        failureAction: FlipFailureAction.abortAndPark,
      );
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        backend.getMeridianFlipSettings,
      ).thenAnswer((_) async => hostSettings);
      when(
        () => backend.updateMeridianFlipSettings(any()),
      ).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(
        globalMeridianFlipSettingsProvider.notifier,
      );
      await notifier.ensureLoaded();
      expect(container.read(globalMeridianFlipSettingsProvider), hostSettings);
      expect(
        container.read(globalMeridianFlipSettingsLoadStateProvider).hasValue,
        isTrue,
      );

      await notifier.setMaxRetries(8);
      final saved =
          verify(
                () => backend.updateMeridianFlipSettings(captureAny()),
              ).captured.single
              as MeridianFlipSettings;
      expect(saved.maxRetries, 8);
      expect(saved.triggerMethod, MeridianTriggerMethod.hourAngleThreshold);
      expect(saved.hourAngleThreshold, 1.25);
      expect(saved.recenterAfterFlip, isFalse);
      expect(saved.failureAction, FlipFailureAction.abortAndPark);
    });

    test('remote clients never own the standalone automation timer', () async {
      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(backend.getMeridianFlipSettings).thenAnswer(
        (_) async =>
            const MeridianFlipSettings(standaloneMonitoringEnabled: true),
      );
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(globalMeridianFlipSettingsProvider.notifier)
          .ensureLoaded();
      final monitor = container.read(
        meridianFlipStandaloneMonitorProvider.notifier,
      );
      expect(monitor.evaluateOnce(), MeridianMonitorDecision.inactive);
    });
  });

  group('MeridianFlipNode useGlobalDefaults data-model contract', () {
    // The sticky-override UX heuristic ("user edited a config field → flip
    // useGlobalDefaults off") lives in the editor-layer helper
    // `applyMeridianFlipEdit(...)`, not in copyWith. These tests pin what the
    // data model itself does: a vanilla field-replace copyWith that honours an
    // explicit `useGlobalDefaults:` argument and leaves the flag alone
    // otherwise.
    test('vanilla copyWith on a meridian field does NOT auto-flip the flag', () {
      final fresh = MeridianFlipNode();
      expect(fresh.useGlobalDefaults, isTrue);

      final edited = fresh.copyWith(maxRetries: 7);
      expect(edited.maxRetries, 7);
      expect(
        edited.useGlobalDefaults,
        isTrue,
        reason:
            'plain copyWith is a field-replace; the auto-flip is in the editor helper',
      );
    });

    test('structural copyWith (name/parent) preserves useGlobalDefaults', () {
      final fresh = MeridianFlipNode();
      final renamed = fresh.copyWith(name: 'My Flip', parentId: 'root');
      expect(
        renamed.useGlobalDefaults,
        isTrue,
        reason:
            'structural changes that do not alter flip behavior must not flip the flag',
      );
    });

    test(
      'explicit useGlobalDefaults: false makes the per-node values sticky',
      () {
        // This is the persisted-override path: a node loaded from JSON with
        // useGlobalDefaults already false should keep that flag through
        // structural copies.
        final fresh = MeridianFlipNode();
        final pinned = fresh.copyWith(maxRetries: 9, useGlobalDefaults: false);
        expect(pinned.useGlobalDefaults, isFalse);
        expect(pinned.maxRetries, 9);
      },
    );
  });

  group('Sequence executor MeridianFlipConfig wiring', () {
    late NightshadeDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = NightshadeDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test(
      'updating globalMeridianFlipSettings.maxRetries flows into the effective settings used by the executor',
      () async {
        final notifier = container.read(
          globalMeridianFlipSettingsProvider.notifier,
        );
        await notifier.setMaxRetries(5);

        final settings = container.read(effectiveMeridianFlipSettingsProvider);
        expect(settings.maxRetries, 5);

        // Why : the executor's `_buildMeridianFlipConfig`
        // reads `effectiveMeridianFlipSettingsProvider` whenever a node has
        // `useGlobalDefaults: true`. Verifying the upstream propagation here
        // exercises the same provider chain without needing to spin up the
        // backend FFI surface.
        final freshNode = MeridianFlipNode();
        expect(freshNode.useGlobalDefaults, isTrue);

        // Per-node override path: when a user edits the node, the editor
        // helper switches useGlobalDefaults off so the override wins over
        // the global setting. We exercise the data-model contract directly
        // by passing `useGlobalDefaults: false` — the editor helper does
        // the same thing internally.
        final overriddenNode = freshNode.copyWith(
          maxRetries: 1,
          useGlobalDefaults: false,
        );
        expect(overriddenNode.useGlobalDefaults, isFalse);
        expect(overriddenNode.maxRetries, 1);
      },
    );

    test(
      'failure action and trigger method round-trip through the global notifier',
      () async {
        final notifier = container.read(
          globalMeridianFlipSettingsProvider.notifier,
        );

        await notifier.setFailureAction(FlipFailureAction.abortAndPark);
        await notifier.setTriggerMethod(
          MeridianTriggerMethod.hourAngleThreshold,
        );

        final settings = container.read(effectiveMeridianFlipSettingsProvider);
        expect(settings.failureAction, FlipFailureAction.abortAndPark);
        expect(
          settings.triggerMethod,
          MeridianTriggerMethod.hourAngleThreshold,
        );
      },
    );

    test(
      'unsupported standalone trigger atomically disables monitoring',
      () async {
        final notifier = container.read(
          globalMeridianFlipSettingsProvider.notifier,
        );
        await notifier.setStandaloneMonitoringEnabled(true);
        expect(
          container
              .read(globalMeridianFlipSettingsProvider)
              .standaloneMonitoringEnabled,
          isTrue,
        );

        await notifier.setTriggerMethod(
          MeridianTriggerMethod.onTrackingLimitHit,
        );
        final settings = container.read(globalMeridianFlipSettingsProvider);
        expect(
          settings.triggerMethod,
          MeridianTriggerMethod.onTrackingLimitHit,
        );
        expect(settings.standaloneMonitoringEnabled, isFalse);
        await expectLater(
          notifier.setStandaloneMonitoringEnabled(true),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('MeridianFlipStandaloneMonitor', () {
    late NightshadeDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = NightshadeDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    ProviderContainer makeContainer({
      required MountState mount,
      double longitude = -75.0,
      double latitude = 40.0,
      NightshadeBackend? backend,
    }) {
      return ProviderContainer(
        overrides: [
          if (backend != null)
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          databaseProvider.overrideWithValue(db),
          mountStateProvider.overrideWith((ref) {
            final n = MountStateNotifier(ref);
            n.state = mount;
            return n;
          }),
          // Why: override appSettings with a real location so the monitor
          // doesn't refuse to compute HA from a 0,0 default.
          appSettingsProvider.overrideWith(() {
            return _StubAppSettingsNotifier(
              AppSettingsState(latitude: latitude, longitude: longitude),
            );
          }),
        ],
      );
    }

    test(
      'inactive when standaloneMonitoringEnabled is false, even with trigger conditions met',
      () async {
        container = makeContainer(
          mount: const MountState(
            connectionState: DeviceConnectionState.connected,
            isTracking: true,
            isParked: false,
            ra: 0.0,
          ),
        );

        await container.read(appSettingsProvider.future);

        final monitor = container.read(
          meridianFlipStandaloneMonitorProvider.notifier,
        );
        final decision = monitor.evaluateOnce();
        expect(decision, MeridianMonitorDecision.inactive);
      },
    );

    test(
      'returns sequenceRunning when execution state is running and toggle is on',
      () async {
        container = makeContainer(
          mount: const MountState(
            connectionState: DeviceConnectionState.connected,
            isTracking: true,
            isParked: false,
            ra: 6.0,
          ),
        );
        await container.read(appSettingsProvider.future);
        await container
            .read(globalMeridianFlipSettingsProvider.notifier)
            .setStandaloneMonitoringEnabled(true);
        container.read(sequenceExecutionStateProvider.notifier).state =
            SequenceExecutionState.running;

        final monitor = container.read(
          meridianFlipStandaloneMonitorProvider.notifier,
        );
        expect(monitor.evaluateOnce(), MeridianMonitorDecision.sequenceRunning);
      },
    );

    test(
      'inactive when mount is disconnected even with monitoring enabled',
      () async {
        container = makeContainer(
          mount: const MountState(
            connectionState: DeviceConnectionState.disconnected,
          ),
        );
        await container.read(appSettingsProvider.future);
        await container
            .read(globalMeridianFlipSettingsProvider.notifier)
            .setStandaloneMonitoringEnabled(true);

        final monitor = container.read(
          meridianFlipStandaloneMonitorProvider.notifier,
        );
        expect(monitor.evaluateOnce(), MeridianMonitorDecision.inactive);
      },
    );

    test('legacy unsupported standalone mode remains inactive', () async {
      container = makeContainer(
        mount: const MountState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'mount-1',
          isTracking: true,
          isParked: false,
          ra: 6,
          dec: 20,
        ),
      );
      await container
          .read(globalMeridianFlipSettingsProvider.notifier)
          .updateSettings(
            const MeridianFlipSettings(
              standaloneMonitoringEnabled: true,
              triggerMethod: MeridianTriggerMethod.minutesBeforeLimit,
            ),
          );

      final monitor = container.read(
        meridianFlipStandaloneMonitorProvider.notifier,
      );
      expect(monitor.evaluateOnce(), MeridianMonitorDecision.inactive);
      expect(
        container.read(flipExecutionStateProvider),
        FlipExecutionState.idle,
      );
    });

    test(
      'fires when mount HA crosses threshold and emits alert state',
      () async {
        // Why: pick an RA such that with a known longitude+time HA is past
        // the threshold. Easier: choose RA = LST - desired_HA. Compute LST
        // explicitly so the test is deterministic.
        final now = DateTime.now().toUtc();
        final lst = computeLocalSiderealTimeHours(now, -75.0);
        // Target an HA of +0.5 hours (past meridian) — well above the default
        // 5 min (0.083 h) trigger.
        final ra = (lst - 0.5) % 24.0;

        container = makeContainer(
          mount: MountState(
            connectionState: DeviceConnectionState.connected,
            isTracking: true,
            isParked: false,
            ra: ra,
            sideOfPier: 'west',
          ),
        );
        await container.read(appSettingsProvider.future);
        await container
            .read(globalMeridianFlipSettingsProvider.notifier)
            .setStandaloneMonitoringEnabled(true);

        // Defaults: trigger = minutesPastMeridian, threshold = 5 min.
        final monitor = container.read(
          meridianFlipStandaloneMonitorProvider.notifier,
        );
        final decision = monitor.evaluateOnce();
        expect(decision, MeridianMonitorDecision.triggered);

        // Why: the trigger path must update the UI's flip-execution state so
        // the operator sees something happened. The monitor now also ATTEMPTS
        // the real flip via backend.performMeridianFlip; in this test
        // environment the mount has no device id / declination, so the
        // attempt honestly lands in `failed` with a diagnostic — the
        // important property is that the state left `idle` (alert fired) and
        // the failure is surfaced rather than swallowed.
        final flipState = container.read(flipExecutionStateProvider);
        expect(flipState, isNot(FlipExecutionState.idle));
        if (flipState == FlipExecutionState.failed) {
          expect(container.read(flipLastErrorProvider), isNotNull);
        }

        // A second evaluation immediately after should respect the cooldown.
        final second = monitor.evaluateOnce();
        expect(second, MeridianMonitorDecision.cooldown);
      },
    );

    test(
      'manual flip uses canonical settings and disables centering without a camera',
      () async {
        final backend = _MockFfiBackend();
        when(
          () => backend.performMeridianFlip(
            mountId: any(named: 'mountId'),
            cameraId: any(named: 'cameraId'),
            focuserId: any(named: 'focuserId'),
            coverCalibratorId: any(named: 'coverCalibratorId'),
            targetName: any(named: 'targetName'),
            targetRaHours: any(named: 'targetRaHours'),
            targetDecDegrees: any(named: 'targetDecDegrees'),
            pauseGuiding: any(named: 'pauseGuiding'),
            autoCenter: any(named: 'autoCenter'),
            refocusAfter: any(named: 'refocusAfter'),
            resumeGuiding: any(named: 'resumeGuiding'),
            settleTimeSecs: any(named: 'settleTimeSecs'),
          ),
        ).thenAnswer((_) async {});
        container = makeContainer(
          backend: backend,
          mount: const MountState(
            connectionState: DeviceConnectionState.connected,
            deviceId: 'mount-1',
            isTracking: true,
            isParked: false,
            ra: 7.5,
            dec: -20,
          ),
        );
        await container.read(appSettingsProvider.future);
        final settings = container.read(
          globalMeridianFlipSettingsProvider.notifier,
        );
        await settings.ensureLoaded();
        await settings.setPushNotificationOnFlip(false);

        final succeeded = await container
            .read(meridianFlipStandaloneMonitorProvider.notifier)
            .executeNow();

        expect(succeeded, isTrue);
        expect(
          container.read(flipExecutionStateProvider),
          FlipExecutionState.completed,
        );
        final sent = verify(
          () => backend.performMeridianFlip(
            mountId: 'mount-1',
            cameraId: null,
            focuserId: null,
            coverCalibratorId: null,
            targetName: 'Manual flip',
            targetRaHours: captureAny(named: 'targetRaHours'),
            targetDecDegrees: captureAny(named: 'targetDecDegrees'),
            pauseGuiding: true,
            autoCenter: false,
            refocusAfter: false,
            resumeGuiding: true,
            settleTimeSecs: 10,
          ),
        );
        sent.called(1);
        // The mount reads back coordinates of date; the flip engine re-slews
        // to a J2000 target (and precesses it again on the way out). Passing
        // the read-back straight through moved the framing by the precession
        // offset -- ~20' in 2026 -- on every manual flip. The simulator, now an
        // of-date mount, shows it: see frame_tests.rs in the bridge.
        final (
          raJ2000Deg,
          decJ2000,
        ) = AstronomyCalculations.precessFromDateToJ2000(
          raDeg: 7.5 * 15,
          decDeg: -20,
          dt: DateTime.now().toUtc(),
        );
        final raSent = sent.captured[0] as double;
        final decSent = sent.captured[1] as double;
        expect(raSent, closeTo(raJ2000Deg / 15, 1 / 3600));
        expect(decSent, closeTo(decJ2000, 1 / 60));
        expect(
          (raSent - 7.5).abs() * 15 * 60,
          greaterThan(10),
          reason: 'the of-date read-back was sent as the J2000 target',
        );
      },
    );

    test('manual flip refuses while a sequence owns the mount', () async {
      final backend = _MockFfiBackend();
      container = makeContainer(
        backend: backend,
        mount: const MountState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'mount-1',
          isTracking: true,
          isParked: false,
          ra: 7.5,
          dec: -20,
        ),
      );
      container.read(sequenceExecutionStateProvider.notifier).state =
          SequenceExecutionState.running;

      final succeeded = await container
          .read(meridianFlipStandaloneMonitorProvider.notifier)
          .executeNow();

      expect(succeeded, isFalse);
      expect(
        container.read(flipLastErrorProvider),
        contains('active sequence'),
      );
      verifyNever(
        () => backend.performMeridianFlip(
          mountId: any(named: 'mountId'),
          cameraId: any(named: 'cameraId'),
          focuserId: any(named: 'focuserId'),
          coverCalibratorId: any(named: 'coverCalibratorId'),
          targetName: any(named: 'targetName'),
          targetRaHours: any(named: 'targetRaHours'),
          targetDecDegrees: any(named: 'targetDecDegrees'),
          pauseGuiding: any(named: 'pauseGuiding'),
          autoCenter: any(named: 'autoCenter'),
          refocusAfter: any(named: 'refocusAfter'),
          resumeGuiding: any(named: 'resumeGuiding'),
          settleTimeSecs: any(named: 'settleTimeSecs'),
        ),
      );
    });
  });

  group('MeridianFlipDisconnectGuard', () {
    late NightshadeDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = NightshadeDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test(
      'transitions executing -> aborted on mount disconnect with documented error',
      () async {
        // Why: the guard's listen only fires on a *change* in mount state. The
        // initial default MountState is already disconnected, so we must first
        // transition the notifier to connected so the subsequent disconnect
        // delta produces a notification.
        final mountNotifier = container.read(mountStateProvider.notifier);
        mountNotifier.state = const MountState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'mount-1',
        );

        // Activate the guard.
        container.read(meridianFlipDisconnectGuardProvider);

        // Simulate an in-flight flip by setting state to executing.
        container.read(flipExecutionStateProvider.notifier).state =
            FlipExecutionState.executing;
        container.read(flipCurrentStepProvider.notifier).state =
            FlipStep.slewingToTarget;
        container.read(flipProgressProvider.notifier).state = 42;
        container.read(flipCurrentAttemptProvider.notifier).state = 1;

        // Now disconnect; the listener should see the connected->disconnected
        // delta and run the abort path.
        mountNotifier.state = const MountState(
          connectionState: DeviceConnectionState.disconnected,
        );

        // Allow the ref.listen tick to flush.
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(flipExecutionStateProvider),
          FlipExecutionState.aborted,
        );
        expect(container.read(flipCurrentStepProvider), isNull);
        expect(container.read(flipProgressProvider), 0);
        expect(container.read(flipCurrentAttemptProvider), 0);
        expect(
          container.read(flipLastErrorProvider),
          'Meridian flip aborted: mount disconnected',
        );
      },
    );
  });

  // The standalone monitor and SchedulerEngine both delegate their LST/HA math
  // to SkyCalculations. These pin that the monitor's public free-function entry
  // points are exact aliases of it, with no behaviour of their own.
  group('LST/HA helpers share one implementation', () {
    test(
      'computeLocalSiderealTimeHours == SkyCalculations.localSiderealTimeHours',
      () {
        final t = DateTime.utc(2024, 3, 1, 6, 45, 0);
        const lon = -71.0;
        expect(
          computeLocalSiderealTimeHours(t, lon),
          equals(SkyCalculations.localSiderealTimeHours(t, lon)),
        );
      },
    );

    test('computeHourAngleHours == SkyCalculations.hourAngleHours', () {
      expect(
        computeHourAngleHours(5.5, 9.25),
        equals(SkyCalculations.hourAngleHours(5.5, 9.25)),
      );
    });

    test('pinned LST (Meeus 12.a) and HA convention', () {
      // GMST at 1987-04-10 00:00 UTC, Greenwich = 197.693195° (Meeus 12.a).
      final lst = computeLocalSiderealTimeHours(
        DateTime.utc(1987, 4, 10, 0, 0, 0),
        0.0,
      );
      expect(lst * 15.0, closeTo(197.693195, 1e-4));
      // HA = LST - RA, positive => west of meridian / already flipped.
      expect(computeHourAngleHours(lst - 2.0, lst), closeTo(2.0, 1e-9));
    });
  });
}

/// Why: appSettingsProvider is an AsyncNotifierProvider so the test needs a
/// stub that returns a synchronous state. Using the public `overrideWith`
/// requires an AsyncNotifier subclass.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._seed);

  final AppSettingsState _seed;

  @override
  Future<AppSettingsState> build() async => _seed;
}
