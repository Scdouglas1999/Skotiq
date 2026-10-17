import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/planning/night_forecast.dart';

void main() {
  // A local-noon night date, the bucketing anchor used across the planner.
  final nightDate = DateTime(2026, 5, 30, 12);

  ForecastTargetUp target({
    int id = 1,
    String name = 'M31',
    double upDarkHours = 4.0,
    double maxAlt = 65.0,
  }) => ForecastTargetUp(
    targetId: id,
    targetName: name,
    upDarkHours: upDarkHours,
    maxAltitudeDeg: maxAlt,
  );

  NightForecast night({
    double darkHours = 8.0,
    double clearDarkHours = 6.0,
    double meanCloud = 0.2,
    List<ForecastTargetUp>? targets,
  }) => NightForecast(
    nightDateLocal: nightDate,
    astronomicalDuskUtc: DateTime.utc(2026, 5, 31, 3),
    astronomicalDawnUtc: DateTime.utc(2026, 5, 31, 11),
    darkHours: darkHours,
    clearDarkHours: clearDarkHours,
    meanCloudCoverDuringDark: meanCloud,
    bestTargets: targets ?? [target()],
  );

  group('ForecastTargetUp', () {
    test('equality and JSON round-trip shape', () {
      final a = target();
      final b = target();
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a == target(upDarkHours: 1.0), isFalse);

      final json = a.toJson();
      expect(json['targetId'], 1);
      expect(json['targetName'], 'M31');
      expect(json['upDarkHours'], 4.0);
      expect(json['maxAltitudeDeg'], 65.0);
    });
  });

  group('NightForecast.score', () {
    test('is 0 when darkHours == 0 even with clear time and targets', () {
      final n = night(darkHours: 0, clearDarkHours: 0);
      expect(n.score, 0.0);
    });

    test('is 0 when no project target is up, regardless of clear sky', () {
      final n = night(darkHours: 8, clearDarkHours: 8, targets: const []);
      expect(n.score, 0.0);
    });

    test(
      'equals the clear fraction of the dark window when a target is up',
      () {
        final n = night(darkHours: 8, clearDarkHours: 6);
        expect(n.score, closeTo(0.75, 1e-9));
      },
    );

    test('rises as clearDarkHours rises (monotonic in clear time)', () {
      final low = night(darkHours: 8, clearDarkHours: 2);
      final high = night(darkHours: 8, clearDarkHours: 7);
      expect(high.score, greaterThan(low.score));
      expect(low.score, closeTo(0.25, 1e-9));
      expect(high.score, closeTo(0.875, 1e-9));
    });

    test('a fully clear, target-up night scores 1.0', () {
      final n = night(darkHours: 8, clearDarkHours: 8);
      expect(n.score, 1.0);
    });
  });

  group('NightForecast.unavailable', () {
    test('produces forecastAvailable=false, reason, and zero score', () {
      final n = NightForecast.unavailable(nightDate, 'forecast feed offline');
      expect(n.forecastAvailable, isFalse);
      expect(n.unavailableReason, 'forecast feed offline');
      expect(n.nightDateLocal, nightDate);
      expect(n.darkHours, 0.0);
      expect(n.clearDarkHours, 0.0);
      expect(n.meanCloudCoverDuringDark, 0.0);
      expect(n.astronomicalDuskUtc, isNull);
      expect(n.astronomicalDawnUtc, isNull);
      expect(n.bestTargets, isEmpty);
      expect(n.score, 0.0);
    });
  });

  group('NightForecast equality and JSON', () {
    test('value equality and hashCode', () {
      expect(night(), equals(night()));
      expect(night().hashCode, night().hashCode);
      expect(night() == night(clearDarkHours: 1.0), isFalse);
    });

    test('toJson serializes timestamps as ISO-8601 UTC and includes score', () {
      final json = night(darkHours: 8, clearDarkHours: 6).toJson();
      expect(json['nightDateLocal'], nightDate.toUtc().toIso8601String());
      expect(
        json['astronomicalDuskUtc'],
        DateTime.utc(2026, 5, 31, 3).toIso8601String(),
      );
      expect(json['darkHours'], 8.0);
      expect(json['clearDarkHours'], 6.0);
      expect(json['meanCloudCoverDuringDark'], 0.2);
      expect((json['bestTargets'] as List).length, 1);
      expect(json['forecastAvailable'], true);
      expect(json['unavailableReason'], isNull);
      expect(json['score'], closeTo(0.75, 1e-9));
    });

    test('unavailable night serializes null twilight and its reason', () {
      final json = NightForecast.unavailable(nightDate, 'polar day').toJson();
      expect(json['astronomicalDuskUtc'], isNull);
      expect(json['astronomicalDawnUtc'], isNull);
      expect(json['forecastAvailable'], false);
      expect(json['unavailableReason'], 'polar day');
      expect(json['score'], 0.0);
      expect(json['bestTargets'], isEmpty);
    });
  });

  group('WeekForecast.bestNight', () {
    test('returns null when there are no nights', () {
      const week = WeekForecast(nights: []);
      expect(week.bestNight, isNull);
    });

    test('returns null when every night is unavailable', () {
      final week = WeekForecast(
        nights: [
          NightForecast.unavailable(nightDate, 'offline'),
          NightForecast.unavailable(
            nightDate.add(const Duration(days: 1)),
            'offline',
          ),
        ],
      );
      expect(week.bestNight, isNull);
    });

    test(
      'ignores unavailable nights and picks the max-score available one',
      () {
        final good = night(darkHours: 8, clearDarkHours: 8); // score 1.0
        final mediocre = night(darkHours: 8, clearDarkHours: 4); // score 0.5
        final week = WeekForecast(
          nights: [
            mediocre,
            NightForecast.unavailable(nightDate, 'offline'),
            good,
          ],
        );
        expect(week.bestNight, same(good));
        expect(week.bestNight!.score, 1.0);
      },
    );

    test('picks max score across available nights', () {
      final a = night(darkHours: 10, clearDarkHours: 3); // 0.3
      final b = night(darkHours: 10, clearDarkHours: 9); // 0.9
      final c = night(darkHours: 10, clearDarkHours: 6); // 0.6
      final week = WeekForecast(nights: [a, b, c]);
      expect(week.bestNight, same(b));
    });

    test('a clear-but-no-target night never wins over a target-up night', () {
      final clearNoTarget = night(
        darkHours: 8,
        clearDarkHours: 8,
        targets: const [],
      ); // score 0.0
      final dimWithTarget = night(darkHours: 8, clearDarkHours: 1); // 0.125
      final week = WeekForecast(nights: [clearNoTarget, dimWithTarget]);
      expect(week.bestNight, same(dimWithTarget));
    });
  });

  group('WeekForecast.unavailable', () {
    test('produces available=false, reason, and no nights', () {
      const week = WeekForecast.unavailable('no site location configured');
      expect(week.available, isFalse);
      expect(week.unavailableReason, 'no site location configured');
      expect(week.nights, isEmpty);
      expect(week.bestNight, isNull);
    });
  });

  group('WeekForecast equality and JSON', () {
    test('value equality', () {
      final w1 = WeekForecast(nights: [night()]);
      final w2 = WeekForecast(nights: [night()]);
      expect(w1, equals(w2));
      expect(w1.hashCode, w2.hashCode);
    });

    test('JSON round-trip shape', () {
      final week = WeekForecast(
        nights: [
          night(darkHours: 8, clearDarkHours: 6),
          NightForecast.unavailable(
            nightDate.add(const Duration(days: 1)),
            'offline',
          ),
        ],
      );
      final json = week.toJson();
      expect((json['nights'] as List).length, 2);
      expect(json['available'], true);
      expect(json['unavailableReason'], isNull);
      final firstNight = (json['nights'] as List).first as Map;
      expect(firstNight['score'], closeTo(0.75, 1e-9));
    });
  });
}
