// The target card: sky position from the site, curves across the night, and
// nothing invented without a site.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_flip_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_run_phase_provider.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_target_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'plan_test_support.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

class _Mount extends MountStateNotifier {
  _Mount(super.ref, MountState value) {
    state = value;
  }
}

/// Boston's clock in October, so the sky checks below hold on any host.
const _edt = FixedOffsetClock(
  utcOffset: Duration(hours: -4),
  label: 'UTC-04:00',
);

void main() {
  // 22:00 EDT.
  final lateEvening = DateTime.utc(2026, 10, 20, 2);

  test('no plan: no target', () {
    final container = planContainer(now: lateEvening);
    addTearDown(container.dispose);

    expect(container.read(nightTargetProvider), isNull);
  });

  test('no site: name and coordinates only', () {
    final container = planContainer(
      now: lateEvening,
      sequence: TwoTargetPlan().sequence,
      site: false,
    );
    addTearDown(container.dispose);

    final target = container.read(nightTargetProvider)!;
    expect(target.name, 'M74');
    expect(target.nodeId, 'm74');
    expect(target.raHours, closeTo(1.611, 1e-9));
    expect(target.horizonLimitDeg, 30);
    expect(target.altitudeDeg, isNull);
    expect(target.hourAngleHours, isNull);
    expect(target.airmass, isNull);
    expect(target.altitudeCurve, isNull);
    expect(target.moonAltitudeCurve, isNull);
    expect(target.transitAt, isNull);
    expect(target.flipAt, isNull);
  });

  test('with a site: position now and curves from sunset to sunrise', () {
    final container = planContainer(
      now: lateEvening,
      sequence: TwoTargetPlan().sequence,
      clock: _edt,
    );
    addTearDown(container.dispose);

    final target = container.read(nightTargetProvider)!;
    // M74 from Boston at 22:00 EDT in October: rising in the east.
    expect(target.altitudeDeg, inInclusiveRange(30, 60));
    expect(target.hourAngleHours, isNegative);
    expect(target.airmass, inInclusiveRange(1.0, 2.0));
    expect(target.moonIlluminationPct, 44);
    expect(target.moonSet, DateTime(2026, 10, 19, 23, 9));

    final transit = target.transitAt!;
    expect(transit.isAfter(DateTime(2026, 10, 19, 23)), isTrue);
    expect(transit.isBefore(DateTime(2026, 10, 20, 2)), isTrue);
    expect(target.transitAltitudeDeg, closeTo(90 - 42.36 + 15.78, 1.0));

    final curve = target.altitudeCurve!;
    expect(curve.first.t, DateTime(2026, 10, 19, 18, 18));
    expect(curve.last.t, DateTime(2026, 10, 20, 7, 10));
    for (var i = 1; i < curve.length; i++) {
      expect(curve[i].t.isAfter(curve[i - 1].t), isTrue,
          reason: 'samples run forward across midnight');
    }
    expect(target.moonAltitudeCurve, hasLength(curve.length));
  });

  test('a planned flip is predicted from the target when flips are on', () {
    final container = planContainer(
      now: lateEvening,
      sequence: TwoTargetPlan().sequence,
      clock: _edt,
      extra: [
        isMeridianFlipEnabledProvider.overrideWithValue(true),
        effectiveMeridianFlipSettingsProvider.overrideWithValue(
          const MeridianFlipSettings(
            triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
            minutesPastMeridian: 10,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final target = container.read(nightTargetProvider)!;
    expect(
      target.flipAt!.difference(target.transitAt!).inMinutes,
      inInclusiveRange(9, 10),
    );
  });

  // Past the threshold the mount's countdown reads zero before the flip and
  // after it alike; Coming up said "Meridian flip now" for the rest of the
  // target after the flip had run.
  test('a flip done this run is not still coming', () {
    final lst = AstronomyCalculations.localSiderealTime(lateEvening, boston.longitude);
    final container = planContainer(
      now: lateEvening,
      sequence: TwoTargetPlan().sequence,
      clock: _edt,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: lateEvening.subtract(const Duration(hours: 1)),
      ),
      extra: [
        nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
        isMeridianFlipEnabledProvider.overrideWithValue(true),
        effectiveMeridianFlipSettingsProvider.overrideWithValue(
          const MeridianFlipSettings(
            triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
            minutesPastMeridian: 10,
          ),
        ),
        mountStateProvider.overrideWith(
          (ref) => _Mount(
            ref,
            MountState(
              connectionState: DeviceConnectionState.connected,
              isTracking: true,
              isParked: false,
              // An hour past the meridian.
              ra: (lst - 1 + 24) % 24,
              dec: 42,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(nightTargetProvider)!.flipAt,
      _edt.fromUtc(lateEvening),
      reason: 'past the threshold and not flipped: the flip is due now',
    );

    // ignore: invalid_use_of_protected_member
    container.read(nightSessionEventsProvider.notifier).state =
        NightSessionEvents(
      flips: [lateEvening.subtract(const Duration(minutes: 40))],
    );
    expect(container.read(nightTargetProvider)!.flipAt, isNull);
  });

  // SY-33: the flip moved the mount to pier east and then failed in its
  // recovery; the host said the mount must not flip again, and Coming up and
  // the altitude chart still read "Meridian flip 22:51".
  test('a flip that moved the mount across the pier is not still coming', () {
    final lst = AstronomyCalculations.localSiderealTime(lateEvening, boston.longitude);
    final container = planContainer(
      now: lateEvening,
      sequence: TwoTargetPlan().sequence,
      clock: _edt,
      execution: SequenceExecutionState.running,
      session: SessionState(
        isActive: true,
        startTime: lateEvening.subtract(const Duration(hours: 1)),
      ),
      extra: [
        nightRunPhaseProvider.overrideWithValue(NightRunPhase.running),
        isMeridianFlipEnabledProvider.overrideWithValue(true),
        effectiveMeridianFlipSettingsProvider.overrideWithValue(
          const MeridianFlipSettings(
            triggerMethod: MeridianTriggerMethod.minutesPastMeridian,
            minutesPastMeridian: 10,
          ),
        ),
        mountStateProvider.overrideWith(
          (ref) => _Mount(
            ref,
            MountState(
              connectionState: DeviceConnectionState.connected,
              isTracking: true,
              isParked: false,
              ra: (lst - 1 + 24) % 24,
              dec: 42,
              sideOfPier: 'East',
            ),
          ),
        ),
        nightFlipProvider.overrideWith(_MovedAcrossPier.new),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(nightTargetProvider)!.flipAt, isNull);
  });
}

class _MovedAcrossPier extends NightFlipTracker {
  @override
  NightFlipState build() => NightFlipState(
        pierAtStart: 'west',
        pierChanged: true,
        failure: (at: DateTime(2026, 11, 3, 22, 51), attempts: 4),
      );
}
