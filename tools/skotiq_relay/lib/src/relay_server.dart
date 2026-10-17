// The self-hostable Skotiq relay server.
//
// Topology (v1, honest and simple):
//
//   appliance ──outbound WS──► relay ◄──WS── phone(s)
//        /uplink                       /connect/<applianceId>
//
// * Appliances dial OUT (so the rig needs no port forwarding) and register
//   with a relay key: a random appliance id + secret minted at first
//   registration. The relay stores only the SHA-256 of the secret.
// * Phones connect to `/connect/<applianceId>`; the relay splices the two
//   WebSockets, forwarding mux frames (see mux/frame.dart) with stream-id
//   rewriting so several phones can share one appliance uplink.
// * The relay NEVER sees plaintext Skotiq credentials: pairing codes
//   and HMAC bearer tokens ride inside the tunnelled HTTP byte streams,
//   end-to-end between phone and appliance (use a TLS appliance or trust
//   your relay host — the relay can observe tunnel bytes like any reverse
//   proxy unless the appliance itself speaks HTTPS).
// * Control frames (stream 0) are hop-local and never forwarded.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'mux/frame.dart';
import 'relay_credentials.dart';

/// Tunable knobs for [RelayServer]. Every limit exists to keep one bad or
/// hostile peer from exhausting the host.
class RelayServerConfig {
  /// TCP port to listen on. 0 = ephemeral (tests).
  final int port;

  /// Bind address. Defaults to any-IPv4.
  final InternetAddress? bindAddress;

  /// PEM cert chain + private key. Both set => serve WSS directly.
  /// Typically left null behind a TLS-terminating reverse proxy.
  final String? tlsCertificatePath;
  final String? tlsPrivateKeyPath;

  /// Cap on distinct registered appliance identities. New registrations
  /// beyond this are refused (existing ones still reconnect).
  final int maxAppliances;

  /// Cap on simultaneously connected phones per appliance.
  final int maxClientsPerAppliance;

  /// Where registered appliance ids + secret hashes persist across relay
  /// restarts. Null = memory only (every restart forgets registrations).
  final String? stateFilePath;

  /// Registration auth failures allowed per source IP per window before
  /// further attempts from that IP are rejected outright.
  final int registrationFailureLimit;
  final Duration registrationFailureWindow;

  const RelayServerConfig({
    this.port = 9777,
    this.bindAddress,
    this.tlsCertificatePath,
    this.tlsPrivateKeyPath,
    this.maxAppliances = 50,
    this.maxClientsPerAppliance = 8,
    this.stateFilePath,
    this.registrationFailureLimit = 5,
    this.registrationFailureWindow = const Duration(minutes: 1),
  });
}

/// Persisted registry: appliance id -> SHA-256(secret) hex.
class RelayApplianceRegistry {
  final Map<String, String> _secretHashes = {};
  final String? _path;

  RelayApplianceRegistry({String? path}) : _path = path;

  int get count => _secretHashes.length;

  bool contains(String applianceId) => _secretHashes.containsKey(applianceId);

  static String hashSecret(String secret) =>
      sha256.convert(utf8.encode(secret)).toString();

  /// Constant-time comparison so secret verification cannot be timed.
  bool verify(String applianceId, String secret) {
    final expected = _secretHashes[applianceId];
    if (expected == null) return false;
    final actual = hashSecret(secret);
    if (expected.length != actual.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> register(String applianceId, String secret) async {
    _secretHashes[applianceId] = hashSecret(secret);
    await _persist();
  }

  Future<void> load() async {
    final path = _path;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('relay state file is not a JSON object: $path');
    }
    final appliances = decoded['appliances'];
    if (appliances is! Map<String, dynamic>) return;
    for (final entry in appliances.entries) {
      final hash = (entry.value is Map<String, dynamic>)
          ? (entry.value as Map<String, dynamic>)['secretHash']
          : null;
      if (hash is String && hash.isNotEmpty) {
        _secretHashes[entry.key] = hash;
      }
    }
  }

  Future<void> _persist() async {
    final path = _path;
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    final payload = jsonEncode({
      'appliances': {
        for (final entry in _secretHashes.entries)
          entry.key: {'secretHash': entry.value},
      },
    });
    final tmp = File('$path.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(path);
  }
}

class RelayServer {
  final RelayServerConfig config;
  final void Function(String message)? onLog;
  final Random _random;

  HttpServer? _httpServer;
  late final RelayApplianceRegistry registry = RelayApplianceRegistry(
    path: config.stateFilePath,
  );

  final Map<String, _ApplianceSession> _online = {};
  final Map<String, List<DateTime>> _authFailuresByIp = {};

  RelayServer(this.config, {this.onLog, Random? random})
    : _random = random ?? Random.secure();

  /// Actual bound port (resolves port 0).
  int get port => _httpServer?.port ?? config.port;

  int get onlineApplianceCount => _online.length;

  int get connectedClientCount =>
      _online.values.fold(0, (sum, a) => sum + a.clients.length);

  Future<void> start() async {
    await registry.load();
    final address = config.bindAddress ?? InternetAddress.anyIPv4;
    if (config.tlsCertificatePath != null && config.tlsPrivateKeyPath != null) {
      final context = SecurityContext()
        ..useCertificateChain(config.tlsCertificatePath!)
        ..usePrivateKey(config.tlsPrivateKeyPath!);
      _httpServer = await HttpServer.bindSecure(address, config.port, context);
    } else {
      _httpServer = await HttpServer.bind(address, config.port);
    }
    _httpServer!.listen(
      _handleRequest,
      onError: (Object e) {
        _log('http server error: $e');
      },
    );
    _log(
      'relay listening on ${address.address}:$port '
      '(${registry.count} registered appliance(s))',
    );
  }

  Future<void> stop() async {
    final appliances = List<_ApplianceSession>.of(_online.values);
    for (final a in appliances) {
      await a.close('relay shutting down');
    }
    _online.clear();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  void _log(String message) => onLog?.call(message);

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (path == '/healthz') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'ok',
              'appliancesRegistered': registry.count,
              'appliancesOnline': onlineApplianceCount,
              'clientsConnected': connectedClientCount,
            }),
          );
        await request.response.close();
        return;
      }
      if (path == '/uplink') {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _respond(
            request,
            HttpStatus.badRequest,
            'expected WebSocket upgrade',
          );
          return;
        }
        final remoteIp = _remoteIp(request);
        final ws = await WebSocketTransformer.upgrade(request);
        unawaited(_handleUplink(ws, remoteIp));
        return;
      }
      if (path.startsWith('/connect/')) {
        final applianceId = path.substring('/connect/'.length);
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          await _respond(
            request,
            HttpStatus.badRequest,
            'expected WebSocket upgrade',
          );
          return;
        }
        final ws = await WebSocketTransformer.upgrade(request);
        unawaited(_handleClient(ws, applianceId));
        return;
      }
      await _respond(request, HttpStatus.notFound, 'skotiq relay');
    } catch (e) {
      _log('request handling failed: $e');
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _respond(HttpRequest request, int status, String body) async {
    request.response
      ..statusCode = status
      ..write(body);
    await request.response.close();
  }

  String _remoteIp(HttpRequest request) =>
      request.connectionInfo?.remoteAddress.address ?? 'unknown';

  // -- appliance uplink ---------------------------------------------------

  Future<void> _handleUplink(WebSocket ws, String remoteIp) async {
    ws.pingInterval = const Duration(seconds: 30);

    if (_isRateLimited(remoteIp)) {
      _sendControl(ws, {
        'op': 'error',
        'code': 'rate_limited',
        'message': 'too many failed registration attempts; retry later',
      });
      await ws.close(WebSocketStatus.policyViolation, 'rate limited');
      return;
    }

    // The very first frame MUST be a register control message.
    final Map<String, dynamic> register;
    final queue = StreamIterator<dynamic>(ws);
    try {
      final gotFirst = await queue.moveNext().timeout(
        const Duration(seconds: 10),
        onTimeout: () => false,
      );
      if (!gotFirst) {
        await ws.close(WebSocketStatus.policyViolation, 'no registration');
        return;
      }
      final frame = _decodeWsFrame(queue.current);
      if (frame.type != MuxFrameType.control ||
          frame.streamId != kMuxControlStreamId) {
        throw const MuxProtocolException('first frame is not control');
      }
      final decoded = jsonDecode(utf8.decode(frame.payload));
      if (decoded is! Map<String, dynamic> || decoded['op'] != 'register') {
        throw const MuxProtocolException('first control message not register');
      }
      register = decoded;
    } on Exception catch (e) {
      _log('uplink from $remoteIp rejected: $e');
      await ws.close(WebSocketStatus.protocolError, 'bad registration');
      return;
    }

    final suppliedId = register['applianceId'];
    final suppliedSecret = register['secret'];
    String applianceId;
    String? mintedSecret;

    if (suppliedId is String && suppliedId.isNotEmpty) {
      // Returning appliance: id + secret must verify.
      if (suppliedSecret is! String ||
          !registry.verify(suppliedId, suppliedSecret)) {
        _recordAuthFailure(remoteIp);
        _log('uplink auth failure for "$suppliedId" from $remoteIp');
        _sendControl(ws, {
          'op': 'error',
          'code': 'auth_failed',
          'message': 'unknown appliance id or wrong secret',
        });
        await ws.close(WebSocketStatus.policyViolation, 'auth failed');
        return;
      }
      applianceId = suppliedId;
    } else {
      // First registration: mint id + secret, return the secret exactly once.
      if (registry.count >= config.maxAppliances) {
        _sendControl(ws, {
          'op': 'error',
          'code': 'capacity',
          'message': 'relay is at its registered-appliance limit',
        });
        await ws.close(WebSocketStatus.policyViolation, 'capacity');
        return;
      }
      do {
        applianceId = mintApplianceId(_random);
      } while (registry.contains(applianceId));
      mintedSecret = mintSecret(_random);
      await registry.register(applianceId, mintedSecret);
      _log('minted new appliance id $applianceId for $remoteIp');
    }

    // Replace a stale session for the same id (rig rebooted; the dead WS
    // may linger until ping timeout — newest registration wins).
    final stale = _online.remove(applianceId);
    if (stale != null) {
      _log('replacing stale uplink for $applianceId');
      await stale.close('replaced by a newer uplink');
    }

    final session = _ApplianceSession(applianceId, ws, this);
    _online[applianceId] = session;
    _sendControl(ws, {
      'op': 'registered',
      'applianceId': applianceId,
      if (mintedSecret != null) 'secret': mintedSecret,
    });
    _log('appliance $applianceId online (from $remoteIp)');

    try {
      while (await queue.moveNext()) {
        final frame = _decodeWsFrame(queue.current);
        session.handleApplianceFrame(frame);
      }
    } on Exception catch (e) {
      _log('uplink $applianceId failed: $e');
    } finally {
      if (identical(_online[applianceId], session)) {
        _online.remove(applianceId);
      }
      await session.close('appliance uplink closed');
      _log('appliance $applianceId offline');
    }
  }

  // -- phone/client tunnel --------------------------------------------------

  Future<void> _handleClient(WebSocket ws, String applianceId) async {
    ws.pingInterval = const Duration(seconds: 30);

    Future<void> refuse(String code, String message) async {
      _sendControl(ws, {'op': 'error', 'code': code, 'message': message});
      await ws.close(WebSocketStatus.policyViolation, code);
    }

    if (!isValidApplianceId(applianceId)) {
      await refuse(
        'bad_appliance_id',
        'appliance id must look like xxxx-xxxx-xxxx',
      );
      return;
    }
    final appliance = _online[applianceId];
    if (appliance == null) {
      await refuse(
        'appliance_offline',
        registry.contains(applianceId)
            ? 'appliance "$applianceId" is registered but not connected'
            : 'no appliance "$applianceId" is registered on this relay',
      );
      return;
    }
    if (appliance.clients.length >= config.maxClientsPerAppliance) {
      await refuse(
        'too_many_clients',
        'appliance "$applianceId" already has the maximum number of clients',
      );
      return;
    }

    final client = _ClientSession(ws, appliance);
    appliance.clients.add(client);
    _sendControl(ws, {'op': 'connected', 'applianceId': applianceId});
    _log(
      'client connected to $applianceId '
      '(${appliance.clients.length} client(s))',
    );

    try {
      await for (final message in ws) {
        final frame = _decodeWsFrame(message);
        appliance.handleClientFrame(client, frame);
      }
    } on Exception catch (e) {
      _log('client tunnel for $applianceId failed: $e');
    } finally {
      appliance.dropClient(client);
      _log(
        'client disconnected from $applianceId '
        '(${appliance.clients.length} client(s))',
      );
    }
  }

  // -- shared helpers -------------------------------------------------------

  MuxFrame _decodeWsFrame(dynamic message) {
    if (message is! List<int>) {
      throw const MuxProtocolException('expected binary WebSocket message');
    }
    return MuxFrame.decodeExact(
      message is Uint8List ? message : Uint8List.fromList(message),
    );
  }

  void _sendControl(WebSocket ws, Map<String, dynamic> message) {
    try {
      ws.add(
        MuxFrame(
          kMuxControlStreamId,
          MuxFrameType.control,
          Uint8List.fromList(utf8.encode(jsonEncode(message))),
        ).encode(),
      );
    } catch (_) {
      // Socket already gone — caller's close path handles it.
    }
  }

  bool _isRateLimited(String ip) {
    final cutoff = DateTime.now().subtract(config.registrationFailureWindow);
    final failures = _authFailuresByIp[ip];
    if (failures == null) return false;
    failures.removeWhere((t) => t.isBefore(cutoff));
    if (failures.isEmpty) {
      _authFailuresByIp.remove(ip);
      return false;
    }
    return failures.length >= config.registrationFailureLimit;
  }

  void _recordAuthFailure(String ip) {
    (_authFailuresByIp[ip] ??= []).add(DateTime.now());
  }
}

/// Server-side state for one appliance uplink plus the clients tunnelled
/// through it. Owns the stream-id rewrite tables.
class _ApplianceSession {
  final String applianceId;
  final WebSocket ws;
  final RelayServer server;

  final Set<_ClientSession> clients = {};

  /// Relay-allocated (appliance-facing) stream id -> originating client
  /// binding. Stream ids the APPLIANCE sees are allocated here so several
  /// clients (each with their own 1,2,3... id space) can share the uplink.
  final Map<int, _StreamBinding> _byUplinkId = {};
  int _nextUplinkStreamId = 1;

  _ApplianceSession(this.applianceId, this.ws, this.server);

  void handleClientFrame(_ClientSession client, MuxFrame frame) {
    if (frame.type == MuxFrameType.control ||
        frame.streamId == kMuxControlStreamId) {
      return; // hop-local; never forwarded
    }
    switch (frame.type) {
      case MuxFrameType.open:
        final uplinkId = _nextUplinkStreamId++;
        final binding = _StreamBinding(client, frame.streamId, uplinkId);
        _byUplinkId[uplinkId] = binding;
        client.byClientId[frame.streamId] = binding;
        _toAppliance(MuxFrame(uplinkId, MuxFrameType.open, frame.payload));
      case MuxFrameType.data:
      case MuxFrameType.finish:
      case MuxFrameType.reset:
        final binding = client.byClientId[frame.streamId];
        if (binding == null) return; // raced with teardown — drop
        _toAppliance(
          MuxFrame(binding.uplinkStreamId, frame.type, frame.payload),
        );
        if (frame.type == MuxFrameType.reset) {
          _unbind(binding);
        } else if (frame.type == MuxFrameType.finish) {
          binding.clientFinished = true;
          if (binding.applianceFinished) _unbind(binding);
        }
      case MuxFrameType.control:
        break; // unreachable
    }
  }

  void handleApplianceFrame(MuxFrame frame) {
    if (frame.type == MuxFrameType.control ||
        frame.streamId == kMuxControlStreamId) {
      return; // hop-local
    }
    if (frame.type == MuxFrameType.open) {
      // v1: appliances never originate streams. Refuse politely so a
      // future appliance speaking a newer protocol degrades cleanly.
      _toAppliance(
        MuxFrame(
          frame.streamId,
          MuxFrameType.reset,
          Uint8List.fromList(
            utf8.encode(
              'relay does not accept '
              'appliance-initiated streams',
            ),
          ),
        ),
      );
      return;
    }
    final binding = _byUplinkId[frame.streamId];
    if (binding == null) return; // client already went away
    binding.client.send(
      MuxFrame(binding.clientStreamId, frame.type, frame.payload),
    );
    if (frame.type == MuxFrameType.reset) {
      _unbind(binding);
    } else if (frame.type == MuxFrameType.finish) {
      binding.applianceFinished = true;
      if (binding.clientFinished) _unbind(binding);
    }
  }

  /// A client WS dropped: abort all its streams toward the appliance.
  void dropClient(_ClientSession client) {
    if (!clients.remove(client)) return;
    final bindings = List<_StreamBinding>.of(client.byClientId.values);
    for (final binding in bindings) {
      _toAppliance(
        MuxFrame(
          binding.uplinkStreamId,
          MuxFrameType.reset,
          Uint8List.fromList(utf8.encode('client disconnected')),
        ),
      );
      _unbind(binding);
    }
  }

  /// Uplink is going away: notify and drop every client.
  Future<void> close(String reason) async {
    final orphans = List<_ClientSession>.of(clients);
    clients.clear();
    _byUplinkId.clear();
    for (final client in orphans) {
      client.byClientId.clear();
      server._sendControl(client.ws, {
        'op': 'error',
        'code': 'appliance_offline',
        'message': reason,
      });
      try {
        await client.ws.close(WebSocketStatus.goingAway, 'appliance offline');
      } catch (_) {}
    }
    try {
      await ws.close(WebSocketStatus.goingAway, reason);
    } catch (_) {}
  }

  void _unbind(_StreamBinding binding) {
    _byUplinkId.remove(binding.uplinkStreamId);
    binding.client.byClientId.remove(binding.clientStreamId);
  }

  void _toAppliance(MuxFrame frame) {
    try {
      ws.add(frame.encode());
    } catch (_) {
      // Uplink dying; the read loop's finally block cleans up.
    }
  }
}

class _ClientSession {
  final WebSocket ws;
  final _ApplianceSession appliance;

  /// Client-facing stream id -> binding (shared with the appliance table).
  final Map<int, _StreamBinding> byClientId = {};

  _ClientSession(this.ws, this.appliance);

  void send(MuxFrame frame) {
    try {
      ws.add(frame.encode());
    } catch (_) {
      // Client socket dying; dropClient in the read loop cleans up.
    }
  }
}

class _StreamBinding {
  final _ClientSession client;
  final int clientStreamId;
  final int uplinkStreamId;
  bool clientFinished = false;
  bool applianceFinished = false;

  _StreamBinding(this.client, this.clientStreamId, this.uplinkStreamId);
}
