// Tests for component C2: meridianCountdownProvider — the derived
// time-to-flip + armed-state model behind the live-capture meridian banner.
//
// The pure compute (`computeMeridianCountdown`) is exercised directly with no
// timers, driving every arming precondition and each trigger-method branch.
// A small set of integration tests then verify the StreamProvider wraps that
// function on a ticker and reads the right upstream providers.
//
// HA determinism trick: rather than reverse-engineer the sidereal formula, we
// compute the live LST from the public helper for a fixed `nowUtc`/longitude,
// then choose `mount.ra` so that HA = LST - RA lands exactly where the scenario
// needs it. This keeps the assertions exact while reusing the production math.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/models/meridian_flip_settings.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart'
    show SequenceExecutionState;
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/equipment/mount_state_provider.dart';
import 'package:skotiq_core/src/providers/meridian_countdown_provider.dart';
import 'package:skotiq_core/src/providers/meridian_flip_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart'
    show sequenceExecutionStateProvider;
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show AppSettingsState, AppSettingsNotifier, appSettingsProvider;

/// Fixed instant + longitude used across the pure tests so HA is reproducible.
final _fixedNowUtc = DateTime.utc(2026, 5, 29, 4, 0, 0);
const _longitude = -75.0;
const _latitude = 40.0;

/// Build a [MountState] whose hour angle equals [haHours] at [_fixedNowUtc].
///
/// HA = LST - RA, so RA = LST - HA (normalized into [0, 24)).
MountState _mountAtHourAngle(
  double haHours, {
  DeviceConnectionState connectionState = DeviceConnectionState.connected,
  bool isTracking = true,
  bool isParked = false,
  String? sideOfPier = 'east',
}) {
  final lst = computeLocalSiderealTimeHours(_fixedNowUtc, _longitude);
  var ra = lst - haHours;
  while (ra < 0) {
    ra += 24.0;
  }
  while (ra >= 24.0) {
    ra -= 24.0;
  }
  return MountState(
    connectionState: connectionState,
    deviceId: 'test-mount',
    ra: ra,
    dec: 45.0,
    isTracking: isTracking,
    isParked: isParked,
    sideOfPier: sideOfPier,
  );
}

void main() {
  group('computeMeridianCountdown — arming preconditions', () {
    test('(a) disconnected mount -> not armed with reason', () {
      final result = computeMeridianCountdown(
        mount: const MountState(
          connectionState: DeviceConnectionState.disconnected,
        ),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.timeToFlip, isNull);
      expect(result.disabledReason, 'Mount not connected');
      expect(result.isAutomaticWatchdog, isTrue);
    });

    test('mount not tracking -> not armed with "not tracking" reason', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0, isTracking: false),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Mount not tracking');
    });

    test('parked mount -> not armed', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0, isParked: true),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Mount is parked');
    });

    test('null RA -> not armed', () {
      final result = computeMeridianCountdown(
        mount: const MountState(
          connectionState: DeviceConnectionState.connected,
          isTracking: true,
          isParked: false,
        ),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Mount has not reported its position yet');
    });

    test('(b) 0,0 location -> not armed with location reason', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0),
        longitude: 0.0,
        latitude: 0.0,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Set your location in Settings');
    });

    test('null location -> not armed with location reason', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0),
        longitude: null,
        latitude: null,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Set your location in Settings');
    });

    test('meridian flip disabled -> not armed with off reason', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(),
        execState: SequenceExecutionState.idle,
        enabled: false,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isFalse);
      expect(result.disabledReason, 'Auto meridian flip is turned off');
    });
  });

  group('computeMeridianCountdown — minutesPastMeridian method', () {
    test('(c) HA just before meridian -> positive timeToFlip', () {
      // HA = -0.1h (6 minutes before the meridian). Threshold is 5 minutes
      // PAST the meridian => thresholdHours = 5/60. Minutes to flip should be
      // (5/60 - (-0.1)) * 60 = 5 + 6 = 11 minutes.
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-0.1),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
          minutesPastMeridian: 5.0,
        ),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isTrue);
      expect(result.disabledReason, isNull);
      expect(result.timeToFlip, isNotNull);
      // Allow ±2s for the sub-minute rounding from the HA math.
      expect(
        (result.timeToFlip!.inSeconds - 11 * 60).abs() <= 2,
        isTrue,
        reason: 'expected ~11 minutes, got ${result.timeToFlip}',
      );
      expect(result.method, MeridianTriggerMethod.minutesPastMeridian);
      expect(result.sideOfPier, 'east');
      expect(result.isSequencerOwned, isFalse);
    });

    test('(d) HA past threshold -> flip imminent (zero duration)', () {
      // HA = +0.5h (30 min past meridian), well past the 5-minute threshold.
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(0.5),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
          minutesPastMeridian: 5.0,
        ),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isTrue);
      expect(result.timeToFlip, Duration.zero);
      expect(result.isFlipImminent, isTrue);
      expect(result.disabledReason, 'Already past meridian — flip imminent');
    });

    test('hourAngleThreshold method computes against HA hours directly', () {
      // HA = +0.2h, threshold 0.5h => (0.5 - 0.2) * 60 = 18 minutes.
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(0.2),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.hourAngleThreshold,
          hourAngleThreshold: 0.5,
        ),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isTrue);
      expect(result.timeToFlip, isNotNull);
      expect(
        (result.timeToFlip!.inSeconds - 18 * 60).abs() <= 2,
        isTrue,
        reason: 'expected ~18 minutes, got ${result.timeToFlip}',
      );
    });
  });

  group('computeMeridianCountdown — tracking-limit methods are Rust-owned', () {
    test(
      '(e) minutesBeforeLimit -> timeToFlip null + sequencer-owned reason',
      () {
        final result = computeMeridianCountdown(
          mount: _mountAtHourAngle(-1.0),
          longitude: _longitude,
          latitude: _latitude,
          settings: const MeridianFlipSettings(
            triggerMethod: MeridianTriggerMethod.minutesBeforeLimit,
          ),
          execState: SequenceExecutionState.idle,
          enabled: true,
          nowUtc: _fixedNowUtc,
        );

        // Armed (preconditions met) but no Dart-computable countdown.
        expect(result.isArmed, isTrue);
        expect(result.timeToFlip, isNull);
        expect(result.isSequencerOwned, isTrue);
        expect(
          result.disabledReason,
          'Monitored by sequencer (tracking-limit method)',
        );
        // HA is still computed for display.
        expect(result.hourAngleHours, closeTo(-1.0, 1e-6));
      },
    );

    test('onTrackingLimitHit -> timeToFlip null + sequencer-owned', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-1.0),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.onTrackingLimitHit,
        ),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isArmed, isTrue);
      expect(result.timeToFlip, isNull);
      expect(result.isSequencerOwned, isTrue);
      expect(
        result.disabledReason,
        'Monitored by sequencer (tracking-limit method)',
      );
    });
  });

  group('computeMeridianCountdown — sequence ownership', () {
    test(
      '(f) sequence running -> isSequencerOwned true but countdown still shown',
      () {
        final result = computeMeridianCountdown(
          mount: _mountAtHourAngle(-0.1),
          longitude: _longitude,
          latitude: _latitude,
          settings: const MeridianFlipSettings(
            triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
            minutesPastMeridian: 5.0,
          ),
          execState: SequenceExecutionState.running,
          enabled: true,
          nowUtc: _fixedNowUtc,
        );

        expect(result.isArmed, isTrue);
        expect(result.isSequencerOwned, isTrue);
        // Numeric countdown is STILL computed so the banner can show the timer.
        expect(result.timeToFlip, isNotNull);
        expect(result.disabledReason, isNull);
      },
    );

    test('paused sequence is also sequencer-owned', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-0.1),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
          minutesPastMeridian: 5.0,
        ),
        execState: SequenceExecutionState.paused,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isSequencerOwned, isTrue);
    });

    test('idle sequence with armed countdown is NOT sequencer-owned', () {
      final result = computeMeridianCountdown(
        mount: _mountAtHourAngle(-0.1),
        longitude: _longitude,
        latitude: _latitude,
        settings: const MeridianFlipSettings(
          triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
          minutesPastMeridian: 5.0,
        ),
        execState: SequenceExecutionState.idle,
        enabled: true,
        nowUtc: _fixedNowUtc,
      );

      expect(result.isSequencerOwned, isFalse);
    });
  });

  group('MeridianCountdownState equality', () {
    test('value-equal states compare equal', () {
      const a = MeridianCountdownState(
        isArmed: true,
        timeToFlip: Duration(minutes: 5),
        isAutomaticWatchdog: true,
        isSequencerOwned: false,
        disabledReason: null,
        method: MeridianTriggerMethod.minutesPastMeridian,
        hourAngleHours: -0.1,
        sideOfPier: 'east',
      );
      const b = MeridianCountdownState(
        isArmed: true,
        timeToFlip: Duration(minutes: 5),
        isAutomaticWatchdog: true,
        isSequencerOwned: false,
        disabledReason: null,
        method: MeridianTriggerMethod.minutesPastMeridian,
        hourAngleHours: -0.1,
        sideOfPier: 'east',
      );
      expect(a, equals(b));

      const c = MeridianCountdownState(
        isArmed: false,
        timeToFlip: null,
        isAutomaticWatchdog: true,
        isSequencerOwned: false,
        disabledReason: 'Mount not connected',
        method: MeridianTriggerMethod.minutesPastMeridian,
        hourAngleHours: 0.0,
        sideOfPier: null,
      );
      expect(a == c, isFalse);
    });
  });

  group('meridianCountdownProvider — Provider wiring', () {
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    ProviderContainer makeContainer({
      required MountState mount,
      double longitude = _longitude,
      double latitude = _latitude,
      SequenceExecutionState execState = SequenceExecutionState.idle,
    }) {
      return ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          mountStateProvider.overrideWith((ref) {
            final n = MountStateNotifier(ref);
            n.state = mount;
            return n;
          }),
          appSettingsProvider.overrideWith(
            () => _StubAppSettingsNotifier(
              AppSettingsState(latitude: latitude, longitude: longitude),
            ),
          ),
          sequenceExecutionStateProvider.overrideWith((ref) => execState),
        ],
      );
    }

    /// Subscribe to the provider and return the latest emitted value once the
    /// async [appSettingsProvider] has resolved (the provider re-emits on that
    /// transition). Picks the location-resolved state, not the transient
    /// AsyncLoading-driven first emit.
    Future<MeridianCountdownState> latestAfterSettingsLoad() async {
      // Keep the autoDispose projection alive while the async settings resolve.
      // The provider re-watches appSettingsProvider, so it recomputes when the
      // location lands; we then read the recomputed (location-aware) value.
      final sub = container.listen<MeridianCountdownState>(
        meridianCountdownProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await container.read(appSettingsProvider.future);
      await Future<void>.delayed(Duration.zero);
      return container.read(meridianCountdownProvider);
    }

    test('emits an armed countdown after settings load', () async {
      // HA chosen so that for any plausible real "now" the target is east of
      // the meridian (negative HA) and well before the 5-minute-past threshold,
      // giving a positive countdown rather than an imminent flip.
      container = makeContainer(mount: _mountAtHourAngle(-2.0));

      final state = await latestAfterSettingsLoad();
      expect(state.isArmed, isTrue);
      expect(state.timeToFlip, isNotNull);
      expect(state.method, MeridianTriggerMethod.minutesPastMeridian);
    });

    test(
      'disconnected mount surfaces the disabled reason through the stream',
      () async {
        container = makeContainer(
          mount: const MountState(
            connectionState: DeviceConnectionState.disconnected,
          ),
        );

        final state = await latestAfterSettingsLoad();
        expect(state.isArmed, isFalse);
        expect(state.disabledReason, 'Mount not connected');
      },
    );
  });
}

/// Minimal [AppSettingsNotifier] stand-in that serves a fixed state, mirroring
/// the stub used in `meridian_flip_provider_test.dart`.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._seed);

  final AppSettingsState _seed;

  @override
  Future<AppSettingsState> build() async => _seed;
}
