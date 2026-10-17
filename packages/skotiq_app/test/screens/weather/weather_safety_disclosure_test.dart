// The Weather screen must not claim the sky is being watched when it is not.
//
// Audit 2026-07-29: with "Enable weather safety" OFF the screen showed a green
// shield, "Safety Status — Conditions safe for imaging", and a Current Settings
// panel reading "Auto-Park: Enabled" — pixel-identical to the monitoring-on
// state. The provider reports `safe` when nothing was evaluated (there is no
// verdict to act on), so the copy has to be derived from the monitoring/armed
// flags instead of from the status alone.
//
// These test the copy decisions directly. The flags they consume are covered by
// skotiq_core/test/providers/weather_safety_monitoring_disclosure_test.dart;
// together the two cover settings -> flags -> rendered words. A full
// WeatherScreen pump is deliberately NOT used: that screen owns a live map
// (network tiles) and a 5-minute evaluation timer, which makes it slow and
// flaky for what is a pure text decision.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('weatherSafetyStatusText', () {
    test('says NOT MONITORING when weather safety is off', () {
      final text = weatherSafetyStatusText(
        // The provider hands the UI `safe` here purely because it has no
        // verdict to give — the case that must not read as a green all-clear.
        status: WeatherSafetyStatus.safe,
        monitoring: false,
      );

      expect(text, contains('Not monitoring'));
      expect(text, isNot(contains('safe for imaging')));
    });

    test('monitoring off wins over any status the provider reports', () {
      for (final status in WeatherSafetyStatus.values) {
        expect(
          weatherSafetyStatusText(status: status, monitoring: false),
          contains('Not monitoring'),
          reason: '$status must not be dressed up as a monitored verdict',
        );
      }
    });

    test('reports the real verdict while monitoring', () {
      expect(
        weatherSafetyStatusText(
          status: WeatherSafetyStatus.safe,
          monitoring: true,
        ),
        'Conditions safe for imaging',
      );
      expect(
        weatherSafetyStatusText(
          status: WeatherSafetyStatus.unsafe,
          monitoring: true,
        ),
        'Unsafe conditions detected',
      );
    });

    test('a snooze discloses that safety is unknown', () {
      final now = DateTime(2026, 7, 29, 22, 0);
      final text = weatherSafetyStatusText(
        status: WeatherSafetyStatus.snoozed,
        monitoring: true,
        snoozeUntil: now.add(const Duration(minutes: 15)),
        now: now,
      );

      expect(text, contains('15 more minutes'));
      expect(text, contains('safety unknown'));
    });
  });

  group('weatherPolicyArmedLabel', () {
    test('only says Enabled when the policy would actually fire', () {
      expect(weatherPolicyArmedLabel(armed: true, toggledOn: true), 'Enabled');
    });

    test('a toggle that is on but disarmed is reported as such', () {
      // The reported defect: "Auto-Park: Enabled" in green while the composed
      // gate (master switch AND Sequencer policy AND this toggle) was false.
      expect(
        weatherPolicyArmedLabel(armed: false, toggledOn: true),
        'On, not armed',
      );
    });

    test('a toggle that is off is Disabled', () {
      expect(
        weatherPolicyArmedLabel(armed: false, toggledOn: false),
        'Disabled',
      );
    });
  });
}
