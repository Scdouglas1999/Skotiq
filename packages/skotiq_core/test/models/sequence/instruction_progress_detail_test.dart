import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  group('InstructionProgressDetail', () {
    // The same file the native side's `progress_detail_kinds_match_the_app`
    // test serializes its `ProgressDetail` values against.
    final kinds =
        jsonDecode(
              File(
                '../../test_fixtures/wire_words/progress_detail_kinds.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    InstructionProgressDetail decode(String kind) =>
        InstructionProgressDetail.fromStructuredData(
          detailKind: kind,
          detailJson: kinds[kind],
        );

    test('reads every kind the app draws from the fields the host sends', () {
      expect(
        decode('Exposure'),
        const ExposureInstructionProgressDetail(
          frame: 3,
          total: 12,
          durationSecs: 180,
        ),
      );
      expect(
        decode('Center'),
        const CenterInstructionProgressDetail(
          attempt: 2,
          maxAttempts: 3,
          lastSeparationArcsec: 41.5,
          solvedRaHours: 5.5,
          solvedDecDegrees: -5.25,
        ),
      );
      expect(
        decode('Autofocus'),
        const AutofocusInstructionProgressDetail(
          step: 5,
          totalSteps: 9,
          currentHfr: 2.75,
          starCount: 41,
        ),
      );
      expect(
        decode('Thermal'),
        const ThermalInstructionProgressDetail(
          currentTempC: -4.5,
          targetTempC: -10,
          coolerPowerPercent: 62,
        ),
      );
      expect(
        decode('MeridianFlipRetry'),
        const MeridianFlipRetryProgressDetail(
          failedAttempt: 2,
          maxAttempts: 4,
          retryInSecs: 60,
        ),
      );
      expect(
        decode('Filter'),
        const FilterInstructionProgressDetail(name: 'Ha', position: 4),
      );
      expect(
        decode('SmartExposure'),
        const SmartExposureInstructionProgressDetail(
          currentFilter: 'OIII',
          planIndex: 1,
          totalPlans: 3,
          frameInPlan: 7,
          totalFrames: 20,
        ),
      );
      expect(
        decode('TargetWaiting'),
        const TargetWaitingProgressDetail(
          target: 'M31',
          condition: 'altitude ≥ 30.0°',
          altitudeDeg: 12,
          floorDeg: 25,
        ),
      );
      expect(
        decode('FlipHold'),
        const FlipHoldProgressDetail(
          exposureSecs: 300,
          firesInSecs: 120,
          hourAngleHours: -0.05,
          thresholdMin: 5,
        ),
      );
      expect(
        decode('ExposureAdjusted'),
        const ExposureAdjustedProgressDetail(
          adaptedSecs: 302,
          nominalSecs: 300,
          skyBrightnessMag: 19.2,
          filter: 'L',
          reasonWire: 'adapted',
          unchanged: false,
        ),
      );
      expect(
        kinds.keys.map(decode),
        everyElement(isNot(isA<UnknownInstructionProgressDetail>())),
      );
      for (final kind in kinds.keys) {
        expect(decode(kind).wire.detailJson, kinds[kind], reason: kind);
      }
    });

    test('a flip step report reads as the flip event it carries', () {
      const raw = {
        'StepStarted': {
          'step': 'SlewingToTarget',
          'step_index': 2,
          'total_steps': 9,
        },
      };
      final detail = InstructionProgressDetail.fromStructuredData(
        detailKind: kMeridianFlipProgressDetailKind,
        detailJson: raw,
      );
      expect(
        detail,
        const MeridianFlipStepProgressDetail(
          event: MeridianFlipStepStarted(
            step: FlipStep.slewingToTarget,
            stepIndex: 2,
            totalSteps: 9,
          ),
          rawJson: raw,
        ),
      );
      expect(detail.wire.detailJson, raw);
    });

    test('a host from before a field was added leaves it null', () {
      final detail = InstructionProgressDetail.fromStructuredData(
        detailKind: 'Thermal',
        detailJson: const {'current_temp_c': 3.0, 'target_temp_c': -10.0},
      );
      expect(
        detail,
        const ThermalInstructionProgressDetail(
          currentTempC: 3,
          targetTempC: -10,
        ),
      );
    });

    test('preserves unknown structured progress without throwing', () {
      final detail = InstructionProgressDetail.fromStructuredData(
        detailKind: 'NewFutureProgress',
        detailJson: const {'foo': 'bar'},
      );

      expect(detail, isA<UnknownInstructionProgressDetail>());
      final unknown = detail as UnknownInstructionProgressDetail;
      expect(unknown.kind, 'NewFutureProgress');
      expect(unknown.rawJson, {'foo': 'bar'});
    });
  });
}
