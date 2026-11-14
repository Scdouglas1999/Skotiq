import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('histogram256FromRawU16 maps high byte to 256 bins', () async {
    final raw = Uint16List.fromList([0, 255, 256, 65535]);
    final bins = (await histogram256FromRawU16(raw))!;
    expect(bins[0], 2); // 0 and 255 → high byte 0
    expect(bins[1], 1); // 256 → high byte 1
    expect(bins[255], 1); // 65535 → high byte 255
    expect(bins.fold<int>(0, (a, b) => a + b), raw.length);
  });

  test('large raw histograms yield and count every sample exactly', () async {
    final raw = Uint16List(1024 * 1024);
    for (var i = 0; i < raw.length; i++) {
      raw[i] = i & 0xffff;
    }
    var completed = false;
    final result = histogram256FromRawU16(raw).then((bins) {
      completed = true;
      return bins;
    });

    await Future<void>.delayed(Duration.zero);
    expect(
      completed,
      isFalse,
      reason: 'other event-loop work must run before the full scan finishes',
    );
    final bins = (await result)!;
    expect(bins, List<int>.filled(256, raw.length ~/ 256));
  });

  test('a discarded histogram stops at the next yield', () async {
    var cancelled = false;
    final result = histogram256FromRawU16(
      Uint16List(1024 * 1024),
      isCancelled: () => cancelled,
    );
    await Future<void>.delayed(Duration.zero);
    cancelled = true;
    expect(await result, isNull);
  });
}
