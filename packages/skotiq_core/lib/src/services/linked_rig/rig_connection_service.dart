import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../backend/roles/host_data/host_link.dart';
import '../../models/backend/backend_connection_state.dart';
import '../../utils/logging_service.dart';
import 'rig_connection_state.dart';
import 'rig_pairing_service.dart';

export 'rig_connection_state.dart';

/// Delay before the Nth automatic re-attach attempt after the connection
/// monitor has declared a session lost (attempt is 0-based).
///
/// Ramps 5 s → 10 s → 20 s → 30 s and then holds at 30 s forever. Retrying
/// without end is the point: without it, losing WiFi for longer than the grace
/// period is terminal — the app drops to the connection screen and stays
/// there, so restoring the network minutes later still leaves "Please
/// reconnect" on screen even though a cold start reconnects instantly from the
/// same saved server. A 30 s idle poll costs far less than a user who wakes to
/// an app that quit watching their run hours ago.
Duration lostSessionRetryDelay(int attempt) {
  const schedule = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];
  if (attempt < 0) return schedule.first;
  return attempt < schedule.length ? schedule[attempt] : schedule.last;
}

/// Whether a successful connect should be written as the startup last server.
///
/// The relay tunnel listens on 127.0.0.1 at an ephemeral port. Saving that
/// endpoint makes the next launch retry a port that is gone. Any other host
/// is still the operator's server, even when a tunnel is open for a different
/// connect.
bool shouldPersistConnectedServer({
  required String host,
  required int port,
  required String? tunnelHost,
  required int? tunnelPort,
}) {
  if (tunnelHost == null || tunnelPort == null) return true;
  return host != tunnelHost || port != tunnelPort;
}

/// What the operator answered in the pairing-code dialog.
sealed class PairingPromptAnswer {
  const PairingPromptAnswer();
}

/// The dialog could not open: the connection screen has no navigator yet.
final class PairingPromptNotReady extends PairingPromptAnswer {
  const PairingPromptNotReady();
}

/// Closed without a code.
final class PairingPromptClosed extends PairingPromptAnswer {
  const PairingPromptClosed();
}

/// The operator chose to scan the host's QR code instead.
final class PairingPromptScan extends PairingPromptAnswer {
  const PairingPromptScan();
}

/// A typed code; [fullAccess] asks the host for admin scope.
final class PairingPromptCode extends PairingPromptAnswer {
  const PairingPromptCode(this.code, {required this.fullAccess});
  final String code;
  final bool fullAccess;
}

/// The loopback tunnel a relay connect rides on.
abstract interface class RigRelayTunnel {
  /// The 127.0.0.1 port the remote rig's API is reachable on.
  int get localPort;

  /// Completes when the tunnel ends.
  Future<void> get done;

  Future<void> close();
}

/// The relay answered and refused the tunnel.
class RigRelayRefused implements Exception {
  const RigRelayRefused(this.code, this.message);
  final String code;
  final String message;
}

/// The identity a linked session joins the host's collaboration slots with.
class RigCollaborationIdentity {
  const RigCollaborationIdentity({
    required this.viewerId,
    required this.deviceName,
    required this.displayName,
  });
  final String viewerId;
  final String deviceName;
  final String displayName;
}

/// What the device running the connect flow provides: its pairing identity,
/// its dialogs, its relay client and its records of servers.
abstract interface class RigConnectionDevice {
  /// Pairs as this device.
  RigPairingService get pairing;

  /// The name this device pairs under.
  String get pairingDeviceName;

  Future<RigCollaborationIdentity> collaborationIdentity(String? authToken);

  /// Asks the operator for the code [server] shows.
  Future<PairingPromptAnswer> askPairingCode(DiscoveredServer server);

  /// Opens the QR scanner, for an operator who chose it in the code dialog.
  Future<void> scanQrInstead();

  bool isValidApplianceId(String id);

  /// Throws [RigRelayRefused] when the relay answered and refused.
  Future<RigRelayTunnel> openRelayTunnel({
    required Uri relayUrl,
    required String applianceId,
    required bool allowBadTlsCertificate,
  });

  /// Adds or refreshes [server] in the saved servers. Never throws.
  Future<void> rememberServer(DiscoveredServer server);

  /// Stamps the saved server [id] as just connected. Never throws.
  Future<void> touchSavedServer(String id);

  /// Adds or refreshes the saved relay row. May throw.
  Future<void> rememberRelay({
    required String displayName,
    required String relayUrl,
    required String applianceId,
    required bool allowInsecureTls,
    required String? authToken,
  });

  /// Registers this device for host pushes on [link]. Never throws.
  Future<void> registerPush(HostLink link);

  /// Forgets the push registration, for a link to a different host.
  void resetPush();
}

/// The app's backend, as the connect flow drives it.
abstract interface class RigConnectionSession {
  /// Opens a session on [server]. Answers a handle for [isCurrent], or null
  /// when a newer backend request took over.
  Future<Object?> open(
    DiscoveredServer server,
    RigCollaborationIdentity identity,
  );

  /// Whether [handle] is still the app's backend.
  bool isCurrent(Object handle);

  /// Whether a link to a host is open.
  bool get isLinked;

  /// The open link, or null.
  HostLink? get link;

  Future<void> disconnect();

  /// Runs after a new session is published (host-backed data reloads).
  void afterLinked(bool Function() stillCurrent);
}

/// The network calls the connect flow makes.
class RigConnectionNetwork {
  const RigConnectionNetwork({
    this.discover = EnhancedSkotiqDiscovery.discoverWithFallback,
    this.read = _readServer,
    this.probe = _probeServer,
    this.saveLastServer = EnhancedSkotiqDiscovery.saveLastServer,
  });

  final Future<DiscoveredServer?> Function({DiscoveryStatusCallback? onStatus})
  discover;
  final Future<ServerRead> Function(DiscoveredServer server) read;
  final Future<ServerProbeOutcome> Function(DiscoveredServer server) probe;
  final Future<void> Function(DiscoveredServer server) saveLastServer;

  static Future<ServerRead> _readServer(DiscoveredServer server) =>
      EnhancedSkotiqDiscovery.readServer(server);

  // Probe over the transport the server actually speaks. A TLS-fronted
  // tailnet/relay rig (scheme=='https') answers only on https.
  static Future<ServerProbeOutcome> _probeServer(DiscoveredServer server) =>
      EnhancedSkotiqDiscovery.probeServer(
        server.host,
        server.webPort,
        authToken: server.authToken,
        scheme: server.scheme,
      );
}

/// The phone's way onto a rig: discovery, pairing when the rig asks for it,
/// the session, the saved-server records, and the watch on the link that
/// re-attaches after a loss. [state] is what the connection screen shows.
class RigConnectionService extends ChangeNotifier {
  RigConnectionService({
    required this.device,
    required this.session,
    this.network = const RigConnectionNetwork(),
    Duration connectionGracePeriod = const Duration(seconds: 30),
    Duration Function(int attempt) retryDelay = lostSessionRetryDelay,
  }) : _connectionGracePeriod = connectionGracePeriod,
       _retryDelay = retryDelay;

  final RigConnectionDevice device;
  final RigConnectionSession session;
  final RigConnectionNetwork network;

  /// How long the link can stay down before the session is declared dead and
  /// the operator is sent back to the connection screen. The backend's own
  /// reconnector backs off up to 30 s.
  final Duration _connectionGracePeriod;
  final Duration Function(int attempt) _retryDelay;

  RigConnectState _state = const RigConnectState();
  RigConnectState get state => _state;

  bool _disposed = false;
  int _operation = 0;

  /// The loopback tunnel a relay session rides on. It outlives the backend
  /// connect (it is the transport) and is torn down whenever the session
  /// ends. Null for direct LAN/Tailscale connections.
  RigRelayTunnel? _activeRelayTunnel;

  StreamSubscription<BackendConnectionState>? _linkStateSubscription;
  Timer? _disconnectGraceTimer;

  /// The app is not in the foreground. Its heartbeat is paused there on
  /// purpose, so a dropped socket is expected and not a lost session.
  bool _appInBackground = false;

  /// Re-arms the connect after the grace period has declared a session dead,
  /// so a phone that blips off the network overnight is reconnected by
  /// morning. Null whenever no retry is pending.
  Timer? _lostSessionRetryTimer;
  int _lostSessionRetryAttempt = 0;

  /// The server whose session was just lost, captured before the connected
  /// server is cleared. Retries re-dial this endpoint (and its saved token)
  /// rather than re-running discovery: discovery can resolve the same host by
  /// a different address (on an emulator, `10.0.2.2` instead of the paired
  /// `192.168.1.20`), and the token is keyed to the paired one.
  DiscoveredServer? _lostSessionServer;

  @visibleForTesting
  RigRelayTunnel? get activeRelayTunnel => _activeRelayTunnel;

  bool _isCurrentOperation(int generation) =>
      !_disposed && generation == _operation;

  void _update(RigConnectState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  /// Shows [problem] on the connection screen.
  void report(ConnectProblem problem) =>
      _update(_state.copyWith(problem: () => problem));

  void openManualEntry() =>
      _update(_state.copyWith(manualEntryOpen: true, problem: () => null));

  void closeManualEntry() => _update(_state.copyWith(manualEntryOpen: false));

  /// The build of the connected app failed; back to a search.
  void resetAfterAppError() => _update(
    _state.copyWith(connected: () => null, problem: () => null, busy: false),
  );

  /// The app's backend changed. Losing the host (or landing on the demo rig,
  /// which is not a link either) returns to the connection screen unless the
  /// operator chose to look around.
  void backendChanged({required bool offersLink}) {
    if (_state.connected != null && offersLink && !_state.skipped) {
      _update(
        _state.copyWith(
          connected: () => null,
          problem: () => null,
          activity: () => null,
        ),
      );
    }
  }

  /// Back to the connection screen from a session with no rig: Settings >
  /// Connection's Connect.
  void showConnectionScreen() {
    if (_disposed || !_state.skipped) return;
    _update(_state.copyWith(skipped: false, problem: () => null));
  }

  // ------------------------------------------------------------- discovery

  Future<void> autoConnect() async {
    _update(
      _state.copyWith(
        busy: true,
        problem: () => null,
        activity: () => const ConnectDiscovering(),
      ),
    );

    try {
      Log.debug('Starting enhanced auto-discovery...', source: 'Discovery');

      final server = await network.discover(
        onStatus: (status) {
          if (!_disposed) {
            _update(
              _state.copyWith(activity: () => ConnectDiscovering(status)),
            );
          }
        },
      );

      if (server != null) {
        Log.info(
          'Found server: ${server.name} at ${server.host}',
          source: 'Discovery',
        );
        await connect(server);
      } else {
        Log.warning('No server found via any method', source: 'Discovery');
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () => const ConnectNothingFound(),
          ),
        );
      }
    } catch (e, stackTrace) {
      Log.error(
        'Discovery error: $e',
        source: 'Discovery',
        error: e,
        stackTrace: stackTrace,
      );
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectDiscoveryFailed(e),
        ),
      );
    }
  }

  /// Links to the computer a scanned QR code names, pairing with the code it
  /// carries when it carries no token.
  Future<void> connectFromQr(QrConnectionData data) async {
    _update(
      _state.copyWith(
        busy: true,
        activity: () => const ConnectViaQr(),
        problem: () => null,
      ),
    );

    var authToken = data.authToken;
    if ((authToken == null || authToken.isEmpty) &&
        data.pairingCode != null &&
        data.pairingCode!.isNotEmpty) {
      try {
        // The QR's fingerprint is checked before the code leaves the phone.
        final paired = await device.pairing.pairWithCode(
          data.toDiscoveredServer(),
          code: data.pairingCode!,
          deviceName: device.pairingDeviceName,
          fullAccess: true,
        );
        authToken = paired.token;
      } on RigPairingFailure catch (failure) {
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () =>
                ConnectPairingFailed(failure, data.toDiscoveredServer()),
          ),
        );
        return;
      }
    }

    final server = data.toDiscoveredServer().copyWith(authToken: authToken);
    // Even when no pairing happened (the QR already carried a token), the
    // live server identity is checked against the QR's fingerprint here, so
    // the failure names the QR code.
    final fetched = (await network.read(server)).server;
    if (_disposed) return;
    if (fetched.fingerprint != null &&
        fetched.fingerprint != data.fingerprint) {
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => const ConnectQrIdentity(),
        ),
      );
      return;
    }

    await connect(server);
  }

  /// Links to a tailnet endpoint the operator entered. Discovery finds
  /// nothing over Tailscale (no broadcast domain), so the rig is reached by
  /// its MagicDNS name or 100.x address.
  Future<void> connectTailscale({
    required String host,
    required int port,
    required String scheme,
    required String? authToken,
  }) async {
    _update(
      _state.copyWith(
        busy: true,
        problem: () => null,
        activity: () => ConnectLinking('$host:$port'),
      ),
    );
    await connect(
      DiscoveredServer(
        name: host,
        host: host,
        webPort: port,
        mode: 'headless',
        scheme: scheme,
        authToken: authToken,
        authRequired: authToken == null,
        pairingSupported: true,
      ),
    );
  }

  /// Links to an address the operator typed; [authority] is how it is shown.
  Future<void> connectAddress({
    required String host,
    required int port,
    required String scheme,
    required String authority,
    required String? authToken,
  }) async {
    _update(
      _state.copyWith(
        busy: true,
        problem: () => null,
        activity: () => ConnectLinking(authority),
      ),
    );

    final read = await network.read(
      DiscoveredServer(
        name: 'Skotiq Server',
        host: host,
        webPort: port,
        mode: 'headless',
        scheme: scheme,
        authToken: authToken,
        pairingSupported: true,
      ),
    );
    final problem = read.problem;
    if (problem != null && problem.kind != LinkProblemKind.mismatch) {
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectHostProblem(problem),
        ),
      );
      return;
    }
    // connect pairs when the host needs it: one tap on the home network,
    // else the code dialog, the same as for a host found by searching.
    await connect(read.server);
  }

  // ----------------------------------------------------------------- relay

  Future<void> _closeActiveRelayTunnel() =>
      _closeRelayTunnel(_activeRelayTunnel);

  /// Closes [tunnel], and forgets it when it is still the session's. A newer
  /// connect's tunnel is never touched.
  Future<void> _closeRelayTunnel(RigRelayTunnel? tunnel) async {
    if (tunnel == null) return;
    if (identical(_activeRelayTunnel, tunnel)) _activeRelayTunnel = null;
    try {
      await tunnel.close();
    } on Object catch (e) {
      Log.debug('Relay tunnel close failed: $e', source: 'Relay');
    }
  }

  /// Connects to an appliance through a self-hosted relay. The relay exposes
  /// the remote rig's headless API as a loopback port, so the rest of the
  /// connect (pairing, tokens, the event WebSocket) runs through [connect]
  /// unchanged; the relay only splices bytes.
  ///
  /// [presetAuthToken] skips pairing for a saved relay row whose appliance
  /// bearer is stored; null for a first connect. [savedServerDisplayName]
  /// names the saved row; `Relay: <id>` when null.
  Future<void> connectViaRelay({
    required String relayUrl,
    required String applianceId,
    bool allowInsecureTls = false,
    String? presetAuthToken,
    String? savedServerDisplayName,
  }) async {
    _update(
      _state.copyWith(
        busy: true,
        problem: () => null,
        activity: () => const ConnectViaRelay(),
      ),
    );

    final trimmedId = applianceId.trim();
    if (!device.isValidApplianceId(trimmedId)) {
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => const ConnectBadApplianceId(),
        ),
      );
      return;
    }

    final Uri parsedRelay;
    try {
      parsedRelay = Uri.parse(relayUrl.trim());
    } on FormatException catch (e) {
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectBadRelayUrl(e),
        ),
      );
      return;
    }

    // A fresh tunnel per connect attempt: drop any previous one first.
    await _closeActiveRelayTunnel();

    RigRelayTunnel? opened;
    try {
      final tunnel = opened = await device.openRelayTunnel(
        relayUrl: parsedRelay,
        applianceId: trimmedId,
        allowBadTlsCertificate: allowInsecureTls,
      );
      _activeRelayTunnel = tunnel;

      unawaited(
        tunnel.done.then((_) {
          if (_disposed || !identical(_activeRelayTunnel, tunnel)) return;
          _activeRelayTunnel = null;
        }),
      );

      // The loopback hop is local, so the tunnel is dialled over http even
      // when the appliance serves https; its token stays end-to-end.
      final relayServer = DiscoveredServer(
        name: savedServerDisplayName ?? 'Relay: $trimmedId',
        host: '127.0.0.1',
        webPort: tunnel.localPort,
        signalingPort: tunnel.localPort,
        mode: 'headless',
        scheme: 'http',
        authRequired: true,
        pairingSupported: true,
        authToken: presetAuthToken,
      );
      // A connect that did not link (failed, or a newer connect took over)
      // closes this tunnel so no loopback listener leaks and no relay row is
      // saved; a newer connect's tunnel stays up.
      if (!await connect(relayServer) || _disposed) {
        await _closeRelayTunnel(tunnel);
        return;
      }

      // Keyed on (relayUrl, applianceId) so a reconnect updates the row.
      final connectedToken = _state.connected?.authToken;
      try {
        await device.rememberRelay(
          displayName: savedServerDisplayName ?? 'Relay: $trimmedId',
          relayUrl: relayUrl.trim(),
          applianceId: trimmedId,
          allowInsecureTls: allowInsecureTls,
          authToken: connectedToken,
        );
      } catch (e, st) {
        // The relay tunnel and backend are already up.
        Log.error(
          'relay: failed to persist saved server: $e',
          source: 'Relay',
          error: e,
          stackTrace: st,
        );
      }
    } on RigRelayRefused catch (e) {
      await _closeRelayTunnel(opened);
      if (_disposed) return;
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectRelayRefused(e.code, e.message),
        ),
      );
    } catch (e) {
      await _closeRelayTunnel(opened);
      if (_disposed) return;
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectRelayUnreachable(e),
        ),
      );
    }
  }

  // --------------------------------------------------------------- connect

  /// Links this phone to [server]: the compatibility check, pairing when the
  /// rig asks for it, the session, the start-up and saved-server records, the
  /// link watch and push registration. Answers whether the phone is now
  /// linked to it. [savedServerId] names the Saved Servers row the operator
  /// picked, which keeps its own name and address.
  Future<bool> connect(DiscoveredServer server, {String? savedServerId}) async {
    if (_disposed) return false;
    final operation = ++_operation;
    _update(
      _state.copyWith(
        activity: () => ConnectLinking(server.name),
        problem: () => null,
        unpairedHost: () => null,
      ),
    );

    try {
      // Ask the host who it is before anything else: a host that does not
      // answer is reported as that, and only a host that answered is saved.
      final read = await network.read(server);
      if (!_isCurrentOperation(operation)) return false;
      var enrichedServer = read.server;
      // A saved row is shown by the name the operator gave it.
      if (savedServerId != null) {
        enrichedServer = enrichedServer.copyWith(name: server.name);
      }
      final problem = read.problem;
      if (problem != null) {
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () => ConnectHostProblem(
              problem,
              mismatchedHost: problem.kind == LinkProblemKind.mismatch
                  ? enrichedServer
                  : null,
            ),
          ),
        );
        return false;
      }

      var authToken = enrichedServer.authToken;
      if (enrichedServer.authRequired &&
          (authToken == null || authToken.isEmpty) &&
          enrichedServer.pairingSupported) {
        // One-tap pairing when /api/info advertised lan-open mode: the host
        // mints a token for a request from a trusted private-LAN source with
        // no code. The pinned fingerprint is checked before the minted token
        // is trusted. A host that wants a code (or was reached over a tailnet
        // or relay) falls through to the code dialog.
        if (enrichedServer.lanPairing) {
          try {
            final paired = await device.pairing.pairOneTap(
              enrichedServer,
              deviceName: device.pairingDeviceName,
              fullAccess: true,
            );
            if (!_isCurrentOperation(operation)) return false;
            Log.info(
              'One-tap LAN pairing succeeded for '
              '${enrichedServer.host}:${enrichedServer.webPort} — '
              'no code needed',
              source: 'Discovery',
            );
            authToken = paired.token;
            enrichedServer = enrichedServer.copyWith(authToken: authToken);
          } on RigPairingFailure catch (failure) {
            if (!_isCurrentOperation(operation)) return false;
            switch (failure.kind) {
              case RigPairingFailureKind.fingerprintMismatch:
                // The host reached is not the one trusted: say so rather
                // than dropping to the code dialog.
                _update(
                  _state.copyWith(
                    busy: false,
                    activity: () => null,
                    problem: () => ConnectOneTapIdentity(failure),
                  ),
                );
                return false;
              case RigPairingFailureKind.refused
                  when failure.cause is RemotePairingException:
                Log.warning(
                  'One-tap LAN pairing unavailable, falling back to code: '
                  '${failure.cause}',
                  source: 'Discovery',
                );
              case RigPairingFailureKind.unreachable:
                throw failure.cause!;
              default:
                break;
            }
          }
        }

        if (!_isCurrentOperation(operation)) return false;

        if (authToken == null || authToken.isEmpty) {
          final pairedToken = await _pairWithCode(enrichedServer);
          if (!_isCurrentOperation(operation)) return false;
          if (pairedToken == null) {
            if (!_disposed) {
              _update(
                _state.copyWith(
                  busy: false,
                  activity: () => null,
                  unpairedHost: () => enrichedServer,
                ),
              );
            }
            return false;
          }
          authToken = pairedToken;
          enrichedServer = enrichedServer.copyWith(authToken: authToken);
        }
      }

      final outcome = await network.probe(enrichedServer);
      if (!_isCurrentOperation(operation)) return false;

      if (outcome == ServerProbeOutcome.reachable) {
        Log.info('Connection successful!', source: 'Discovery');

        // The collaboration identity lets the backend join the host's viewer
        // slots as soon as the socket opens; its viewer id matches what the
        // host computes from the bearer.
        final identity = await device.collaborationIdentity(
          enrichedServer.authToken,
        );
        if (!_isCurrentOperation(operation)) return false;
        final handle = await session.open(enrichedServer, identity);
        if (handle == null) return false;
        if (!_isCurrentOperation(operation) || !session.isCurrent(handle)) {
          return false;
        }

        // A reachable /api/info probe is not a live session: the server is
        // published only after the WebSocket handshake above succeeded. The
        // address form did its job; left open, it would hold off every
        // lost-session retry.
        _update(
          _state.copyWith(
            connected: () => enrichedServer,
            busy: false,
            activity: () => null,
            manualEntryOpen: false,
          ),
        );
        _lostSessionServer = null;

        // Persistence is secondary to the live session: a disk or keychain
        // failure must not turn it into a connection error. The relay
        // tunnel's loopback endpoint is ephemeral and must not replace the
        // last server; a different host is still saved while a tunnel is open.
        final tunnel = _activeRelayTunnel;
        final persistServer = shouldPersistConnectedServer(
          host: enrichedServer.host,
          port: enrichedServer.webPort,
          tunnelHost: tunnel == null ? null : '127.0.0.1',
          tunnelPort: tunnel?.localPort,
        );
        if (persistServer) {
          try {
            await network.saveLastServer(enrichedServer);
          } catch (e, stackTrace) {
            Log.error(
              'Could not cache connected server for startup reconnect: $e',
              source: 'Discovery',
              error: e,
              stackTrace: stackTrace,
            );
          }
        }
        if (!_isCurrentOperation(operation) || !session.isCurrent(handle)) {
          return false;
        }
        // A saved row keeps the name and address the operator gave it. Relay
        // sessions are saved by [connectViaRelay] under their relay identity,
        // not their loopback port.
        if (savedServerId != null) {
          await device.touchSavedServer(savedServerId);
        } else if (persistServer) {
          await device.rememberServer(enrichedServer);
        }
        if (!_isCurrentOperation(operation) || !session.isCurrent(handle)) {
          return false;
        }

        startLinkWatch();

        // Lets the host push critical alerts to a phone that is asleep or
        // off the LAN. A failure there never disturbs the session.
        final link = session.link;
        if (link != null) unawaited(device.registerPush(link));

        session.afterLinked(
          () => _isCurrentOperation(operation) && session.isCurrent(handle),
        );
        return true;
      } else if (outcome == ServerProbeOutcome.authRejected) {
        // The host answered and refused this phone's token: its pairings were
        // reset (a reinstall, a cleared database). That is "pair again".
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () => ConnectForgotten(enrichedServer.name),
            unpairedHost: () => enrichedServer.copyWith(clearAuthToken: true),
          ),
        );
      } else {
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () => ConnectNoSession(
              enrichedServer.host,
              enrichedServer.webPort,
              tokenMissing:
                  enrichedServer.authRequired &&
                  (enrichedServer.authToken == null ||
                      enrichedServer.authToken!.isEmpty),
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      if (!_isCurrentOperation(operation)) return false;
      Log.error(
        'Connection error: $e',
        source: 'Discovery',
        error: e,
        stackTrace: stackTrace,
      );
      _update(
        _state.copyWith(
          busy: false,
          activity: () => null,
          problem: () => ConnectFailedWith(e),
        ),
      );
    }
    return false;
  }

  /// Pairs with the code the operator types. Null when no token came of it;
  /// the state then says why.
  Future<String?> _pairWithCode(DiscoveredServer server) async {
    final answer = await device.askPairingCode(server);
    switch (answer) {
      case PairingPromptNotReady():
        _update(
          _state.copyWith(
            busy: false,
            activity: () => null,
            problem: () => const ConnectUiNotReady(),
          ),
        );
        return null;
      case PairingPromptScan():
        if (_disposed) return null;
        _update(_state.copyWith(busy: false, activity: () => null));
        await device.scanQrInstead();
        return null;
      case PairingPromptClosed():
        if (!_disposed) {
          _update(_state.copyWith(busy: false, activity: () => null));
        }
        return null;
      case PairingPromptCode(:final code, :final fullAccess):
        if (code.isEmpty || _disposed) {
          if (!_disposed) {
            _update(_state.copyWith(busy: false, activity: () => null));
          }
          return null;
        }
        _update(
          _state.copyWith(
            activity: () => ConnectPairing(server.host, server.webPort),
          ),
        );
        try {
          final paired = await device.pairing.pairWithCode(
            server,
            code: code,
            deviceName: device.pairingDeviceName,
            fullAccess: fullAccess,
          );
          return paired.token;
        } on RigPairingFailure catch (failure) {
          if (_disposed) return null;
          _update(
            _state.copyWith(
              busy: false,
              activity: () => null,
              problem: () => ConnectPairingFailed(failure, server),
            ),
          );
          return null;
        }
    }
  }

  /// Leaves the connection screen without a rig ("Look around").
  Future<void> skip() async {
    ++_operation;
    _update(_state.copyWith(skipped: true, busy: false, problem: () => null));
    // A later connect to a (possibly different) host registers for pushes
    // again rather than assuming it already is.
    device.resetPush();
    try {
      await session.disconnect();
    } catch (e) {
      if (_disposed) return;
      _update(
        _state.copyWith(skipped: false, problem: () => ConnectCannotLeave(e)),
      );
      return;
    }
    unawaited(_closeActiveRelayTunnel());
  }

  // ------------------------------------------------------------ link watch

  void _stopLinkWatch() {
    _linkStateSubscription?.cancel();
    _linkStateSubscription = null;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    // A pending retry belongs to the session being torn down. The
    // lost-session path re-arms it right after; every other caller (a fresh
    // connect, dispose) wants it gone.
    _lostSessionRetryTimer?.cancel();
    _lostSessionRetryTimer = null;
    if (_state.stale) _update(_state.copyWith(stale: false));
  }

  /// Re-arms the connect after the session was declared lost: re-dials the
  /// server it was lost on (token included), and runs discovery only when
  /// there was none.
  void _scheduleLostSessionRetry() {
    if (_disposed) return;
    _lostSessionRetryTimer?.cancel();
    final delay = _retryDelay(_lostSessionRetryAttempt);
    _lostSessionRetryAttempt++;
    _lostSessionRetryTimer = Timer(delay, () async {
      _lostSessionRetryTimer = null;
      if (_disposed) return;
      // A dial from the background tends to fail and leaves "No answer" on
      // screen; the return to the foreground dials at once instead.
      if (_appInBackground) {
        _scheduleLostSessionRetry();
        return;
      }
      // Never fight the operator: when they already reconnected, opened the
      // address form, chose to look around, or a connect is running, sit this
      // round out.
      if (_state.connected != null ||
          _state.busy ||
          _state.manualEntryOpen ||
          _state.skipped) {
        if (_state.connected == null && !_state.skipped) {
          _scheduleLostSessionRetry();
        }
        return;
      }
      final target = _lostSessionServer;
      if (target != null) {
        await connect(target);
      } else {
        await autoConnect();
      }
      if (_disposed) return;
      if (_state.connected == null && !_state.skipped) {
        _scheduleLostSessionRetry();
      }
    });
  }

  void _armDisconnectGrace(HostLink link) {
    _disconnectGraceTimer ??= Timer(
      _connectionGracePeriod,
      () => _onDisconnectGraceExpired(link),
    );
  }

  Future<void> _onDisconnectGraceExpired(HostLink link) async {
    _disconnectGraceTimer = null;
    // Not lost: paused. The return to the foreground starts a fresh grace.
    if (_appInBackground) return;
    if (_disposed) return;
    if (!session.isLinked ||
        link.connectionState == BackendConnectionState.connected) {
      return;
    }
    Log.error(
      'WebSocket disconnected for ${_connectionGracePeriod.inSeconds}s — declaring connection lost',
      source: 'Connection',
    );
    _stopLinkWatch();
    // Captured before the disconnect below: that lands on a resting backend,
    // which clears the connected server at once ([backendChanged]).
    _lostSessionServer = _state.connected ?? _lostSessionServer;
    // The next connect may land on a different host, which hands back the
    // same push token; it has to register there again.
    device.resetPush();
    try {
      await session.disconnect();
    } catch (e, stackTrace) {
      Log.error(
        'Could not detach the lost backend session: $e',
        source: 'Connection',
        error: e,
        stackTrace: stackTrace,
      );
      if (!_disposed) report(const ConnectLostStillSettling());
      return;
    }
    unawaited(_closeActiveRelayTunnel());
    _update(
      _state.copyWith(
        connected: () => null,
        busy: false,
        stale: false,
        problem: () => const ConnectSessionLost(),
        activity: () => null,
      ),
    );
    _scheduleLostSessionRetry();
  }

  /// The app is back in the foreground.
  void appResumed() {
    _appInBackground = false;
    _setHeartbeatPaused(false);
    final link = session.link;
    if (link != null &&
        link.connectionState != BackendConnectionState.connected &&
        // A terminal failure (a version mismatch) gets no grace and no redial.
        link.connectionState != BackendConnectionState.error) {
      // The socket dropped while the heartbeat was paused. Dial now rather
      // than after the backend's backoff, and time the grace from here: a
      // timer that came due in the background must not tear the session down
      // the moment the user looks.
      _disconnectGraceTimer?.cancel();
      _disconnectGraceTimer = null;
      unawaited(link.reconnectNow());
      _armDisconnectGrace(link);
    }
    // A session already given up on: try now rather than after the backoff.
    final lost = _lostSessionServer;
    if (lost != null &&
        _state.connected == null &&
        _lostSessionRetryTimer != null &&
        !_state.busy &&
        !_state.manualEntryOpen &&
        !_state.skipped) {
      _lostSessionRetryTimer?.cancel();
      _lostSessionRetryTimer = null;
      _lostSessionRetryAttempt = 0;
      _update(_state.copyWith(busy: true, problem: () => null));
      unawaited(() async {
        await connect(lost);
        if (_disposed) return;
        if (_state.connected == null && !_state.skipped) {
          _update(_state.copyWith(busy: false));
          _scheduleLostSessionRetry();
        }
      }());
    }
  }

  void appBackgrounded() {
    _appInBackground = true;
    _setHeartbeatPaused(true);
  }

  void _setHeartbeatPaused(bool paused) {
    final link = session.link;
    if (link == null) return;
    if (paused) {
      link.pauseWebSocketHeartbeatForAppLifecycle();
    } else {
      link.resumeWebSocketHeartbeatForAppLifecycle();
    }
  }

  /// Follows the open link's state: a drop shows the stale banner at once and
  /// ends the session after the grace period. Idempotent: it cancels any
  /// earlier watch first.
  void startLinkWatch() {
    _stopLinkWatch();
    // A live session again: the next drop starts its backoff from the top.
    _lostSessionRetryAttempt = 0;
    final link = session.link;
    if (link == null) return;

    _linkStateSubscription = link.connectionStateStream.listen((linkState) {
      if (_disposed) return;
      switch (linkState) {
        case BackendConnectionState.connected:
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
          if (_state.stale) {
            _update(_state.copyWith(stale: false, activity: () => null));
          }
        case BackendConnectionState.connecting:
          // First handshake in flight: no prior session to go stale, but a
          // slow first handshake must not trigger the tear-down.
          _disconnectGraceTimer?.cancel();
          _disconnectGraceTimer = null;
        case BackendConnectionState.error:
          // Terminal (a version mismatch): the backend stopped retrying, so
          // there is no recovery to wait for.
          if (!_state.stale) _update(_state.copyWith(stale: true));
        case BackendConnectionState.reconnecting:
        case BackendConnectionState.disconnected:
          if (!_state.stale) _update(_state.copyWith(stale: true));
          _armDisconnectGrace(link);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _stopLinkWatch();
    final tunnel = _activeRelayTunnel;
    _activeRelayTunnel = null;
    if (tunnel != null) unawaited(tunnel.close());
    super.dispose();
  }
}
