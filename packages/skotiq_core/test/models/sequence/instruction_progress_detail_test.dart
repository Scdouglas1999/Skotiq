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
                'test/fixtures/progress_detail_kinds.json',
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
        kinds.keys.map(decode),
        everyElement(isNot(isA<UnknownInstructionProgressDetail>())),
      );
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
