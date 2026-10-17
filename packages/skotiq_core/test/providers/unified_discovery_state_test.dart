import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('UnifiedDiscoveryState', () {
    test('lastDiscoveryCompletedAt returns newest backend timestamp', () {
      final older = DateTime(2026, 5, 24, 10);
      final newer = DateTime(2026, 5, 24, 12);
      final state = UnifiedDiscoveryState(
        backendStates: {
          DriverType.native: BackendDiscoveryState(
            backend: DriverType.native,
            status: DiscoveryStatus.completed,
            completedAt: older,
          ),
          DriverType.alpaca: BackendDiscoveryState(
            backend: DriverType.alpaca,
            status: DiscoveryStatus.completed,
            completedAt: newer,
          ),
        },
      );

      expect(state.lastDiscoveryCompletedAt, newer);
    });
  });
}
