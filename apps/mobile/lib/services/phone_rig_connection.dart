import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_app/screens/connection/rig_connect_entry.dart';
import 'package:skotiq_app/screens/connection/rig_pairing_text.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_relay/client.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../screens/qr_scanner_screen.dart';
import '../widgets/pairing_code_dialog.dart';
import 'mobile_pairing_service.dart';
import 'push_registration_service.dart';
import 'saved_servers_service.dart';

/// The phone runs the core connect flow on its own device side, and Settings
/// > Connection's Connect returns to its connection screen.
final List<Override> phoneConnectionOverrides = [
  rigConnectionDeviceProvider.overrideWith((ref) {
    final device = PhoneRigConnectionDevice(
      connection: () => ref.read(rigConnectionProvider),
      savedServers: () => ref.read(savedServersServiceProvider),
    );
    ref.onDispose(device.dispose);
    return device;
  }),
  openRigConnectProvider.overrideWith(
    (ref) =>
        (_) => ref.read(rigConnectionProvider).showConnectionScreen(),
  ),
];

/// Navigator of the connection screen's [MaterialApp]. Its dialogs and the QR
/// scanner open on this context: the shell's own context sits above that
/// [MaterialApp], so [Navigator.of] on it finds nothing in release builds.
final phoneConnectionNavigatorKey = GlobalKey<NavigatorState>();

/// Build context inside the connection screen (has Navigator, Theme and
/// localizations), or null before its first frame.
BuildContext? phoneConnectionUiContext() {
  final context = phoneConnectionNavigatorKey.currentContext;
  return context != null && context.mounted ? context : null;
}

/// The phone's side of the core connect flow: its pairing identity, its
/// dialogs, the relay client, the saved servers and push registration.
class PhoneRigConnectionDevice implements RigConnectionDevice {
  PhoneRigConnectionDevice({
    required RigConnectionService Function() connection,
    required SavedServersService Function() savedServers,
  }) : _connection = connection,
       _savedServers = savedServers;

  final RigConnectionService Function() _connection;
  final SavedServersService Function() _savedServers;

  /// Registers this device's push token (APNs on iOS, FCM on Android) with
  /// the linked host. Created on first use so its channel handler is attached
  /// only once there is a session.
  PushRegistrationService? _pushRegistration;

  @override
  final RigPairingService pairing = MobilePairingService.pairing();

  @override
  String get pairingDeviceName => MobilePairingService.deviceName();

  @override
  Future<RigCollaborationIdentity> collaborationIdentity(String? authToken) =>
      buildCollaborationIdentity(authToken);

  @override
  Future<PairingPromptAnswer> askPairingCode(DiscoveredServer server) async {
    final uiContext = phoneConnectionUiContext();
    if (uiContext == null) return const PairingPromptNotReady();
    // The dialog owns its TextEditingController (see PairingCodeDialog),
    // because the route outlives showDialog's future.
    final answer = await showDialog<PairingDialogResult>(
      context: uiContext,
      builder: (ctx) => PairingCodeDialog(
        host: server.host,
        port: server.webPort,
        serverName: server.name,
        requestCode: hostHasNoScreen(server)
            ? () => pairing.requestCode(server)
            : null,
      ),
    );
    if (answer == null) return const PairingPromptClosed();
    if (answer.scan) return const PairingPromptScan();
    return PairingPromptCode(answer.code, fullAccess: answer.admin);
  }

  @override
  Future<void> scanQrInstead() => scanQrAndConnect(_connection());

  @override
  bool isValidApplianceId(String id) => _isValidApplianceId(id);

  @override
  Future<RigRelayTunnel> openRelayTunnel({
    required Uri relayUrl,
    required String applianceId,
    required bool allowBadTlsCertificate,
  }) async {
    try {
      return _RelayTunnel(
        await RelayTunnelClient.connect(
          relayUrl: relayUrl,
          applianceId: applianceId,
          allowBadTlsCertificate: allowBadTlsCertificate,
          onLog: (message) => Log.debug(message, source: 'Relay'),
        ),
      );
    } on RelayTunnelException catch (e) {
      throw RigRelayRefused(e.code, e.message);
    }
  }

  /// Mirrors a connected direct (LAN / Tailscale) server into the Saved
  /// Servers list, keyed on host:port. The rig's advertised tailnet address is
  /// recorded when it is a real tailnet endpoint, so "Connect over Tailscale"
  /// can prefill it later.
  @override
  Future<void> rememberServer(DiscoveredServer server) async {
    final tailscaleHost = server.tailscaleHost;
    final validTailscaleHost =
        tailscaleHost != null &&
            tailscaleHost.isNotEmpty &&
            SavedServer.isTailscaleEndpoint(tailscaleHost)
        ? tailscaleHost
        : null;
    try {
      await _savedServers().upsert(
        displayName: server.name,
        host: server.host,
        port: server.webPort,
        authToken: server.authToken,
        pinnedFingerprint: server.fingerprint,
        scheme: server.scheme,
        lastConnectedAt: DateTime.now(),
        tailscaleHost: validTailscaleHost,
      );
    } catch (e, st) {
      Log.error(
        'saved_servers: failed to upsert connected server: $e',
        source: 'Discovery',
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> touchSavedServer(String id) async {
    try {
      await _savedServers().touchLastConnected(id);
    } catch (e, st) {
      Log.error(
        'saved_servers: failed to stamp $id as connected: $e',
        source: 'Discovery',
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> rememberRelay({
    required String displayName,
    required String relayUrl,
    required String applianceId,
    required bool allowInsecureTls,
    required String? authToken,
  }) => _savedServers().upsertRelay(
    displayName: displayName,
    relayUrl: relayUrl,
    relayApplianceId: applianceId,
    relayAllowInsecureTls: allowInsecureTls,
    authToken: authToken,
    lastConnectedAt: DateTime.now(),
  );

  /// Off iOS/Android there is nothing to register; on an Android build
  /// without a Firebase project the native side reports `fcm_unconfigured`
  /// and the service stays dormant. The service logs every network or host
  /// error itself.
  @override
  Future<void> registerPush(HostLink link) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    final deviceId = await MobilePairingService.deviceId();
    final service = _pushRegistration ??= PushRegistrationService();
    await service.ensureRegistered(backend: link, deviceId: deviceId);
  }

  @override
  void resetPush() => _pushRegistration?.reset();

  void dispose() => _pushRegistration?.dispose();
}

bool _isValidApplianceId(String id) => isValidApplianceId(id);

class _RelayTunnel implements RigRelayTunnel {
  _RelayTunnel(this._client);
  final RelayTunnelClient _client;

  @override
  int get localPort => _client.localPort;

  @override
  Future<void> get done => _client.done;

  @override
  Future<void> close() => _client.close();
}

/// Opens the QR scanner and links to the computer the scanned code names.
/// The scanner checks the code's schema and host before it returns one.
Future<void> scanQrAndConnect(RigConnectionService connection) async {
  final uiContext = phoneConnectionUiContext();
  if (uiContext == null) {
    connection.report(const ConnectUiNotReady());
    return;
  }

  QrConnectionData? data;
  try {
    data = await Navigator.of(uiContext).push<QrConnectionData>(
      MaterialPageRoute(
        builder: (_) => const QrScannerScreen(),
        fullscreenDialog: true,
      ),
    );
  } catch (e, stackTrace) {
    Log.error(
      'QR scanner failed: $e',
      source: 'Discovery',
      error: e,
      stackTrace: stackTrace,
    );
    connection.report(ConnectScannerFailed(e));
    return;
  }

  if (data == null) return;
  await connection.connectFromQr(data);
}

/// The identity a session joins the host's collaboration slots with.
///
/// * `viewerId`: `computeServerFingerprint(authToken)`, the digest the host
///   computes from the bearer, so the join is not taken for impersonation;
///   without a token, the stable per-device id so the slot still has an id.
/// * `deviceName`: the stable per-device id, a machine-readable key in the
///   slot list.
/// * `displayName`: `PLATFORM · SHORTID`.
Future<RigCollaborationIdentity> buildCollaborationIdentity(
  String? authToken,
) async {
  // The same id the pairing flow uses, so the slot label matches the pairing.
  final deviceId = await MobilePairingService.deviceId();
  // The suffix bytes are random; the prefix is the constant `mobile:`.
  final shortId = deviceId.length > 14
      ? deviceId.substring(deviceId.length - 6)
      : deviceId;
  final platformLabel = Platform.isIOS
      ? 'iPhone'
      : Platform.isAndroid
      ? 'Android'
      : Platform.operatingSystem;
  final viewerId = (authToken != null && authToken.trim().isNotEmpty)
      ? computeServerFingerprint(authToken)
      : deviceId;
  return RigCollaborationIdentity(
    viewerId: viewerId,
    deviceName: deviceId,
    displayName: '$platformLabel · $shortId',
  );
}
