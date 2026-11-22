// A GUI linked to another imaging host keeps its Remote Access server
// running, but its API answers 409: the window's devices, runs and data are
// the linked host's. The identity, version and update routes stay open.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

class _LinkedBackend extends Mock implements NetworkBackend {
  @override
  String get serverHost => 'observatory.local';
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late ProviderContainer container;
  late HeadlessApiServer server;
  late HttpClient client;
  late Uri baseUri;

  Future<void> start({required bool linked}) async {
    final backend = _LinkedBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '2.5.0', buildNumber: 5),
        ),
        if (linked)
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
    );
    await server.start();
    client = HttpClient();
    baseUri = Uri.parse('http://127.0.0.1:${server.actualPort}');
  }

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    container.dispose();
  });

  Future<(int, Map<String, dynamic>?)> get(String path) async {
    final request = await client.getUrl(baseUri.resolve(path));
    request.headers.set('x-skotiq-version', '2.5.0');
    request.headers.set('authorization', 'Bearer admin-token');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      body = null;
    }
    return (response.statusCode, body);
  }

  test('a linked window answers its API with 409 naming the host', () async {
    await start(linked: true);
    final (status, body) = await get('/api/sequencer/status');
    expect(status, HttpStatus.conflict);
    expect(body?['code'], 'linked_to_host');
    expect(body?['host'], 'observatory.local');
    expect(body?['message'], contains('observatory.local'));
  });

  test('a linked window still answers its identity and version', () async {
    await start(linked: true);
    expect((await get('/api/info')).$1, isNot(HttpStatus.conflict));
    expect((await get('/api/system/version')).$1, isNot(HttpStatus.conflict));
  });

  test('a window that is not linked answers as before', () async {
    await start(linked: false);
    expect(
      (await get('/api/sequencer/status')).$1,
      isNot(HttpStatus.conflict),
    );
  });
}
