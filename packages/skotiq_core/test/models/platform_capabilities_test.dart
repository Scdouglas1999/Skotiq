import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('PlatformCapabilityMatrix', () {
    test('marks ASCOM COM as Windows-only', () {
      final ascom = PlatformCapabilityMatrix.rows.singleWhere(
        (row) => row.backend == 'ascom',
      );

      expect(ascom.isAvailableOn('windows'), isTrue);
      expect(ascom.isAvailableOn('linux'), isFalse);
      expect(ascom.isAvailableOn('macos'), isFalse);
      expect(ascom.reasonFor('linux'), contains('Windows COM drivers'));
    });

    test('serializes deterministic unsupported reasons for API responses', () {
      final report = PlatformCapabilityMatrix.forPlatform('linux').toJson();
      final drivers = report['drivers'] as List<dynamic>;
      final ascom = drivers.cast<Map<String, dynamic>>().singleWhere((driver) {
        return driver['backend'] == 'ascom';
      });

      expect(report['platform'], 'linux');
      expect(ascom['status'], 'unsupported');
      expect(ascom['unsupportedReason'], contains('ASCOM COM requires'));
    });

    test('serializes capability-gated backends for API responses', () {
      final report = PlatformCapabilityMatrix.forPlatform('windows').toJson();
      final drivers = (report['drivers'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final native = drivers.singleWhere((driver) {
        return driver['backend'] == 'native';
      });
      final simulator = drivers.singleWhere((driver) {
        return driver['backend'] == 'simulator';
      });

      expect(native['status'], 'capability-gated');
      expect(native['unsupportedReason'], isNull);
      expect(native['notes'], contains('packaged libraries'));
      expect(simulator['status'], 'capability-gated');
      expect(simulator['notes'], contains('workflow-specific'));
    });

    test('normalizes darwin to macos', () {
      final report = PlatformCapabilityMatrix.forPlatform('darwin');

      expect(report.platform, PlatformCapabilityMatrix.macos);
    });

    test('matches the public driver backend status matrix', () {
      const expected = {
        'ascom': {
          PlatformCapabilityMatrix.windows: 'available',
          PlatformCapabilityMatrix.linux: 'unsupported',
          PlatformCapabilityMatrix.macos: 'unsupported',
        },
        'alpaca': {
          PlatformCapabilityMatrix.windows: 'available',
          PlatformCapabilityMatrix.linux: 'available',
          PlatformCapabilityMatrix.macos: 'available',
        },
        'indi': {
          PlatformCapabilityMatrix.windows: 'available',
          PlatformCapabilityMatrix.linux: 'available',
          PlatformCapabilityMatrix.macos: 'available',
        },
        'native': {
          PlatformCapabilityMatrix.windows: 'capability-gated',
          PlatformCapabilityMatrix.linux: 'capability-gated',
          PlatformCapabilityMatrix.macos: 'capability-gated',
        },
        'simulator': {
          PlatformCapabilityMatrix.windows: 'capability-gated',
          PlatformCapabilityMatrix.linux: 'capability-gated',
          PlatformCapabilityMatrix.macos: 'capability-gated',
        },
      };

      expect(
        PlatformCapabilityMatrix.rows.map((row) => row.backend).toSet(),
        expected.keys.toSet(),
      );

      for (final row in PlatformCapabilityMatrix.rows) {
        final expectedByPlatform = expected[row.backend]!;
        for (final entry in expectedByPlatform.entries) {
          expect(
            row.statusFor(entry.key),
            entry.value,
            reason:
                '${row.label} on ${entry.key} must match public support docs.',
          );
        }
      }
    });
  });
}
