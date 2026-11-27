import 'dart:io';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import 'linked_rig_store.dart';
import 'rig_pairing_service.dart';

export 'rig_pairing_service.dart';

/// Pairs this desktop with an imaging computer and remembers it.
class RigLinkService extends RigPairingService {
  RigLinkService({required this.store, super.clientFactory})
    : super(deviceId: store.deviceId, deviceType: PairingDeviceType.desktop);

  final LinkedRigStore store;

  /// The name this desktop is listed under on the host, unless the person
  /// changes it: `Skotiq on <computer> (Linux)`.
  static String defaultDeviceName() {
    final os = Platform.isLinux
        ? 'Linux'
        : Platform.isWindows
        ? 'Windows'
        : Platform.isMacOS
        ? 'macOS'
        : Platform.operatingSystem;
    return 'Skotiq on ${hostComputerName()} ($os)';
  }

  /// Whether [token] still opens a session on [host].
  Future<ServerProbeOutcome> checkToken(
    String host,
    int port,
    String token, {
    String scheme = 'http',
  }) => EnhancedSkotiqDiscovery.probeServer(
    host,
    port,
    authToken: token,
    scheme: scheme,
  );

  /// Remember [host] as the rig to launch linked to.
  Future<LinkedRig> remember(DiscoveredServer host, RigPairing pairing) async {
    final rig = LinkedRig(
      host: host.host,
      port: host.webPort,
      scheme: host.scheme,
      name: host.displayName,
      fingerprint: host.fingerprint,
      version: host.version == 'unknown' ? null : host.version,
      platform: host.platform,
      hostMode: host.hostMode,
      tokenScope: pairing.scope,
      pairedAt: DateTime.now().toUtc(),
    );
    await store.save(rig, token: pairing.token);
    return rig;
  }
}
