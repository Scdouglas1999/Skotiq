// Relay registration / auth / capacity / rate-limit behaviour, exercised
// against a real (loopback, ephemeral-port) RelayServer with real WebSocket
// uplinks. These talk the raw mux control protocol so the test pins the wire
// contract the appliance and phone clients depend on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:test/test.dart';

/// One decoded control message plus the raw socket, so a test can keep the
/// uplink open (to stay "online") or close it.
class _Uplink {
  final WebSocket ws;
  final Map<String, dynamic> firstReply;
  _Uplink(this.ws, this.firstReply);
}

Uint8List _control(Map<String, dynamic> message) => MuxFrame(
  kMuxControlStreamId,
  MuxFrameType.control,
  Uint8List.fromList(utf8.encode(jsonEncode(message))),
).encode();

Map<String, dynamic> _decodeControl(dynamic message) {
  final bytes = message is Uint8List
      ? message
      : Uint8List.fromList(message as List<int>);
  final frame = MuxFrame.decodeExact(bytes);
  expect(frame.type, MuxFrameType.control);
  expect(frame.streamId, kMuxControlStreamId);
  return jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
}

void main() {
  late RelayServer server;

  Future<void> startServer({RelayServerConfig? config}) async {
    server = RelayServer(config ?? const RelayServerConfig(port: 0));
    await server.start();
  }

  tearDown(() async {
    await server.stop();
  });

  /// Register an uplink and return it with its first control reply still
  /// connected (caller decides when to close).
  Future<_Uplink> registerUplink({String? id, String? secret}) async {
    final ws = await WebSocket.connect('ws://127.0.0.1:${server.port}/uplink');
    final firstReply = Completer<Map<String, dynamic>>();
    // Single subscription kept alive for the socket's lifetime (a WebSocket
    // is single-subscription). We only assert on the FIRST control frame;
    // later frames are drained so the relay's read loop stays healthy.
    ws.listen(
      (message) {
        if (!firstReply.isCompleted) {
          firstReply.complete(_decodeControl(message));
        }
      },
      onError: (_) {},
      onDone: () {},
    );
    ws.add(
      _control({
        'op': 'register',
        if (id != null) 'applianceId': id,
        if (secret != null) 'secret': secret,
      }),
    );
    final reply = await firstReply.future.timeout(const Duration(seconds: 5));
    return _Uplink(ws, reply);
  }

  test('first registration mints a valid id + secret', () async {
    await startServer();
    final up = await registerUplink();
    expect(up.firstReply['op'], 'registered');
    final id = up.firstReply['applianceId'] as String;
    final secret = up.firstReply['secret'] as String;
    expect(isValidApplianceId(id), isTrue);
    expect(secret, isNotEmpty);
    expect(server.registry.contains(id), isTrue);
    expect(server.onlineApplianceCount, 1);
    await up.ws.close();
  });

  test(
    'returning appliance re-registers with id + secret, no new secret',
    () async {
      await startServer();
      final first = await registerUplink();
      final id = first.firstReply['applianceId'] as String;
      final secret = first.firstReply['secret'] as String;
      await first.ws.close();

      final again = await registerUplink(id: id, secret: secret);
      expect(again.firstReply['op'], 'registered');
      expect(again.firstReply['applianceId'], id);
      expect(
        again.firstReply.containsKey('secret'),
        isFalse,
        reason: 'returning registration must not re-mint a secret',
      );
      await again.ws.close();
    },
  );

  test('wrong secret is rejected with auth_failed', () async {
    await startServer();
    final first = await registerUplink();
    final id = first.firstReply['applianceId'] as String;
    await first.ws.close();

    final bad = await registerUplink(id: id, secret: 'not-the-secret');
    expect(bad.firstReply['op'], 'error');
    expect(bad.firstReply['code'], 'auth_failed');
    await bad.ws.close();
  });

  test('unknown appliance id is rejected', () async {
    await startServer();
    final bad = await registerUplink(id: 'aaaa-bbbb-cccc', secret: 'x');
    expect(bad.firstReply['op'], 'error');
    expect(bad.firstReply['code'], 'auth_failed');
    await bad.ws.close();
  });

  test('repeated auth failures from one IP are rate-limited', () async {
    await startServer(
      config: const RelayServerConfig(port: 0, registrationFailureLimit: 3),
    );
    // Burn through the failure budget.
    for (var i = 0; i < 3; i++) {
      final bad = await registerUplink(id: 'aaaa-bbbb-cccc', secret: 'x$i');
      expect(bad.firstReply['code'], 'auth_failed');
      await bad.ws.close();
    }
    final limited = await registerUplink(id: 'aaaa-bbbb-cccc', secret: 'y');
    expect(limited.firstReply['code'], 'rate_limited');
    await limited.ws.close();
  });

  test('capacity limit refuses new registrations but keeps existing', () async {
    await startServer(
      config: const RelayServerConfig(port: 0, maxAppliances: 1),
    );
    final first = await registerUplink();
    expect(first.firstReply['op'], 'registered');
    final id = first.firstReply['applianceId'] as String;
    final secret = first.firstReply['secret'] as String;

    final overflow = await registerUplink();
    expect(overflow.firstReply['op'], 'error');
    expect(overflow.firstReply['code'], 'capacity');
    await overflow.ws.close();

    // The already-registered appliance can still reconnect.
    await first.ws.close();
    final back = await registerUplink(id: id, secret: secret);
    expect(back.firstReply['op'], 'registered');
    await back.ws.close();
  });

  test('a newer uplink replaces a stale session for the same id', () async {
    await startServer();
    final first = await registerUplink();
    final id = first.firstReply['applianceId'] as String;
    final secret = first.firstReply['secret'] as String;
    expect(server.onlineApplianceCount, 1);

    // Reconnect WITHOUT closing the first socket: relay should evict the
    // stale one (newest wins) and still report exactly one online.
    final second = await registerUplink(id: id, secret: secret);
    expect(second.firstReply['op'], 'registered');
    await pumpEventQueue();
    expect(server.onlineApplianceCount, 1);
    await second.ws.close();
  });

  test('healthz reports counters', () async {
    await startServer();
    final up = await registerUplink();
    final client = HttpClient();
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${server.port}/healthz'),
    );
    final resp = await req.close();
    final body = jsonDecode(await resp.transform(utf8.decoder).join()) as Map;
    expect(resp.statusCode, 200);
    expect(body['status'], 'ok');
    expect(body['appliancesRegistered'], 1);
    expect(body['appliancesOnline'], 1);
    client.close();
    await up.ws.close();
  });

  test('connecting to an offline/unknown appliance is refused', () async {
    await startServer();
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/connect/zzzz-zzzz-zzzz',
    );
    final reply = Completer<Map<String, dynamic>>();
    ws.listen((m) {
      if (!reply.isCompleted) reply.complete(_decodeControl(m));
    });
    final message = await reply.future.timeout(const Duration(seconds: 5));
    expect(message['op'], 'error');
    expect(message['code'], 'appliance_offline');
    await ws.close();
  });

  test('connecting with a malformed appliance id is refused', () async {
    await startServer();
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.port}/connect/not-an-id',
    );
    final reply = Completer<Map<String, dynamic>>();
    ws.listen((m) {
      if (!reply.isCompleted) reply.complete(_decodeControl(m));
    });
    final message = await reply.future.timeout(const Duration(seconds: 5));
    expect(message['op'], 'error');
    expect(message['code'], 'bad_appliance_id');
    await ws.close();
  });

  test('registry persists across restart via the state file', () async {
    final dir = await Directory.systemTemp.createTemp('relay_state_test');
    final statePath = '${dir.path}/state.json';
    try {
      await startServer(
        config: RelayServerConfig(port: 0, stateFilePath: statePath),
      );
      final up = await registerUplink();
      final id = up.firstReply['applianceId'] as String;
      final secret = up.firstReply['secret'] as String;
      await up.ws.close();
      await server.stop();

      // Fresh server, same state file: the appliance must re-auth.
      await startServer(
        config: RelayServerConfig(port: 0, stateFilePath: statePath),
      );
      final back = await registerUplink(id: id, secret: secret);
      expect(back.firstReply['op'], 'registered');
      expect(back.firstReply['applianceId'], id);
      await back.ws.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('new appliance registrations are throttled per source IP', () async {
    await startServer(
      config: const RelayServerConfig(port: 0, newRegistrationLimitPerIp: 2),
    );
    final first = await registerUplink();
    expect(first.firstReply['op'], 'registered');
    final id = first.firstReply['applianceId'] as String;
    final secret = first.firstReply['secret'] as String;
    final second = await registerUplink();
    expect(second.firstReply['op'], 'registered');
    final third = await registerUplink();
    expect(third.firstReply['code'], 'rate_limited');

    await first.ws.close();
    await second.ws.close();
    await third.ws.close();
    final back = await registerUplink(id: id, secret: secret);
    expect(back.firstReply['op'], 'registered');
    await back.ws.close();
  });

  test(
    're-opening a client stream resets the previous uplink binding',
    () async {
      await startServer();
      final uplink = await _watchUplink(server);
      final id = uplink.registered['applianceId'] as String;
      final client = await _watchClient(server, id);
      client.ws.add(MuxFrame(7, MuxFrameType.open, Uint8List(0)).encode());
      await _until(
        () =>
            uplink.frames.where((f) => f.type == MuxFrameType.open).length == 1,
      );
      client.ws.add(MuxFrame(7, MuxFrameType.open, Uint8List(0)).encode());
      await _until(
        () =>
            uplink.frames.where((f) => f.type == MuxFrameType.open).length ==
                2 &&
            uplink.frames.any((f) => f.type == MuxFrameType.reset),
      );
      final openIndexes = <int>[
        for (var i = 0; i < uplink.frames.length; i++)
          if (uplink.frames[i].type == MuxFrameType.open) i,
      ];
      final resetIndex = uplink.frames.indexWhere(
        (f) => f.type == MuxFrameType.reset,
      );
      expect(resetIndex, greaterThan(openIndexes.first));
      expect(resetIndex, lessThan(openIndexes.last));
      await client.ws.close();
      await uplink.ws.close();
    },
  );

  test('a client cannot open more streams than the per-client cap', () async {
    await startServer(
      config: const RelayServerConfig(port: 0, maxStreamsPerClient: 2),
    );
    final uplink = await _watchUplink(server);
    final id = uplink.registered['applianceId'] as String;
    final client = await _watchClient(server, id);
    for (var streamId = 1; streamId <= 3; streamId++) {
      client.ws.add(
        MuxFrame(streamId, MuxFrameType.open, Uint8List(0)).encode(),
      );
    }
    await _until(
      () => client.frames.any(
        (frame) => frame.type == MuxFrameType.reset && frame.streamId == 3,
      ),
    );
    final reset = client.frames.firstWhere(
      (frame) => frame.type == MuxFrameType.reset && frame.streamId == 3,
    );
    expect(utf8.decode(reset.payload), contains('too many open streams'));
    expect(uplink.frames.where((f) => f.type == MuxFrameType.open).length, 2);
    await client.ws.close();
    await uplink.ws.close();
  });

  test('concurrent registry writes do not drop appliances', () async {
    await startServer();
    final dir = await Directory.systemTemp.createTemp('relay_persist_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final statePath = '${dir.path}/state.json';
    final registry = RelayApplianceRegistry(path: statePath);
    await Future.wait([
      for (var i = 0; i < 24; i++)
        registry.register('appliance-$i', 'secret-$i'),
    ]);
    final loaded = RelayApplianceRegistry(path: statePath);
    await loaded.load();
    expect(loaded.count, 24);
    for (var i = 0; i < 24; i++) {
      expect(loaded.verify('appliance-$i', 'secret-$i'), isTrue);
    }
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for a relay frame');
    }
    await Future<void>.delayed(const Duration(milliseconds: 15));
  }
}

class _WatchedSocket {
  _WatchedSocket(this.ws, this.frames, this.registered);
  final WebSocket ws;
  final List<MuxFrame> frames;
  final Map<String, dynamic> registered;
}

Future<_WatchedSocket> _watchUplink(RelayServer relay) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:${relay.port}/uplink');
  final frames = <MuxFrame>[];
  final registered = Completer<Map<String, dynamic>>();
  ws.listen(
    (message) {
      final frame = _frame(message);
      frames.add(frame);
      if (!registered.isCompleted && frame.type == MuxFrameType.control) {
        registered.complete(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
      }
    },
    onError: (_) {},
    onDone: () {},
  );
  ws.add(_control({'op': 'register'}));
  return _WatchedSocket(
    ws,
    frames,
    await registered.future.timeout(const Duration(seconds: 5)),
  );
}

Future<_WatchedSocket> _watchClient(
  RelayServer relay,
  String applianceId,
) async {
  final ws = await WebSocket.connect(
    'ws://127.0.0.1:${relay.port}/connect/$applianceId',
  );
  final frames = <MuxFrame>[];
  final connected = Completer<Map<String, dynamic>>();
  ws.listen(
    (message) {
      final frame = _frame(message);
      frames.add(frame);
      if (!connected.isCompleted && frame.type == MuxFrameType.control) {
        connected.complete(
          jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>,
        );
      }
    },
    onError: (_) {},
    onDone: () {},
  );
  final reply = await connected.future.timeout(const Duration(seconds: 5));
  expect(reply['op'], 'connected');
  return _WatchedSocket(ws, frames, reply);
}

MuxFrame _frame(dynamic message) {
  final bytes = message is Uint8List
      ? message
      : Uint8List.fromList(message as List<int>);
  return MuxFrame.decodeExact(bytes);
}
