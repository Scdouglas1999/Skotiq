import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/backend/remote_display_jpeg.dart';

String _meta({required int width, required int height}) => base64Encode(
  utf8.encode(
    jsonEncode({
      'width': width,
      'height': height,
      'histogram': List<int>.filled(256, 0),
      'stats': {
        'min': 0,
        'max': 255,
        'mean': 10.0,
        'median': 10.0,
        'stdDev': 1.0,
        'starCount': 0,
      },
      'exposureTime': 5.0,
      'timestamp': '2026-11-08T03:00:00.000Z',
      'isColor': false,
    }),
  ),
);

void main() {
  // A linked client asks the host for a preview narrower than the sensor;
  // everything drawn over the frame works in sensor pixels.
  test('a narrower preview comes back at the sensor size', () async {
    final small = img.Image(width: 4, height: 2);
    img.fill(small, color: img.ColorRgb8(200, 200, 200));
    small.setPixelRgb(0, 0, 0, 0, 0);
    final jpeg = img.encodeJpg(small, quality: 100);

    final frame = await decodeRemoteJpegWire(
      jpegBytes: jpeg,
      metaHeaderBase64: _meta(width: 8, height: 4),
    );

    expect((frame.width, frame.height), (8, 4));
    expect(frame.displayData, hasLength(8 * 4 * 4));
    // The dark corner pixel covers the 2x2 block it stands for.
    expect(frame.displayData[0], lessThan(100));
    expect(frame.displayData[(1 * 8 + 1) * 4], lessThan(100));
    expect(frame.displayData[(3 * 8 + 7) * 4], greaterThan(150));
  });

  test('a full-size JPEG is used as it is', () async {
    final full = img.Image(width: 8, height: 4);
    final frame = await decodeRemoteJpegWire(
      jpegBytes: img.encodeJpg(full),
      metaHeaderBase64: _meta(width: 8, height: 4),
    );
    expect(frame.displayData, hasLength(8 * 4 * 4));
  });
}
