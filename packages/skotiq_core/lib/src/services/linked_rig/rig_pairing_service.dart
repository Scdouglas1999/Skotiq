import 'dart:async';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_remote_protocol/wire.dart' show ApiErrorCodes;

/// What went wrong while pairing with an imaging computer, in the terms the
/// connect flow explains to a person.
enum RigPairingFailureKind {
  /// One-tap pairing is not offered for this connection: the host requires a
  /// code, or this client did not reach it from the local network.
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
  const RigPairingFailure(
    this.kind,
    this.message, {
    this.hostMessage,
    this.statusCode,
    this.cause,
  });

  final RigPairingFailureKind kind;
  final String message;

  /// The host's own words when it answered and refused.
  final String? hostMessage;

  /// The HTTP status of a refusal the host answered with.
  final int? statusCode;

  /// The exception that ended the request before the host answered.
  final Object? cause;

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

/// Pairs this client with an imaging computer.
///
/// Every pairing call pins the fingerprint the host was listed with: the host
/// is asked for `/api/info` again first, and the request is not sent if a
/// different identity answers.
class RigPairingService {
  RigPairingService({
    required Future<String> Function() deviceId,
    required this.deviceType,
    Duration timeout = const Duration(seconds: 10),
    RemotePairingClient Function(DiscoveredServer host)? clientFactory,
  }) : _deviceId = deviceId,
       _clientFactory =
           clientFactory ?? ((host) => _defaultClient(host, timeout));

  final Future<String> Function() _deviceId;

  /// What this client pairs as.
  final PairingDeviceType deviceType;
  final RemotePairingClient Function(DiscoveredServer host) _clientFactory;

  static RemotePairingClient _defaultClient(
    DiscoveredServer host,
    Duration timeout,
  ) => RemotePairingClient(
    host: host.host,
    port: host.webPort,
    scheme: host.scheme,
    pinnedFingerprint: host.fingerprint,
    timeout: timeout,
  );

  /// One-tap pairing through `POST /api/pairing/lan-claim`. [fullAccess]
  /// asks for admin scope; otherwise the host grants control.
  Future<RigPairing> pairOneTap(
    DiscoveredServer host, {
    required String deviceName,
    bool fullAccess = false,
    PairingDeviceType? deviceType,
  }) async {
    final client = _clientFactory(host);
    final RemotePairingVerifyResult? result;
    try {
      result = await client.lanClaim(
        deviceId: await _deviceId(),
        deviceName: deviceName,
        deviceType: deviceType ?? this.deviceType,
        requestedScope: fullAccess ? _adminScope : null,
      );
    } on RemotePairingFingerprintMismatch catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.fingerprintMismatch,
        e.message,
        cause: e,
      );
    } on RemotePairingException catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.refused,
        e.message,
        cause: e,
      );
    } on Object catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.unreachable,
        '$e',
        cause: e,
      );
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
        statusCode: e.statusCode,
        cause: e,
      );
    } on Object catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.unreachable,
        '$e',
        cause: e,
      );
    }
  }

  /// Pairing with the short code the host shows (`WORD-WORD-NNNN`).
  /// [fullAccess] asks for admin scope, which lets this client manage the
  /// host's stored passwords, backups, plugins and updates too.
  Future<RigPairing> pairWithCode(
    DiscoveredServer host, {
    required String code,
    required String deviceName,
    required bool fullAccess,
    bool normalizeCode = true,
  }) async {
    final client = _clientFactory(host);
    final RemotePairingVerifyResult result;
    try {
      result = await client.verify(
        code: normalizeCode ? normalizePairingCode(code) : code,
        deviceId: await _deviceId(),
        deviceName: deviceName,
        deviceType: deviceType,
        requestedScope: fullAccess ? _adminScope : _controlScope,
      );
    } on RemotePairingFingerprintMismatch catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.fingerprintMismatch,
        e.message,
        cause: e,
      );
    } on RemotePairingException catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.refused,
        e.message,
        cause: e,
      );
    } on Object catch (e) {
      throw RigPairingFailure(
        RigPairingFailureKind.unreachable,
        '$e',
        cause: e,
      );
    }
    return _accept(result);
  }

  static const _adminScope = 'admin';
  static const _controlScope = 'control';

  RigPairing _accept(RemotePairingVerifyResult result) {
    final token = result.token;
    if (result.success && token != null && token.isNotEmpty) {
      return RigPairing(
        token: token,
        scope: result.tokenScope ?? _controlScope,
      );
    }
    final kind = switch (result.error) {
      ApiErrorCodes.invalidPairingCode => RigPairingFailureKind.invalidCode,
      ApiErrorCodes.pairingCodeExpired ||
      ApiErrorCodes.pairingCodeAlreadyUsed => RigPairingFailureKind.expiredCode,
      _ when result.statusCode == 429 => RigPairingFailureKind.rateLimited,
      _ => RigPairingFailureKind.refused,
    };
    throw RigPairingFailure(
      kind,
      result.message ?? result.error ?? 'Pairing was refused.',
      hostMessage: result.message,
      statusCode: result.statusCode,
    );
  }
}

/// Upper-case and trim a typed pairing code; tolerate spaces for dashes.
String normalizePairingCode(String raw) => raw
    .trim()
    .toUpperCase()
    .replaceAll(RegExp(r'\s+'), '-')
    .replaceAll(RegExp(r'-+'), '-');
