// When the link of a client whose manual action holds the run ends, the host
// turns that hold into an ordinary pause: the hold is released and the run
// is never resumed by it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

import '../headless_api/handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  late _MockSequencerBackend backend;
  late ProviderContainer container;
  late HeadlessApiServer server;
  final released = <String>[];

  setUp(() async {
    released.clear();
    backend = _MockSequencerBackend();
    when(
      () => backend.sequencerReleaseActionHold(holder: any(named: 'holder')),
    ).thenAnswer((invocation) async {
      released.add(invocation.namedArguments[#holder] as String);
      return true;
    });
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.0.0', buildNumber: 1),
        ),
        sequencerBackendProvider.overrideWithValue(backend),
      ],
    );
    server = HeadlessApiServer(
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      webSocketHeartbeatInterval: const Duration(hours: 1),
      webSocketHeartbeatTimeout: const Duration(hours: 2),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
  });

  Future<WebSocket> connect() async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${server.actualPort}'
      '/events?token=admin-token&version=6.0.0',
    );
    final first = await socket.first;
    expect((jsonDecode(first as String) as Map)['type'], 'collaboration_state');
    return socket;
  }

  test("a client's last link closing ends its hold as a plain pause", () async {
    final first = await connect();
    final second = await connect();
    await _until(() => server.connectedClientCount == 2);

    await first.close();
    await _until(() => server.connectedClientCount == 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(released, isEmpty, reason: 'the client still has a link open');

    await second.close();
    await _until(() => released.isNotEmpty);

    expect(released, hasLength(1));
    expect(
      released.single,
      isNot('host'),
      reason: "the host's own action is never released by a link",
    );
    verifyNever(() => backend.sequencerResume());
    verifyNever(
      () => backend.sequencerEndActionHold(holder: any(named: 'holder')),
    );
  });
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
