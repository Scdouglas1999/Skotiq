import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairingDatabase, PairingResult, TokenManager;

/// Outcome of a verify attempt against the [PairingService].
enum PairingVerifyOutcome { success, invalidCode, codeExpired, codeAlreadyUsed }

class PairingStartResult {
  /// User-facing pairing code (e.g. `STAR-LYRA-1234`) shown on the desktop.
  final String code;
  final DateTime expiresAt;

  PairingStartResult({required this.code, required this.expiresAt});
}

class PairingVerifyResult {
  final PairingVerifyOutcome outcome;
  final String? sessionToken;
  final DateTime? expiresAt;

  PairingVerifyResult({
    required this.outcome,
    this.sessionToken,
    this.expiresAt,
  });
}

/// Pairing service for the headless REST API and dashboard.
///
/// Delegates storage and code generation to [TokenManager] so GUI pairing
/// (`PairingScreen`) and HTTP pairing (`/api/pairing/*`) share one Drift DB.
class PairingService {
  static const Duration _defaultPairingTimeout = Duration(minutes: 5);
  static const Duration _defaultSessionTokenLifetime = Duration(days: 365);

  final TokenManager _tokenManager;
  final PairingDatabase _database;
  final DateTime Function() _now;

  factory PairingService({
    PairingDatabase? database,
    TokenManager? tokenManager,
    DateTime Function()? now,
  }) {
    final db = database ?? PairingDatabase();
    return PairingService._(
      database: db,
      tokenManager: tokenManager ?? TokenManager(db),
      now: now ?? DateTime.now,
    );
  }

  PairingService._({
    required PairingDatabase database,
    required TokenManager tokenManager,
    required DateTime Function() now,
  }) : _database = database,
       _tokenManager = tokenManager,
       _now = now;

  PairingDatabase get database => _database;

  /// Begins a pairing session. Returns the code to display on the desktop.
  Future<PairingStartResult> startPairing() async {
    final code = await _tokenManager.startPairing(
      timeout: _defaultPairingTimeout,
    );
    final expiresAt = _now().add(_defaultPairingTimeout);
    return PairingStartResult(code: code, expiresAt: expiresAt);
  }

  /// Validates a code and persists the paired device record.
  Future<PairingVerifyResult> verifyPairing({
    required String code,
    required String deviceId,
    required String deviceName,
    String deviceType = 'browser',
    String authGrantSpec = 'control',
  }) async {
    final completion = await _tokenManager.completePairing(
      pairingCode: code,
      deviceId: deviceId,
      deviceName: deviceName,
      deviceType: deviceType,
      // Persist absolute expiry so the auth middleware can enforce the
      // `expiresAt` returned to the client.
      tokenLifetime: _defaultSessionTokenLifetime,
      authGrantSpec: authGrantSpec,
    );

    final outcome = switch (completion.result) {
      PairingResult.success => PairingVerifyOutcome.success,
      PairingResult.deviceAlreadyPaired => PairingVerifyOutcome.success,
      PairingResult.invalidCode => PairingVerifyOutcome.invalidCode,
      PairingResult.codeExpired => PairingVerifyOutcome.codeExpired,
      PairingResult.codeAlreadyUsed => PairingVerifyOutcome.codeAlreadyUsed,
    };

    if (outcome != PairingVerifyOutcome.success) {
      return PairingVerifyResult(outcome: outcome);
    }

    return PairingVerifyResult(
      outcome: PairingVerifyOutcome.success,
      sessionToken: completion.sessionToken,
      expiresAt: _now().add(_defaultSessionTokenLifetime),
    );
  }

  Duration get codeLifetime => _defaultPairingTimeout;

  /// Lifetime of session tokens minted by [verifyPairing]. Exposed so the
  /// headless server's sweep can log the configured horizon and tests can
  /// assert that pairing rows are written with the right `expires_at`.
  Duration get sessionTokenLifetime => _defaultSessionTokenLifetime;

  /// Underlying [TokenManager] — exposed so the headless server can register
  /// its in-memory revocation listener and trigger periodic sweeps without
  /// reaching through the database directly.
  TokenManager get tokenManager => _tokenManager;

  Future<void> close() async {
    await _database.close();
  }
}
