import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('InstructionProgressDetail', () {
    test('decodes structured exposure progress', () {
      final detail = InstructionProgressDetail.fromStructuredData(
        detailKind: 'Exposure',
        detailJson: const {'frame': 3, 'total': 12, 'duration_secs': 180},
      );

      expect(detail, isA<ExposureInstructionProgressDetail>());
      final exposure = detail as ExposureInstructionProgressDetail;
      expect(exposure.frame, 3);
      expect(exposure.total, 12);
      expect(exposure.durationSecs, 180);
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
