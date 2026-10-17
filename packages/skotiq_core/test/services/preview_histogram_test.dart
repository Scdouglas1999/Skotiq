import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';

void main() {
  test('histogram256FromRawU16 maps high byte to 256 bins', () {
    final raw = Uint16List.fromList([0, 255, 256, 65535]);
    final bins = histogram256FromRawU16(raw);
    expect(bins[0], 2); // 0 and 255 → high byte 0
    expect(bins[1], 1); // 256 → high byte 1
    expect(bins[255], 1); // 65535 → high byte 255
    expect(bins.fold<int>(0, (a, b) => a + b), raw.length);
  });
}
