// The guider star-image route decodes every field of the host's JSON
// envelope (frame/width/height/starX/starY/pixels).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

void main() {
  test('the guider star image decodes every field', () async {
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
      ..setResponse('/api/guider/star-image', method: 'GET', body: body);

    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    final image = await backend.guiderGetStarImage();

    expect(image.frame, equals(42));
    expect(image.width, equals(3));
    expect(image.height, equals(2));
    expect(image.starX, equals(1.25));
    expect(image.starY, equals(0.5));
    expect(image.pixels, equals(pixels));
  });
}
