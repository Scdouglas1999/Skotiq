import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fakes/fake_network_client.dart';

void main() {
  test('remote flat output path is never created on the controller', () async {
    final root = await Directory.systemTemp.createTemp('skotiq-flat-path-');
    addTearDown(() => root.delete(recursive: true));
    final nested = '${root.path}/host-only/date/filter';

    await prepareFlatOutputDirectory(nested, createLocally: false);

    expect(Directory(nested).existsSync(), isFalse);
  });

  test('local flat output path is created recursively', () async {
    final root = await Directory.systemTemp.createTemp('skotiq-flat-path-');
    addTearDown(() => root.delete(recursive: true));
    final nested = '${root.path}/local/date/filter';

    await prepareFlatOutputDirectory(nested, createLocally: true);

    expect(Directory(nested).existsSync(), isTrue);
  });

  test('remote flat output path must be writable on the host', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/files/validate',
        method: 'POST',
        body: '''
          {"valid":true,"exists":true,"writable":true,
          "normalizedPath":"/host/flats"}
        ''',
      );
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 8080,
      httpClient: fake,
      autoConnectWebSocket: false,
    );

    final path = await validateRemoteFlatOutputDirectory(
      backend,
      '/host/flats/.',
    );

    expect(path, '/host/flats');
    expect(fake.requests.single.path, '/api/files/validate');
    expect(fake.requests.single.body, contains('"mustExist":true'));
    expect(fake.requests.single.body, contains('"mustBeWritable":true'));
  });

  test('remote flat output path rejects an invalid host directory', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/files/validate',
        method: 'POST',
        body:
            '{"valid":false,"exists":false,"writable":false,"error":"Path is required"}',
      );
    final backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 8080,
      httpClient: fake,
      autoConnectWebSocket: false,
    );

    await expectLater(
      validateRemoteFlatOutputDirectory(backend, '/missing'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Path is required'),
        ),
      ),
    );
  });
}
