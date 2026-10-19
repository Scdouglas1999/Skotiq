// The target card: sky position from the site, curves across the night, and
// nothing invented without a site.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/plan/night_target_provider.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import 'plan_test_support.dart';

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
}
