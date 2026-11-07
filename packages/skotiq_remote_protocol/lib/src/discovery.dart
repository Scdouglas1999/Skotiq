import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:convert';

import 'network_uri.dart';

/// Discovered Skotiq server information
class DiscoveredServer {
  final String host;
  final int webPort;

  /// Signalling port carried by the legacy UDP/QR wire shapes. Nothing dials
  /// it; it exists so those payloads still round-trip. Synthetic
  /// [DiscoveredServer]s should leave it at its default.
  final int signalingPort;
  final String name;

  /// Human-facing server version string. Defaults to `unknown` for synthetic
  /// records built before `/api/info` enrichment fills the real value —
  /// callers should not hard-code a placeholder version.
  final String version;
  final String? apiVersion;
  final String mode;
  final bool authRequired;
  final String authenticationMode;
  final bool pairingSupported;
  final String? authToken;
  final String? fingerprint;

  /// `true` when the appliance advertises one-tap LAN pairing (`lanPairing`
  /// in `/api/info`): it is in `lan-open` mode and will mint a scoped token
  /// for a request that arrives from a trusted private-LAN source, with no
  /// pairing code. Discovery seeds this `false` (UDP/mDNS can't tell); the
  /// `/api/info` enrichment fills the canonical value. The connect flow uses
  /// it to try `POST /api/pairing/lan-claim` before falling back to the code
  /// dialog.
  final bool lanPairing;

  /// Transport scheme. Either `http` (plain) or `https` (TLS). Defaults to
  /// `http` because UDP-broadcast discovery cannot tell the difference — the
  /// mDNS browse path populates this from the server's `scheme` TXT record so
  /// QR-less Tailscale / WiFi connections still land on the right protocol
  /// when the operator has TLS enabled.
  final String scheme;

  /// The rig's Tailscale (MagicDNS / `100.x`) address as advertised by
  /// `/api/info` (`tailscaleHost`) when the appliance is on a tailnet. `null`
  /// for rigs that aren't dual-homed onto a tailnet. The connect flow records
  /// this so a returning operator can reach the rig over Tailscale from
  /// off-site without hand-typing the MagicDNS name off the desktop — the
  /// Tailscale setup sheet prefills it.
  final String? tailscaleHost;

  /// The appliance id the rig's relay uplink minted (`relayApplianceId` in
  /// `/api/info`) when a relay tunnel is up. `null` when the rig has no relay
  /// uplink. Surfaced so the relay-connect dialog prefills the id instead of
  /// forcing the operator to read it off the headless daemon's log.
  final String? relayApplianceId;

  /// The host's computer name (for example `DESKTOP-MMAJGAK` or `observatory`).
  /// Filled from `/api/info` (`hostName`) on hosts that report it, or from the
  /// mDNS SRV target (`DESKTOP-MMAJGAK.local`) on older ones. Null when neither
  /// source has answered.
  final String? hostName;

  /// The host's operating system as `/api/info` reports it (`linux`,
  /// `windows`, `macos`). Null until enrichment.
  final String? platform;

  /// `gui` when the desktop app with its window serves the API, `headless`
  /// for the daemon. Read from `/api/info` `hostMode` (hosts newer than 8.2.1);
  /// older hosts said `mode: headless` for both.
  final String? hostMode;

  DiscoveredServer({
    required this.host,
    required this.webPort,
    this.signalingPort = 45678,
    required this.name,
    this.version = 'unknown',
    this.apiVersion,
    this.mode = 'desktop',
    this.authRequired = false,
    this.authenticationMode = 'none',
    this.pairingSupported = false,
    this.authToken,
    this.fingerprint,
    this.lanPairing = false,
    this.scheme = 'http',
    this.tailscaleHost,
    this.relayApplianceId,
    this.hostName,
    this.platform,
    this.hostMode,
  });

  /// The name a person recognizes: the computer name when it is known, else
  /// the advertised name when it says more than the product name, else the
  /// address.
  String get displayName {
    final computer = hostName?.trim();
    if (computer != null && computer.isNotEmpty) return computer;
    final advertised = name.trim();
    if (advertised.isNotEmpty &&
        advertised != 'Skotiq' &&
        advertised != 'Skotiq Headless') {
      return advertised;
    }
    return host;
  }

  /// `true` when the server advertised TLS via mDNS. UDP-broadcast discovery
  /// always reports false — the cascade falls back to enriching via
  /// `GET /api/info` which carries the canonical answer.
  bool get isTls => scheme == 'https';

  String get webUrl => buildSkotiqServerUri(
    scheme: scheme,
    host: host,
    port: webPort,
    pathAndQuery: '',
  ).toString();
  String get signalingUrl => buildSkotiqServerUri(
    scheme: scheme,
    host: host,
    port: signalingPort,
    pathAndQuery: '',
  ).toString();

  DiscoveredServer copyWith({
    String? host,
    int? webPort,
    int? signalingPort,
    String? name,
    String? version,
    String? apiVersion,
    String? mode,
    bool? authRequired,
    String? authenticationMode,
    bool? pairingSupported,
    String? authToken,
    String? fingerprint,
    bool? lanPairing,
    String? scheme,
    String? tailscaleHost,
    String? relayApplianceId,
    String? hostName,
    String? platform,
    String? hostMode,
  }) {
    return DiscoveredServer(
      host: host ?? this.host,
      webPort: webPort ?? this.webPort,
      signalingPort: signalingPort ?? this.signalingPort,
      name: name ?? this.name,
      version: version ?? this.version,
      apiVersion: apiVersion ?? this.apiVersion,
      mode: mode ?? this.mode,
      authRequired: authRequired ?? this.authRequired,
      authenticationMode: authenticationMode ?? this.authenticationMode,
      pairingSupported: pairingSupported ?? this.pairingSupported,
      authToken: authToken ?? this.authToken,
      fingerprint: fingerprint ?? this.fingerprint,
      lanPairing: lanPairing ?? this.lanPairing,
      scheme: scheme ?? this.scheme,
      tailscaleHost: tailscaleHost ?? this.tailscaleHost,
      relayApplianceId: relayApplianceId ?? this.relayApplianceId,
      hostName: hostName ?? this.hostName,
      platform: platform ?? this.platform,
      hostMode: hostMode ?? this.hostMode,
    );
  }

  @override
  String toString() => '$name (${Uri(host: host, port: webPort).authority})';
}

/// Handle returned from [SkotiqDiscovery.startBroadcasting] so callers
/// can terminate the announcement loop without leaking the periodic timer.
///
/// Every announcement timer is reachable through a handle; an uncancellable
/// `Timer.periodic` leaks one timer per broadcast call.
class DiscoveryBroadcaster {
  final DiscoveryPortLease _lease;
  final Timer _timer;
  bool _stopped = false;

  DiscoveryBroadcaster._(this._lease, this._timer);

  /// The shared socket on the discovery port. Owned by [DiscoveryPortMux];
  /// closing it here would silence every other responder in the process.
  RawDatagramSocket get socket => _lease.socket;

  /// Cancel the periodic broadcast and release the port. Idempotent.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    _timer.cancel();
    _lease.release();
  }
}

/// Answers a datagram that arrived on the discovery port. Returns true when it
/// handled the message, so the next handler is not asked.
typedef DiscoveryDatagramHandler =
    bool Function(String message, Datagram datagram, RawDatagramSocket socket);

/// One process-wide socket on UDP 45679 shared by every responder.
///
/// The desktop host used to bind the port twice: once for the discovery
/// beacon ([SkotiqDiscovery.startBroadcasting]) and once for the LAN update
/// responder ([UpdatePushDiscovery.startResponding]), both with
/// `reuseAddress`. On Windows a unicast datagram to a doubly bound UDP port is
/// delivered to only one of the sockets, and it was the update responder's,
/// which ignores discovery probes. A Windows imaging computer therefore never
/// answered `SKOTIQ_DISCOVERY_V2:` at all (reproduced against a live 8.2.1 GUI
/// host: the update probe was answered on the same port, the discovery probe
/// was not). One socket that hands each message to the responder whose prefix
/// it carries cannot lose a datagram that way.
class DiscoveryPortMux {
  DiscoveryPortMux._();

  static RawDatagramSocket? _socket;
  static Future<RawDatagramSocket>? _opening;
  static final List<DiscoveryPortLease> _leases = [];

  /// Bind (or join) the shared socket on [port] and register [handler].
  static Future<DiscoveryPortLease> acquire({
    required DiscoveryDatagramHandler handler,
    int port = SkotiqDiscovery.discoveryPort,
  }) async {
    final socket = _socket ?? await (_opening ??= _open(port));
    final lease = DiscoveryPortLease._(socket, handler);
    _leases.add(lease);
    return lease;
  }

  static Future<RawDatagramSocket> _open(int port) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        // Still shared with OTHER processes (a second Skotiq on the machine,
        // the update pusher tool); within this process there is one socket.
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          final String message;
          try {
            message = utf8.decode(datagram.data);
          } catch (_) {
            return; // Not text: noise on a shared LAN.
          }
          for (final lease in List.of(_leases)) {
            try {
              if (lease._handler(message, datagram, socket)) return;
            } catch (e, stackTrace) {
              developer.log(
                'Discovery responder failed: $e\n$stackTrace',
                name: 'SkotiqDiscovery',
                level: 900,
              );
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          developer.log(
            'Discovery port socket error: $error\n$stackTrace',
            name: 'SkotiqDiscovery',
            level: 1000,
          );
        },
      );
      _socket = socket;
      return socket;
    } finally {
      _opening = null;
    }
  }

  static void _release(DiscoveryPortLease lease) {
    _leases.remove(lease);
    if (_leases.isEmpty) {
      final socket = _socket;
      _socket = null;
      try {
        socket?.close();
      } catch (_) {
        // Best-effort close on shutdown; the OS may already have reclaimed it.
      }
    }
  }

  /// Number of live leases. For tests.
  static int get leaseCount => _leases.length;
}

/// A responder's hold on the shared discovery socket.
class DiscoveryPortLease {
  DiscoveryPortLease._(this.socket, this._handler);

  final RawDatagramSocket socket;
  final DiscoveryDatagramHandler _handler;
  bool _released = false;

  /// Unregister this responder; the socket closes with the last lease.
  void release() {
    if (_released) return;
    _released = true;
    DiscoveryPortMux._release(this);
  }
}

class SkotiqDiscovery {
  /// Server-side fixed port — desktop instances bind here so clients can
  /// target a known address.
  static const int _serverPort = discoveryPort;

  /// The UDP port Skotiq hosts listen on for discovery and update probes.
  static const int discoveryPort = 45679;
  // Marker bytes so we never mistake a stray UDP datagram for a Skotiq
  // packet. JSON alone is not sufficient — anything on the local LAN can
  // emit `{...}`.
  static const String _requestPrefix = 'SKOTIQ_DISCOVERY_V2:';
  static const String _responsePrefix = 'SKOTIQ_RESPONSE_V2:';
  static const String _protocolVersion = '2';

  /// Start broadcasting this server's presence (desktop/server side).
  ///
  /// Returned [DiscoveryBroadcaster] owns the socket + timer. Callers MUST
  /// call [DiscoveryBroadcaster.stop] on shutdown.
  static Future<DiscoveryBroadcaster> startBroadcasting({
    required int webPort,
    required int signalingPort,
    String name = 'Skotiq',
    String version = '2.0.0',
    String scheme = 'http',
    String? fingerprint,
    bool authRequired = false,
    String authenticationMode = 'none',
    bool pairingSupported = false,
    String? hostName,
    String? hostMode,
    Duration interval = const Duration(seconds: 2),
  }) async {
    // Build the announcement once — payload is invariant across the run.
    final payload = {
      'protocol': _protocolVersion,
      'name': name,
      'version': version,
      'webPort': webPort,
      'signalingPort': signalingPort,
      'scheme': scheme,
      'authRequired': authRequired,
      'authenticationMode': authenticationMode,
      'pairingSupported': pairingSupported,
      if (fingerprint != null && fingerprint.isNotEmpty)
        'fingerprint': fingerprint,
      if (hostName != null && hostName.isNotEmpty) 'hostName': hostName,
      if (hostMode != null && hostMode.isNotEmpty) 'hostMode': hostMode,
    };
    final messageBytes = utf8.encode('$_responsePrefix${jsonEncode(payload)}');
    final broadcastTargets = await _udpBroadcastTargets();

    // Respond directly to client probes so a client that joined after our
    // last broadcast tick doesn't have to wait for the next one.
    final lease = await DiscoveryPortMux.acquire(
      handler: (message, datagram, socket) {
        if (!message.startsWith(_requestPrefix)) return false;
        socket.send(messageBytes, datagram.address, datagram.port);
        return true;
      },
    );
    final socket = lease.socket;

    void emit() {
      for (final target in broadcastTargets) {
        try {
          socket.send(messageBytes, target, _serverPort);
        } catch (_) {
          // Why: periodic broadcaster tick — network may not be ready
          // (interface coming up), firewall may be blocking, or address
          // may be temporarily unreachable. Killing the periodic loop on
          // any of these would silently disable discovery for the session;
          // we want to keep retrying every tick until conditions recover.
        }
      }
    }

    // Immediate emit so a client probing in this same tick gets a response,
    // then resume on the periodic schedule.
    //
    // Why supervised: although `emit` already has an internal try/catch for
    // socket.send, any other failure inside the periodic tick (e.g. an
    // unexpected NPE from a future maintainer expanding the body) would
    // be silently swallowed by Timer.periodic. Wrapping the tick body in
    // _superviseSync makes such regressions visible in the dev log
    // (background-service supervision).
    emit();
    final timer = Timer.periodic(
      interval,
      (_) => _superviseSync('broadcastEmit', emit),
    );

    return DiscoveryBroadcaster._(lease, timer);
  }

  /// Run [task] and log any thrown exception at error level.
  ///
  /// Why: Timer.periodic and Stream.listen callbacks complete outside any
  /// await chain — exceptions become unhandled errors that the zone drops.
  /// This is the "background-service supervision" gap.
  /// We log but do not rethrow because the caller is fire-and-forget;
  /// rethrowing would land in the same dropped-error path.
  static void _superviseSync(String name, void Function() task) {
    try {
      task();
    } catch (e, stackTrace) {
      developer.log(
        'Supervised task "$name" failed: $e\n$stackTrace',
        name: 'SkotiqDiscovery',
        level: 1000,
      );
    }
  }

  /// Discover Skotiq servers on the local network (mobile/client side).
  ///
  /// Binds an ephemeral UDP port (port 0) so multiple clients on the same
  /// host don't fight for [_serverPort] — that port is reserved for the
  /// server. Sends a probe to the server port and listens on the ephemeral
  /// port for the responses targeted back at us.
  static Future<List<DiscoveredServer>> discoverServers({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final servers = <DiscoveredServer>[];
    final seen = <String>{};
    RawDatagramSocket? socket;

    try {
      developer.log(
        'Creating UDP socket for discovery (ephemeral port)...',
        name: 'SkotiqDiscovery',
      );
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      developer.log(
        'Client socket bound to ephemeral port ${socket.port}; '
        'targeting server port $_serverPort',
        name: 'SkotiqDiscovery',
      );

      socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket!.receive();
        if (datagram == null) return;
        try {
          final server = tryParseResponsePacket(
            utf8.decode(datagram.data),
            datagram.address.address,
          );
          if (server == null) return;
          final webPort = server.webPort;
          final host = server.host;
          final key = '$host:$webPort';
          if (seen.contains(key)) return;
          seen.add(key);
          servers.add(server);
          developer.log(
            'Found server: ${servers.last.name} at $host',
            name: 'SkotiqDiscovery',
            level: 800,
          );
        } catch (e) {
          developer.log(
            'Error parsing packet: $e',
            name: 'SkotiqDiscovery',
            level: 1000,
          );
        }
      });

      // Structured probe — the server validates the prefix; the JSON body is
      // the forward-compat hook for adding device-id / pairing fields without
      // breaking the protocol.
      final probe = utf8.encode(
        '$_requestPrefix${jsonEncode({'protocol': _protocolVersion})}',
      );
      for (final target in await _udpBroadcastTargets()) {
        try {
          socket.send(probe, target, _serverPort);
        } catch (_) {
          // Best-effort discovery probe: another target may still work.
        }
      }

      await Future.delayed(timeout);
      developer.log(
        'Discovery timeout reached, found ${servers.length} servers',
        name: 'SkotiqDiscovery',
      );
      return servers;
    } catch (e) {
      developer.log(
        'Discovery error: $e',
        name: 'SkotiqDiscovery',
        level: 1000,
      );
      return servers;
    } finally {
      socket?.close();
    }
  }

  /// Get the first discovered server (for auto-connect)
  static Future<DiscoveredServer?> discoverFirst({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final servers = await discoverServers(timeout: timeout);
    return servers.isNotEmpty ? servers.first : null;
  }

  static String _validScheme(Object? raw) {
    if (raw is! String) return 'http';
    final scheme = raw.toLowerCase();
    return scheme == 'https' ? 'https' : 'http';
  }

  /// Parse one UDP response packet. Exposed as a pure helper so the wire
  /// contract can be covered without depending on LAN broadcast behaviour in
  /// unit tests.
  static DiscoveredServer? tryParseResponsePacket(String message, String host) {
    try {
      if (!message.startsWith(_responsePrefix)) return null;
      final jsonStr = message.substring(_responsePrefix.length);
      final info = jsonDecode(jsonStr);
      if (info is! Map<String, dynamic>) return null;
      if (info['webPort'] is! int || info['signalingPort'] is! int) {
        return null;
      }

      return DiscoveredServer(
        host: host,
        webPort: info['webPort'] as int,
        signalingPort: info['signalingPort'] as int,
        name: info['name'] is String ? info['name'] as String : 'Skotiq',
        version: info['version'] is String
            ? info['version'] as String
            : '2.0.0',
        scheme: _validScheme(info['scheme']),
        authRequired: info['authRequired'] as bool? ?? false,
        authenticationMode: info['authenticationMode'] is String
            ? info['authenticationMode'] as String
            : 'none',
        pairingSupported: info['pairingSupported'] as bool? ?? false,
        fingerprint: info['fingerprint'] is String
            ? info['fingerprint'] as String
            : null,
        hostName: info['hostName'] is String
            ? info['hostName'] as String
            : null,
        hostMode: info['hostMode'] is String
            ? info['hostMode'] as String
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// UDP broadcast targets used for discovery probes and server beacons.
  ///
  /// `255.255.255.255` is still the baseline, but some Linux/Wi-Fi stacks
  /// drop limited broadcast packets. Adding likely /24 directed broadcasts
  /// for each active IPv4 interface improves Raspberry Pi appliance discovery
  /// on common home networks without requiring router configuration.
  static Future<List<InternetAddress>> _udpBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces.expand(
        (interface) => interface.addresses.map((address) => address.address),
      );
      targets.addAll(likelyIpv4DirectedBroadcastTargets(addresses));
    } catch (_) {
      // Interface enumeration is optional. Limited broadcast remains enough
      // for the legacy path when the OS denies interface listing.
    }
    return targets.map(InternetAddress.new).toList(growable: false);
  }

  /// Compute likely directed-broadcast addresses from IPv4 interface addresses.
  ///
  /// Dart's [NetworkInterface] does not expose netmasks, so this intentionally
  /// uses the common /24 form (`a.b.c.255`) instead of pretending to know the
  /// exact subnet. The result supplements, not replaces, limited broadcast.
  static Set<String> likelyIpv4DirectedBroadcastTargets(
    Iterable<String> addresses,
  ) {
    final targets = <String>{};
    for (final address in addresses) {
      final parts = address.split('.');
      if (parts.length != 4) continue;
      final octets = <int>[];
      var valid = true;
      for (final part in parts) {
        final value = int.tryParse(part);
        if (value == null || value < 0 || value > 255) {
          valid = false;
          break;
        }
        octets.add(value);
      }
      if (!valid) continue;
      if (octets[0] == 127 || octets[0] == 0) continue;
      if (octets[3] == 0 || octets[3] == 255) continue;
      targets.add('${octets[0]}.${octets[1]}.${octets[2]}.255');
    }
    return targets;
  }
}

/// Discovered Skotiq instance for update pushing
class DiscoveredUpdateTarget {
  final String host;
  final int pushPort;
  final String name;
  final String version;
  final int buildNumber;
  final bool isReceiving;

  DiscoveredUpdateTarget({
    required this.host,
    required this.pushPort,
    required this.name,
    required this.version,
    required this.buildNumber,
    required this.isReceiving,
  });

  @override
  String toString() => '$name v$version ($host:$pushPort)';
}

/// Discovery service for finding Skotiq instances to push updates to
class UpdatePushDiscovery {
  static const int _discoveryPort = 45679;
  static const int _pushPort = 45680;
  static const String _updatePushMessage = 'SKOTIQ_UPDATE_PUSH';
  static const String _updateResponsePrefix = 'SKOTIQ_UPDATE_TARGET:';

  /// Discover Skotiq instances that can receive updates
  static Future<List<DiscoveredUpdateTarget>> discoverTargets({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final targets = <DiscoveredUpdateTarget>[];
    final seen = <String>{};

    try {
      developer.log(
        'Creating UDP socket for discovery...',
        name: 'UpdatePushDiscovery',
      );
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;

      socket.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            try {
              final message = utf8.decode(datagram.data);
              if (message.startsWith(_updateResponsePrefix)) {
                final jsonStr = message.substring(_updateResponsePrefix.length);
                final info = jsonDecode(jsonStr) as Map<String, dynamic>;

                final host = datagram.address.address;
                final key = '$host:${info['pushPort']}';

                if (!seen.contains(key)) {
                  seen.add(key);
                  final target = DiscoveredUpdateTarget(
                    host: host,
                    pushPort: info['pushPort'] as int? ?? _pushPort,
                    name: info['name'] as String? ?? 'Skotiq',
                    version: info['version'] as String? ?? 'unknown',
                    buildNumber: info['buildNumber'] as int? ?? 0,
                    isReceiving: info['isReceiving'] as bool? ?? false,
                  );
                  targets.add(target);
                  developer.log(
                    'Found target: $target',
                    name: 'UpdatePushDiscovery',
                    level: 800,
                  );
                }
              }
            } catch (e) {
              developer.log(
                'Error parsing packet: $e',
                name: 'UpdatePushDiscovery',
                level: 1000,
              );
            }
          }
        }
      });

      // Send update push discovery broadcast
      developer.log(
        'Sending discovery broadcast...',
        name: 'UpdatePushDiscovery',
      );
      final discoveryData = utf8.encode(_updatePushMessage);
      socket.send(
        discoveryData,
        InternetAddress('255.255.255.255'),
        _discoveryPort,
      );

      // Wait for responses
      await Future.delayed(timeout);
      developer.log(
        'Discovery complete, found ${targets.length} targets',
        name: 'UpdatePushDiscovery',
      );
      socket.close();

      return targets;
    } catch (e) {
      developer.log(
        'Discovery error: $e',
        name: 'UpdatePushDiscovery',
        level: 1000,
      );
      return targets;
    }
  }

  /// Start responding to update push discovery messages (desktop side).
  ///
  /// Shares the discovery port's one socket through [DiscoveryPortMux]; see
  /// there for why a second socket on the same port lost discovery probes.
  static Future<DiscoveryPortLease> startResponding({
    required String name,
    required String version,
    required int buildNumber,
    required bool Function() isReceivingCallback,
  }) async {
    final lease = await DiscoveryPortMux.acquire(
      port: _discoveryPort,
      handler: (message, datagram, socket) {
        if (message != _updatePushMessage) return false;
        final info = {
          'name': name,
          'version': version,
          'buildNumber': buildNumber,
          'pushPort': _pushPort,
          'isReceiving': isReceivingCallback(),
        };
        final response = '$_updateResponsePrefix${jsonEncode(info)}';
        socket.send(utf8.encode(response), datagram.address, datagram.port);
        developer.log(
          'Responded to discovery from ${datagram.address.address}',
          name: 'UpdatePushDiscovery',
        );
        return true;
      },
    );

    developer.log(
      'Listening for update push discovery on port $_discoveryPort',
      name: 'UpdatePushDiscovery',
      level: 800,
    );
    return lease;
  }
}
