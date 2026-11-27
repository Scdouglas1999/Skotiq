// The phone's connect flow on fake ports: each way a connect ends leaves the
// state the connection screen words, a superseded connect writes nothing, and
// a link that stays down past the grace re-dials the server it was lost on.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

class _Pairing extends RigPairingService {
  _Pairing()
    : super(
        deviceId: () async => 'mobile:1',
        deviceType: PairingDeviceType.android,
      );

  Object? oneTap;
  final codes = <String>[];
  final oneTapFullAccess = <bool>[];

  @override
  Future<RigPairing> pairOneTap(
    DiscoveredServer host, {
    required String deviceName,
    bool fullAccess = false,
  }) async {
    oneTapFullAccess.add(fullAccess);
    final answer = oneTap;
    if (answer is RigPairingFailure) throw answer;
    return RigPairing(token: answer as String, scope: 'admin');
  }

  @override
  Future<RigPairing> pairWithCode(
    DiscoveredServer host, {
    required String code,
    required String deviceName,
    required bool fullAccess,
  }) async {
    codes.add(code);
    return const RigPairing(token: 'code-token', scope: 'admin');
  }
}

class _Tunnel implements RigRelayTunnel {
  _Tunnel(this.localPort);
  @override
  final int localPort;
  final _done = Completer<void>();
  bool closed = false;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

class _Device implements RigConnectionDevice {
  @override
  final _Pairing pairing = _Pairing();
  PairingPromptAnswer prompt = const PairingPromptClosed();
  final remembered = <String>[];
  final relays = <String>[];
  final tunnels = <_Tunnel>[];
  int pushResets = 0;

  @override
  String get pairingDeviceName => 'Android companion';

  @override
  Future<RigCollaborationIdentity> collaborationIdentity(String? token) async =>
      const RigCollaborationIdentity(
        viewerId: 'v',
        deviceName: 'd',
        displayName: 'n',
      );

  @override
  Future<PairingPromptAnswer> askPairingCode(DiscoveredServer server) async =>
      prompt;

  @override
  Future<void> scanQrInstead() async {}

  @override
  bool isValidApplianceId(String id) =>
      RegExp(r'^\w{4}-\w{4}-\w{4}$').hasMatch(id);

  @override
  Future<RigRelayTunnel> openRelayTunnel({
    required Uri relayUrl,
    required String applianceId,
    required bool allowBadTlsCertificate,
  }) async {
    final tunnel = _Tunnel(40000 + tunnels.length);
    tunnels.add(tunnel);
    return tunnel;
  }

  @override
  Future<void> rememberServer(DiscoveredServer server) async =>
      remembered.add('${server.host}:${server.webPort}');

  @override
  Future<void> touchSavedServer(String id) async => remembered.add('touch $id');

  @override
  Future<void> rememberRelay({
    required String displayName,
    required String relayUrl,
    required String applianceId,
    required bool allowInsecureTls,
    required String? authToken,
  }) async => relays.add('$applianceId $authToken');

  @override
  Future<void> registerPush(HostLink link) async {}

  @override
  void resetPush() => pushResets++;
}

class _Link implements HostLink {
  final states = StreamController<BackendConnectionState>.broadcast();
  @override
  BackendConnectionState connectionState = BackendConnectionState.connected;
  @override
  Stream<BackendConnectionState> get connectionStateStream => states.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Session implements RigConnectionSession {
  Object _current = Object();
  bool linked = false;
  _Link? openLink;
  final opened = <String>[];
  int disconnects = 0;

  @override
  Future<Object?> open(
    DiscoveredServer server,
    RigCollaborationIdentity identity,
  ) async {
    opened.add('${server.host}:${server.webPort} ${server.authToken}');
    _current = Object();
    linked = true;
    openLink = _Link();
    return _current;
  }

  @override
  bool isCurrent(Object handle) => identical(handle, _current);

  @override
  bool get isLinked => linked;

  @override
  HostLink? get link => linked ? openLink : null;

  @override
  Future<void> disconnect() async {
    disconnects++;
    linked = false;
    _current = Object();
  }

  @override
  void afterLinked(bool Function() stillCurrent) {}
}

DiscoveredServer _host({
  String host = '192.168.1.20',
  bool authRequired = false,
  bool lanPairing = false,
  String? token,
  String? version,
}) => DiscoveredServer(
  host: host,
  webPort: 8080,
  name: 'NYX',
  authRequired: authRequired,
  pairingSupported: true,
  lanPairing: lanPairing,
  authToken: token,
  version: version,
);

void main() {
  group('relay', relayRaceTests);

  late _Device device;
  late _Session session;
  late List<String> savedLast;
  late Map<String, ServerRead> reads;
  late ServerProbeOutcome probe;

  RigConnectionService build({
    Future<ServerRead> Function(DiscoveredServer)? read,
  }) => RigConnectionService(
    device: device,
    session: session,
    network: RigConnectionNetwork(
      discover: ({onStatus}) async => null,
      read: read ?? (s) async => reads[s.host] ?? ServerRead(s, null),
      probe: (_) async => probe,
      saveLastServer: (s) async => savedLast.add('${s.host}:${s.webPort}'),
    ),
  );

  setUp(() {
    device = _Device();
    session = _Session();
    savedLast = [];
    reads = {};
    probe = ServerProbeOutcome.reachable;
  });

  test(
    'a reachable host links, is saved twice and the screen clears',
    () async {
      final service = build();
      expect(await service.connect(_host()), isTrue);
      expect(service.state.connected?.host, '192.168.1.20');
      expect(service.state.busy, isFalse);
      expect(service.state.problem, isNull);
      expect(savedLast, ['192.168.1.20:8080']);
      expect(device.remembered, ['192.168.1.20:8080']);
    },
  );

  test('a saved row keeps its own record: stamped, not upserted', () async {
    final service = build();
    expect(await service.connect(_host(), savedServerId: 'row1'), isTrue);
    expect(device.remembered, ['touch row1']);
  });

  test('a host of another release is a mismatch carrying the host', () async {
    reads['192.168.1.20'] = ServerRead(
      _host(version: '1.0.0'),
      const LinkProblem.mismatch(
        '192.168.1.20:8080',
        LinkVersionMismatch(host: '1.0.0', client: '9.0.0'),
      ),
    );
    final service = build();
    expect(await service.connect(_host()), isFalse);
    final problem = service.state.problem;
    expect(problem, isA<ConnectHostProblem>());
    expect(service.state.mismatchedHost?.version, '1.0.0');
    expect(session.opened, isEmpty);
  });

  test(
    'a host that wants a code: a closed dialog offers the host again',
    () async {
      final service = build();
      expect(await service.connect(_host(authRequired: true)), isFalse);
      expect(service.state.unpairedHost?.host, '192.168.1.20');
      expect(service.state.problem, isNull);
    },
  );

  test('a typed code pairs and the session opens with its token', () async {
    device.prompt = const PairingPromptCode('STAR-LYRA-1234', fullAccess: true);
    final service = build();
    expect(await service.connect(_host(authRequired: true)), isTrue);
    expect(device.pairing.codes, ['STAR-LYRA-1234']);
    expect(session.opened, ['192.168.1.20:8080 code-token']);
  });

  test('one tap on the home network needs no code', () async {
    device.pairing.oneTap = 'lan-token';
    final service = build();
    expect(
      await service.connect(_host(authRequired: true, lanPairing: true)),
      isTrue,
    );
    expect(session.opened, ['192.168.1.20:8080 lan-token']);
    // A headless rig has no other screen to choose its folders and solver
    // on, so one tap asks for full access.
    expect(device.pairing.oneTapFullAccess, [true]);
  });

  test(
    'a host that forgot the phone says pair again and offers the host',
    () async {
      probe = ServerProbeOutcome.authRejected;
      final service = build();
      expect(await service.connect(_host(token: 'old')), isFalse);
      expect(service.state.problem, isA<ConnectForgotten>());
      expect(service.state.unpairedHost?.authToken, isNull);
    },
  );

  test('a host that does not take the session names the address', () async {
    probe = ServerProbeOutcome.unreachable;
    final service = build();
    expect(await service.connect(_host()), isFalse);
    final problem = service.state.problem as ConnectNoSession;
    expect(problem.host, '192.168.1.20');
    expect(problem.tokenMissing, isFalse);
  });

  test('a connect a newer one replaced writes nothing', () async {
    final first = Completer<ServerRead>();
    final service = build(
      read: (s) =>
          s.host == 'old' ? first.future : Future.value(ServerRead(s, null)),
    );
    final older = service.connect(_host(host: 'old'));
    expect(await service.connect(_host(host: 'new')), isTrue);
    first.complete(ServerRead(_host(host: 'old'), null));
    expect(await older, isFalse);
    expect(service.state.connected?.host, 'new');
    expect(savedLast, ['new:8080']);
  });

  test(
    'a link down past the grace is lost and the same server is re-dialled',
    () {
      fakeAsync((async) {
        final service = build();
        service.connect(_host(token: 't'));
        async.flushMicrotasks();
        final link = session.openLink!;
        link.connectionState = BackendConnectionState.reconnecting;
        link.states.add(BackendConnectionState.reconnecting);
        async.flushMicrotasks();
        expect(service.state.stale, isTrue);

        async.elapse(hostLinkRetryWindow);
        // The resting backend the disconnect lands on clears the server.
        service.backendChanged(offersLink: true);
        async.flushMicrotasks();
        expect(service.state.problem, isA<ConnectSessionLost>());
        expect(service.state.connected, isNull);
        expect(service.state.stale, isFalse);
        expect(device.pushResets, 1);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(session.opened, ['192.168.1.20:8080 t', '192.168.1.20:8080 t']);
        expect(service.state.connected?.host, '192.168.1.20');
      });
    },
  );

  test(
    'a link back inside its retry window keeps the session and its screen',
    () {
      fakeAsync((async) {
        final service = build();
        service.connect(_host(token: 't'));
        async.flushMicrotasks();
        final link = session.openLink!;
        link.connectionState = BackendConnectionState.reconnecting;
        link.states.add(BackendConnectionState.reconnecting);
        async.flushMicrotasks();
        expect(service.state.stale, isTrue);

        // The phone check's outage: 36 s of airplane mode, after which the
        // link's next attempt (61 s into its ramp) gets through.
        async.elapse(const Duration(seconds: 61));
        expect(service.state.problem, isNull);
        expect(service.state.connected?.host, '192.168.1.20');
        expect(service.state.stale, isTrue, reason: 'the banner stays up');
        expect(session.disconnects, 0);

        link.connectionState = BackendConnectionState.connected;
        link.states.add(BackendConnectionState.connected);
        async.flushMicrotasks();
        expect(service.state.stale, isFalse);
        async.elapse(hostLinkRetryWindow);
        expect(session.disconnects, 0);
        expect(service.state.problem, isNull);
      });
    },
  );

  test(
    'Look around leaves the host and the flow stays out of the way',
    () async {
      final service = build();
      await service.connect(_host());
      await service.skip();
      expect(service.state.skipped, isTrue);
      expect(session.disconnects, 1);
      service.backendChanged(offersLink: true);
      expect(service.state.connected?.host, '192.168.1.20');
      service.showConnectionScreen();
      expect(service.state.skipped, isFalse);
    },
  );
}

class _HeldConnect extends RigConnectionService {
  _HeldConnect({required super.device, required super.session});

  final held = <Completer<bool>>[];

  @override
  Future<bool> connect(DiscoveredServer server, {String? savedServerId}) {
    final answer = Completer<bool>();
    held.add(answer);
    return answer.future;
  }
}

void relayRaceTests() {
  test(
    'a relay connect a newer one replaced closes only its own tunnel',
    () async {
      final device = _Device();
      final session = _Session();
      final service = _HeldConnect(device: device, session: session);

      final older = service.connectViaRelay(
        relayUrl: 'wss://relay.example',
        applianceId: 'aaaa-bbbb-cccc',
      );
      await pumpEventQueue();
      final newer = service.connectViaRelay(
        relayUrl: 'wss://relay.example',
        applianceId: 'dddd-eeee-ffff',
      );
      await pumpEventQueue();
      expect(device.tunnels, hasLength(2));

      // The older connect was superseded while the newer one is still dialling.
      service.held[0].complete(false);
      await older;
      expect(device.tunnels[1].closed, isFalse);
      expect(service.activeRelayTunnel, same(device.tunnels[1]));

      session.linked = true;
      service.held[1].complete(true);
      await newer;
      expect(device.tunnels[1].closed, isFalse);
      expect(device.relays, ['dddd-eeee-ffff null']);
    },
  );
}
