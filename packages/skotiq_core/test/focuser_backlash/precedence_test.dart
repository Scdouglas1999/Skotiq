import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/focuser_backlash_calibration.dart';
import 'package:skotiq_core/src/services/focuser_backlash/effective_focuser_backlash.dart';

import 'fixtures.dart';

void main() {
  group('an operator-entered figure outranks a measured one', () {
    test('a non-zero afBacklashIn wins outright', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 350,
        operatorCompensationEnabled: true,
        measured: recordFor(),
      );

      expect(effective.origin, FocuserBacklashOrigin.operatorEntered);
      expect(effective.steps, 350);
      expect(effective.provenance, 'the value you entered');
      expect(effective.record, isNull);
      expect(effective.hasFigure, isTrue);
    });

    test('it wins even with nothing measured', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 350,
        operatorCompensationEnabled: true,
        measured: null,
      );

      expect(effective.origin, FocuserBacklashOrigin.operatorEntered);
      expect(effective.steps, 350);
    });

    test('the operator ordering is best-first in the enum itself', () {
      expect(
        FocuserBacklashOrigin.operatorEntered.index,
        lessThan(FocuserBacklashOrigin.measured.index),
      );
      expect(
        FocuserBacklashOrigin.measured.index,
        lessThan(FocuserBacklashOrigin.none.index),
      );
    });
  });

  group('the measured figure is used only when theirs is the shipped 0', () {
    test('105 steps from the measurement, with its provenance', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(),
      );

      expect(effective.origin, FocuserBacklashOrigin.measured);
      expect(effective.steps, 105);
      expect(effective.record, isNotNull);
      expect(effective.hasFigure, isTrue);
    });

    test(
      'the provenance states the date, the position and the temperature',
      () {
        final effective = resolveEffectiveFocuserBacklash(
          operatorEnteredSteps: 0,
          operatorCompensationEnabled: true,
          measured: recordFor(),
        );

        // Backlash varies along the travel, so the position is never left out.
        expect(effective.provenance, contains('position 6620'));
        expect(effective.provenance, contains('2026-09-14'));
        expect(effective.provenance, contains('14.5 °C'));
        expect(
          '${effective.steps} steps, ${effective.provenance}',
          '105 steps, measured on 2026-09-14 at position 6620, 14.5 °C',
        );
      },
    );

    test('a driver with no thermometer still names date and position', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(temperature: null),
      );

      expect(effective.provenance, contains('position 6620'));
      expect(effective.provenance, isNot(contains('°C')));
    });

    test('a figure measured elsewhere in the travel says where', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(steps: 83, position: 2500, temperature: 9.0),
      );

      expect(effective.steps, 83);
      expect(effective.provenance, contains('position 2500'));
    });
  });

  group('a measured zero is not a figure', () {
    test('no measurable backlash resolves to none', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(steps: 0, measurable: false),
      );

      expect(effective.origin, FocuserBacklashOrigin.none);
      expect(effective.steps, 0);
      expect(effective.hasFigure, isFalse);
      expect(effective.record, isNull);
    });

    test('and it says so, with the resolution it was measured against', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(steps: 0, measurable: false),
      );

      expect(effective.provenance, contains('15 steps'));
      expect(effective.provenance, contains('detectable'));
      expect(effective.provenance, contains('2026-09-14'));
    });
  });

  group('nothing known', () {
    test('an untouched setting and an uncalibrated focuser give none', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: null,
      );

      expect(effective.origin, FocuserBacklashOrigin.none);
      expect(effective.steps, 0);
      expect(effective.hasFigure, isFalse);
      expect(effective.provenance, contains('has not been measured'));
    });

    test('an unusable record is treated as never measured', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 0,
        operatorCompensationEnabled: true,
        measured: recordFor(steps: -40),
      );

      expect(effective.origin, FocuserBacklashOrigin.none);
      expect(effective.steps, 0);
    });
  });

  group('compensation switched off', () {
    // With `af_backlash_comp_method` = "None" the wire config already sends
    // `backlash_compensation: 0`, so a figure the operator typed never reaches
    // the engine. Reporting it as in force would be untrue, and would hide the
    // measured figure that IS applied — `measured_backlash_in` is ungated,
    // because it sizes the final run-up rather than the sweep's overshoots.
    test('a typed figure that is switched off is not reported as in force', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 200,
        operatorCompensationEnabled: false,
        measured: null,
      );

      expect(effective.origin, FocuserBacklashOrigin.none);
      expect(effective.steps, 0);
      expect(effective.switchedOffOperatorSteps, 200);
      expect(effective.provenance, contains('switched off'));
    });

    test('the measured figure applies while theirs is switched off', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 200,
        operatorCompensationEnabled: false,
        measured: recordFor(steps: 105),
      );

      expect(effective.origin, FocuserBacklashOrigin.measured);
      expect(effective.steps, 105);
      // And their figure is still named, so a surface can say why the number
      // beside it is not the one being used.
      expect(effective.switchedOffOperatorSteps, 200);
    });

    test(
      'switching compensation off changes nothing when they typed no figure',
      () {
        final effective = resolveEffectiveFocuserBacklash(
          operatorEnteredSteps: 0,
          operatorCompensationEnabled: false,
          measured: recordFor(steps: 105),
        );

        expect(effective.origin, FocuserBacklashOrigin.measured);
        expect(effective.steps, 105);
        expect(effective.switchedOffOperatorSteps, isNull);
      },
    );

    test('a figure in force reports nothing switched off', () {
      final effective = resolveEffectiveFocuserBacklash(
        operatorEnteredSteps: 200,
        operatorCompensationEnabled: true,
        measured: recordFor(steps: 105),
      );

      expect(effective.origin, FocuserBacklashOrigin.operatorEntered);
      expect(effective.steps, 200);
      expect(effective.switchedOffOperatorSteps, isNull);
    });
  });

  test('the figure carried forward is the one that was measured', () {
    final calibration = FocuserBacklashResult.tryParse(
      // The real run, so the chain from native JSON to applied figure is
      // covered end to end rather than from a hand-made record.
      '{"outcome":"measured","calibration":${_measuredCalibration()}}',
    )!.calibration!;

    final effective = resolveEffectiveFocuserBacklash(
      operatorEnteredSteps: 0,
      operatorCompensationEnabled: true,
      measured: calibration.toRecord(),
    );

    expect(effective.steps, 105);
    expect(effective.origin, FocuserBacklashOrigin.measured);
    expect(effective.provenance, contains('position 6620'));
  });
}

String _measuredCalibration() =>
    '{"steps":105,"vertex_difference":105,"measurable":true,'
    '"resolution_limit_steps":15.0,'
    '"below":{"approach":"from_below","points":[{"position":6440,"hfr":11.2}],'
    '"optimum_position":6620,"r_squared":0.99,"method":"Quadratic"},'
    '"above":{"approach":"from_above","points":[{"position":6515,"hfr":3.1}],'
    '"optimum_position":6515,"r_squared":0.98,"method":"Quadratic"},'
    '"measured_at_position":6620,"clearance_steps":400,'
    '"reversal_budget_steps":760,"reversal_budget_at_vertex_steps":580,'
    '"confidence":"high",'
    '"confidence_reason":"Both directions fitted well.",'
    '"context":{"focuser_device_id":"zwo-eaf-1",'
    '"taken_at":"2026-09-14T23:11:04Z","temperature_celsius":14.5,'
    '"app_version":"7.0.0+27"}}';
