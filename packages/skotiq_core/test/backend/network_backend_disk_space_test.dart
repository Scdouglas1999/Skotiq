import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/models/disk_space.dart';

import '../fakes/fakes.dart';

// The host
// knows the folder is missing; the phone must get that answer, not a generic
// failure.
void main() {
  test('a folder the host does not have arrives as pathMissing', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/system/disk-space',
        status: 500,
        // The body exactly as the host writes it: details at the top level.
        body:
            '{"path":"/mnt/astro/captures","kind":"pathMissing",'
            '"error":"Path does not exist; cannot query free space",'
            '"code":"disk_query_failed",'
            '"message":"Path does not exist; cannot query free space"}',
      );
    final backend = NetworkBackend(
      serverHost: 'example.invalid',
      serverPort: 8080,
      webSocketPort: 8080,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    await expectLater(
      backend.getHostCaptureDiskSpace(),
      throwsA(
        isA<DiskSpaceException>()
            .having((e) => e.kind, 'kind', DiskSpaceFailureKind.pathMissing)
            .having((e) => e.path, 'path', '/mnt/astro/captures'),
      ),
    );
  });
}
