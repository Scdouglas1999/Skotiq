import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('DriverBackendDescription', () {
    test('keeps ASCOM COM labeled as Windows-only', () {
      expect(DriverType.ascom.shortLabel, 'ASCOM COM');
      expect(DriverType.ascom.description, contains('Windows-only'));
      expect(DriverType.ascom.description, contains('Alpaca'));
    });

    test('keeps native and INDI descriptions capability-scoped', () {
      expect(DriverType.native.description, contains('release includes'));
      expect(DriverType.indi.description, contains('reachable INDI server'));
      expect(DriverType.indi.description, contains('depends on the driver'));
    });
  });
}
