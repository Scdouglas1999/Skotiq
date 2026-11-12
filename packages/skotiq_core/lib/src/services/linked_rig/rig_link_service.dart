import 'dart:async';
import 'dart:io';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import 'linked_rig_store.dart';

/// What went wrong while pairing with an imaging computer, in the terms the
/// connect flow explains to a person.
enum RigPairingFailureKind {
  /// One-tap pairing is not offered for this connection: the host requires a
  /// code, or this desktop did not reach it from the local network.
  oneTapUnavailable,
  invalidCode,
  expiredCode,
  rateLimited,

  /// The host at this address does not have the identity the list showed.
  fingerprintMismatch,
  unreachable,
  refused,
}

class RigPairingFailure implements Exception {
  const RigPairingFailure(this.kind, this.message);

  final RigPairingFailureKind kind;
  final String message;

  @override
  String toString() => message;
}

/// A successful pairing: the token and what it allows.
class RigPairing {
  const RigPairing({required this.token, required this.scope});

  final String token;

  /// `control` or `admin` (or a fine-grained spec on hosts that mint one).
  final String scope;
}

/// Pairs this desktop with an imaging computer and remembers it.
///
/// Every pairing call pins the fingerprint the list showed: the host is asked
/// for `/api/info` again first, and the request is not sent if a different
/// identity answers.
class RigLinkService {
  RigLinkService({
    required this.store,
    RemotePairingClient Function(DiscoveredServer host)? clientFactory,
  }) : _clientFactory = clientFactory ?? _defaultClient;

  final LinkedRigStore store;
  final RemotePairingClient Function(DiscoveredServer host) _clientFactory;

  static RemotePairingClient _defaultClient(DiscoveredServer host) =>
      RemotePairingClient(
        host: host.host,
        port: host.webPort,
        scheme: host.scheme,
        pinnedFingerprint: host.fingerprint,
        timeout: const Duration(seconds: 10),
      );

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

  /// One-tap pairing through `POST /api/pairing/lan-claim`. Grants control.
  Future<RigPairing> pairOneTap(
    DiscoveredServer host, {
    required String deviceName,
  }) async {
    final client = _clientFactory(host);
    final RemotePairingVerifyResult? result;
    try {
      result = await client.lanClaim(
        deviceId: await store.deviceId(),
        deviceName: deviceName,
        deviceType: 'desktop',
      );
    } on RemotePairingFingerprintMismatch catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.fingerprintMismatch,
        e.message,
      );
    } on RemotePairingException catch (e) {
      throw RigPairingFailure(RigPairingFailureKind.refused, e.message);
    } on Object catch (e) {
      throw RigPairingFailure(RigPairingFailureKind.unreachable, '$e');
    }
    if (result == null) {
      throw const RigPairingFailure(
        RigPairingFailureKind.oneTapUnavailable,
        'This imaging computer asks for a pairing code.',
      );
    }
    return _accept(result);
  }

  /// Asks [host] to make a pairing code. A host with no screen (a headless
  /// one) keeps it in a file in its data folder and, when started with
  /// `--pairing-print-codes`, prints it to its console; the answer says where,
  /// never what.
  Future<RemotePairingStartResult> requestCode(DiscoveredServer host) async {
    try {
      return await _clientFactory(host).start();
    } on RemotePairingException catch (e) {
      throw RigPairingFailure(
        e.statusCode == 429
            ? RigPairingFailureKind.rateLimited
            : RigPairingFailureKind.refused,
        e.message,
      );
    } on Object catch (e) {
      throw RigPairingFailure(RigPairingFailureKind.unreachable, '$e');
    }
  }

  /// Pairing with the short code the host shows (`WORD-WORD-NNNN`).
  /// [fullAccess] asks for admin scope, which lets this desktop manage the
  /// host's stored passwords, backups, plugins and updates too.
  Future<RigPairing> pairWithCode(
    DiscoveredServer host, {
    required String code,
    required String deviceName,
    required bool fullAccess,
  }) async {
    final client = _clientFactory(host);
    final RemotePairingVerifyResult result;
    try {
      result = await client.verify(
        code: normalizePairingCode(code),
        deviceId: await store.deviceId(),
        deviceName: deviceName,
        deviceType: 'desktop',
        requestedScope: fullAccess ? 'admin' : 'control',
      );
    } on RemotePairingFingerprintMismatch catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.fingerprintMismatch,
        e.message,
      );
    } on RemotePairingException catch (e) {
      throw RigPairingFailure(RigPairingFailureKind.refused, e.message);
    } on Object catch (e) {
      throw RigPairingFailure(RigPairingFailureKind.unreachable, '$e');
    }
    return _accept(result);
  }

  RigPairing _accept(RemotePairingVerifyResult result) {
    final token = result.token;
    if (result.success && token != null && token.isNotEmpty) {
      return RigPairing(token: token, scope: result.tokenScope ?? 'control');
    }
    final kind = switch (result.error) {
      'invalid_pairing_code' => RigPairingFailureKind.invalidCode,
      'pairing_code_expired' ||
      'pairing_code_already_used' => RigPairingFailureKind.expiredCode,
      _ when result.statusCode == 429 => RigPairingFailureKind.rateLimited,
      _ => RigPairingFailureKind.refused,
    };
    throw RigPairingFailure(
      kind,
      result.message ?? result.error ?? 'Pairing was refused.',
    );
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

/// Upper-case and trim a typed pairing code; tolerate spaces for dashes.
String normalizePairingCode(String raw) => raw
    .trim()
    .toUpperCase()
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp(r'-+'), '-');
