import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/providers/unified_discovery_provider.dart';

void main() {
  const available = <DriverType>[
    DriverType.native,
    DriverType.ascom,
    DriverType.indi,
    DriverType.alpaca,
    DriverType.simulator,
  ];

  test('startup policy excludes only disabled protocol backends', () {
    expect(
      discoveryBackendsForPolicy(
        available,
        includeIndi: false,
        includeAlpaca: false,
      ),
      <DriverType>[DriverType.native, DriverType.ascom, DriverType.simulator],
    );
  });

  test('manual all-backend policy retains INDI and Alpaca', () {
    expect(
      discoveryBackendsForPolicy(
        available,
        includeIndi: true,
        includeAlpaca: true,
      ),
      available,
    );
  });
}
