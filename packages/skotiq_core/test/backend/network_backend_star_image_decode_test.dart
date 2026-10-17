// phd2GetStarImage and guiderGetStarImage decode the SAME star-image JSON
// envelope through the shared private `_starImageFromJson`. This pins that both
// routes map every field identically (frame/width/height/starX/starY/pixels)
// from the same wire payload.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

void main() {
  test('phd2 and guider star-image routes decode identical fields', () async {
    final pixels = Uint8List.fromList(const [0, 1, 2, 250, 128, 64]);
    final body = jsonEncode({
      'frame': 42,
      'width': 3,
      'height': 2,
      'starX': 1.25,
      'starY': 0.5,
      'pixels': base64Encode(pixels),
    });

    final fake = FakeNetworkClient()
      ..setResponse('/api/phd2/star-image', method: 'GET', body: body)
      ..setResponse('/api/guider/star-image', method: 'GET', body: body);

    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    final viaPhd2 = await backend.phd2GetStarImage();
    final viaGuider = await backend.guiderGetStarImage(
      deviceId: 'simulator:guider-1',
    );

    expect(viaPhd2.frame, equals(viaGuider.frame));
    expect(viaPhd2.width, equals(viaGuider.width));
    expect(viaPhd2.height, equals(viaGuider.height));
    expect(viaPhd2.starX, equals(viaGuider.starX));
    expect(viaPhd2.starY, equals(viaGuider.starY));
    expect(viaPhd2.pixels, equals(viaGuider.pixels));

    // And the decode is correct against the source payload.
    expect(viaPhd2.frame, equals(42));
    expect(viaPhd2.width, equals(3));
    expect(viaPhd2.height, equals(2));
    expect(viaPhd2.starX, equals(1.25));
    expect(viaPhd2.starY, equals(0.5));
    expect(viaPhd2.pixels, equals(pixels));
  });
}
