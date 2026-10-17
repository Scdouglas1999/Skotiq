import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../database/pairing_database.dart';

/// Result of a pairing attempt
enum PairingResult {
  success,
  invalidCode,
  codeExpired,
  codeAlreadyUsed,
  deviceAlreadyPaired,
}

/// Result of a token verification
enum TokenVerificationResult {
  valid,
  invalid,
  deviceRevoked,
  deviceNotFound,

  /// The device's session token is past its `expiresAt` timestamp. The DB
  /// row may still be present (the headless sweep purges it on the next
  /// tick). Treat the same as [deviceRevoked]: deny access and force re-pair.
  expired,
}

typedef PairingCompletion = ({PairingResult result, String? sessionToken});

/// Callback invoked by [TokenManager] whenever a paired device's session
/// token is revoked or expires from the auth middleware's point of view.
/// The headless server registers a listener so it can evict the
/// corresponding entry from `_pairedSessionTokens` synchronously.
///
/// The callback receives the raw session token (NOT the device id) because
/// the in-memory map is keyed by token value.
typedef SessionTokenRevocationListener = void Function(String sessionToken);

/// Result of a sweep over `paired_devices` to surface tokens that the
/// in-memory auth map must no longer honour. See
/// [TokenManager.purgeExpiredAndRevokedSessions].
class TokenSweepResult {
  /// Session tokens removed because their `expires_at` has passed. The DB
  /// rows are also hard-deleted by the sweep.
  final List<String> expiredTokens;

  /// Session tokens removed because the device was revoked
  /// (`is_active = false`). DB rows are RETAINED for audit purposes; only
  /// the in-memory entry is evicted via the listener callback.
  final List<String> revokedTokens;

  const TokenSweepResult({
    required this.expiredTokens,
    required this.revokedTokens,
  });

  bool get isEmpty => expiredTokens.isEmpty && revokedTokens.isEmpty;
  int get totalCount => expiredTokens.length + revokedTokens.length;
}

/// Manages authentication tokens and pairing for WebRTC connections
class TokenManager {
  final PairingDatabase _database;
  final Random _random = Random.secure();
  static const int _maxPairingCreationAttempts = 5;

  /// The process has one hardware-owning host, but GUI and HTTP pairing use
  /// separate [TokenManager] instances over the same Drift file. Keep the
  /// host's cache listener process-wide so a revoke initiated by either
  /// instance evicts the server's in-memory bearer immediately.
  static TokenManager? _revocationListenerOwner;
  static SessionTokenRevocationListener? _processRevocationListener;

  /// Words for generating memorable pairing codes
  static const _codeWords = [
    'STAR',
    'MOON',
    'NOVA',
    'ORION',
    'LYRA',
    'CYGNUS',
    'VEGA',
    'SIRIUS',
    'PLUTO',
    'MARS',
    'VENUS',
    'COMET',
    'NEBULA',
    'GALAXY',
    'PULSAR',
    'QUASAR',
    'METEOR',
    'COSMOS',
    'ZENITH',
    'ASTRO',
  ];

  TokenManager(this._database);

  // Token generation

  /// Generate a cryptographically secure 32-byte token
  /// Returns the token as a hex-encoded string (64 characters)
  String generateSecureToken() {
    final bytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return _bytesToHex(bytes);
  }

  /// Generate a user-friendly pairing code (e.g., "STAR-LYRA-1234")
  /// The code is derived from a secure token to ensure uniqueness
  String generatePairingCode(String token) {
    // Use the first 4 bytes of the token to derive a larger, memorable code
    // space than a single-word code would allow.
    final tokenBytes = _hexToBytes(token);
    final firstWordIndex = tokenBytes[0] % _codeWords.length;
    final secondWordIndex = tokenBytes[1] % _codeWords.length;
    final number = ((tokenBytes[2] << 8) | tokenBytes[3]) % 10000;

    return '${_codeWords[firstWordIndex]}-${_codeWords[secondWordIndex]}-${number.toString().padLeft(4, '0')}';
  }

  // Pairing management

  /// Start a new pairing session
  /// Returns the pairing code to display to the user
  Future<String> startPairing({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    // Clean up expired sessions before creating a new one
    await _database.deleteExpiredPairingSessions();

    for (var attempt = 0; attempt < _maxPairingCreationAttempts; attempt++) {
      final sessionToken = generateSecureToken();
      final pairingCode = generatePairingCode(sessionToken);

      try {
        await _database.createPairingSession(
          pairingCode: pairingCode,
          sessionToken: sessionToken,
          expiresIn: timeout,
        );
        return pairingCode;
      } catch (_) {
        // Why: pairing-code collision retry loop. createPairingSession
        // throws when the random code already exists in the DB; we
        // regenerate and retry up to _maxPairingCreationAttempts. Only
        // the final attempt's exception is allowed to escape, so the
        // operator sees a real "could not allocate a unique code" error
        // rather than a transient collision being mis-reported.
        if (attempt == _maxPairingCreationAttempts - 1) {
          rethrow;
        }
      }
    }

    throw StateError('Failed to create a unique pairing code.');
  }

  /// Cancel an in-progress pairing session so its code can no longer complete
  /// a pairing. The operator tapped Cancel before any device used the code;
  /// deleting the session invalidates it immediately instead of leaving it
  /// live until its timeout.
  Future<void> cancelPairing(String code) async {
    await _database.deletePairingSession(code.trim().toUpperCase());
  }

  /// Verify a pairing attempt and complete the pairing
  Future<PairingResult> verifyPairing({
    required String pairingCode,
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
    String authGrantSpec = 'control',
  }) async {
    final completion = await completePairing(
      pairingCode: pairingCode,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      authGrantSpec: authGrantSpec,
    );
    return completion.result;
  }

  /// Verify a pairing attempt, persist the device, and return its session token.
  ///
  /// [tokenLifetime] sets the `expires_at` column on the persisted
  /// `paired_devices` row, enforced by [verifySessionToken] and by the
  /// headless auth-middleware sweep. `null` means no DB-side expiry; callers
  /// SHOULD always pass a finite lifetime — the headless server's
  /// `PairingService` passes its `_defaultSessionTokenLifetime` here.
  Future<PairingCompletion> completePairing({
    required String pairingCode,
    required String deviceId,
    required String deviceName,
    String deviceType = 'mobile',
    Duration? tokenLifetime,
    String authGrantSpec = 'control',
  }) async {
    final normalizedPairingCode = pairingCode.trim().toUpperCase();
    final normalizedDeviceId = deviceId.trim();
    final normalizedDeviceName = deviceName.trim();

    // Retrieve pairing session
    final session = await _database.getPairingSession(normalizedPairingCode);

    if (session == null) {
      return (result: PairingResult.invalidCode, sessionToken: null);
    }

    // Check if already used
    if (session.isUsed) {
      return (result: PairingResult.codeAlreadyUsed, sessionToken: null);
    }

    // Check if expired
    if (DateTime.now().isAfter(session.expiresAt)) {
      return (result: PairingResult.codeExpired, sessionToken: null);
    }

    // Check if device already paired
    final existingDevice = await _database.getPairedDevice(normalizedDeviceId);
    final wasAlreadyPaired = existingDevice != null && existingDevice.isActive;

    // Mark session as used
    await _database.markPairingSessionUsed(normalizedPairingCode);

    // Add or update paired device. Existing devices are re-issued the fresh
    // session token from the current pairing flow instead of disclosing any
    // previous token.
    if (existingDevice != null) {
      await _database.deletePairedDevice(normalizedDeviceId);
    }

    final expiresAt = tokenLifetime == null
        ? null
        : DateTime.now().add(tokenLifetime);

    await _database.addPairedDevice(
      deviceId: normalizedDeviceId,
      deviceName: normalizedDeviceName,
      sessionToken: session.sessionToken,
      deviceType: deviceType,
      expiresAt: expiresAt,
      authGrantSpec: authGrantSpec,
    );

    // Clean up used session
    await _database.deleteUsedPairingSessions();

    return (
      result: wasAlreadyPaired
          ? PairingResult.deviceAlreadyPaired
          : PairingResult.success,
      sessionToken: session.sessionToken,
    );
  }

  /// Verify a session token for subsequent connections
  /// Uses constant-time comparison to prevent timing attacks
  Future<TokenVerificationResult> verifySessionToken({
    required String deviceId,
    required String token,
  }) async {
    final device = await _database.getPairedDevice(deviceId);

    if (device == null) {
      return TokenVerificationResult.deviceNotFound;
    }

    if (!device.isActive) {
      return TokenVerificationResult.deviceRevoked;
    }

    // Reject expired tokens BEFORE the constant-time comparison so a network
    // attacker cannot use timing to distinguish "right token, expired" from
    // "wrong token, unexpired" — both paths short-circuit before the compare.
    final expiresAt = device.expiresAt;
    if (expiresAt != null && !DateTime.now().isBefore(expiresAt)) {
      // Notify the host so any in-memory cache evicts the entry.
      _notifyRevocation(device.sessionToken);
      return TokenVerificationResult.expired;
    }

    // Constant-time comparison to prevent timing attacks
    if (_constantTimeCompare(device.sessionToken, token)) {
      // Update last connected timestamp
      await _database.updateLastConnected(deviceId);
      return TokenVerificationResult.valid;
    }

    return TokenVerificationResult.invalid;
  }

  /// Revoke a paired device
  Future<void> revokeDevice(String deviceId) async {
    // Capture the session token BEFORE flipping `is_active`. The auth
    // middleware's in-memory `_pairedSessionTokens` map is keyed by token
    // value (it does not store device ids), so we need the raw token to
    // propagate the eviction synchronously via [setRevocationListener].
    final device = await _database.getPairedDevice(deviceId);
    await _database.revokeDevice(deviceId);
    if (device != null) {
      _notifyRevocation(device.sessionToken);
    }
  }

  /// Revoke every active paired device at once, returning how many were
  /// deauthorized.
  ///
  /// Each revoked session token is announced individually through
  /// [setRevocationListener] so the auth middleware's in-memory
  /// `_pairedSessionTokens` map (keyed by token value, not device id) evicts
  /// them all without a process restart — a bulk revoke that only wrote the
  /// database would leave every already-connected client authorized until the
  /// host was restarted.
  Future<int> revokeAllDevices() async {
    final revoked = await _database.revokeAllDevices();
    for (final device in revoked) {
      _notifyRevocation(device.sessionToken);
    }
    return revoked.length;
  }

  /// Rename a paired device without touching its session token.
  ///
  /// Purely cosmetic on purpose: the token, grant and expiry are untouched, so
  /// naming the phone in your hand never interrupts a device that is mid-run.
  /// Returns false when no such row exists.
  Future<bool> renameDevice(String deviceId, String deviceName) async {
    return await _database.renamePairedDevice(deviceId, deviceName) > 0;
  }

  /// Delete a paired device completely
  Future<void> deleteDevice(String deviceId) async {
    final device = await _database.getPairedDevice(deviceId);
    await _database.deletePairedDevice(deviceId);
    if (device != null) {
      _notifyRevocation(device.sessionToken);
    }
  }

  /// Get all active paired devices
  Future<List<PairedDevice>> getActivePairedDevices() async {
    return await _database.getActivePairedDevices();
  }

  /// Active (`is_active = true`) AND not yet expired. This is the canonical
  /// "tokens the auth middleware should accept" snapshot that the headless
  /// server hydrates `_pairedSessionTokens` from at startup.
  Future<List<PairedDevice>> getActiveUnexpiredPairedDevices() async {
    return _database.getActiveUnexpiredPairedDevices(DateTime.now());
  }

  /// Register a callback the manager invokes whenever a session token must
  /// be evicted from any in-memory caches (revoke, expiry sweep, delete).
  ///
  /// The headless server calls this at startup so revocation propagates
  /// without a process restart. Registration is process-wide because the GUI
  /// pairing screen and embedded server intentionally use separate database
  /// connections; only the hardware-owning server registers a listener.
  void setRevocationListener(SessionTokenRevocationListener? listener) {
    if (listener == null) {
      if (identical(_revocationListenerOwner, this)) {
        _revocationListenerOwner = null;
        _processRevocationListener = null;
      }
      return;
    }
    _revocationListenerOwner = this;
    _processRevocationListener = listener;
  }

  void _notifyRevocation(String sessionToken) {
    _processRevocationListener?.call(sessionToken);
  }

  /// Sweep `paired_devices`: surface tokens that the in-memory auth map must
  /// no longer honour, hard-delete expired rows, and keep revoked rows for
  /// audit. Returns the set of tokens that were affected so the caller can
  /// update its in-memory state. Also invokes the registered revocation
  /// listener for each affected token.
  ///
  /// Called periodically by `HeadlessApiServer` (every 60s by default). Also
  /// safe to call at startup so any tokens that expired while the server
  /// was offline are purged before clients can attempt to use them.
  Future<TokenSweepResult> purgeExpiredAndRevokedSessions() async {
    final now = DateTime.now();
    final rows = await _database.getExpiredOrRevokedDevices(now);
    final expired = <String>[];
    final revoked = <String>[];
    for (final row in rows) {
      final expiresAt = row.expiresAt;
      final isExpired = expiresAt != null && !now.isBefore(expiresAt);
      if (isExpired) {
        expired.add(row.sessionToken);
      } else if (!row.isActive) {
        revoked.add(row.sessionToken);
      }
      // A deauthorized phone must stop receiving cellular criticals. Delete
      // the device's push token + prefs rows regardless of expired-vs-revoked
      // (the expired `paired_devices` row is hard-deleted below; the revoked
      // one is retained for audit but its push rows are not). Idempotent.
      await _database.deletePushTokensForDevice(row.deviceId);
      await _database.deletePushPrefsForDevice(row.deviceId);
    }
    // Hard-delete expired rows so the table does not grow without bound.
    // Revoked rows are intentionally kept for audit (the operator may want
    // to see which device id last had access).
    if (expired.isNotEmpty) {
      await _database.deleteExpiredPairedDevices(now);
    }
    // Notify the host so in-memory caches drop the entries.
    for (final token in expired) {
      _notifyRevocation(token);
    }
    for (final token in revoked) {
      _notifyRevocation(token);
    }
    return TokenSweepResult(expiredTokens: expired, revokedTokens: revoked);
  }

  // Helper methods

  /// Convert bytes to hex string
  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Convert hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (int i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// Constant-time string comparison to prevent timing attacks
  /// Both strings must be hex-encoded and of the same length
  bool _constantTimeCompare(String a, String b) {
    if (a.length != b.length) {
      return false;
    }

    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }

    return result == 0;
  }

  /// Hash a token using SHA-256 (for logging/debugging without exposing the token)
  String hashToken(String token) {
    final bytes = utf8.encode(token);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
