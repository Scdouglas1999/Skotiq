import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../db/hub_database.dart';
import 'password_hasher.dart';
import 'token_service.dart';

/// A hub account: identity, reputation/trust, and admin flag.
class Account {
  Account({
    required this.id,
    required this.displayName,
    required this.publicKey,
    required this.trust,
    required this.isAdmin,
    required this.residualSum,
    required this.residualN,
    required this.acceptedFrames,
    required this.rejectedFrames,
  });

  final String id;
  final String displayName;
  final String publicKey;
  final double trust;
  final bool isAdmin;

  /// Σ of reported median residual across accepted contributions — the basis
  /// for residual-weighted trust.
  final double residualSum;

  /// Count of contributions that fed [residualSum].
  final int residualN;
  final int acceptedFrames;
  final int rejectedFrames;

  /// Mean reported residual, or null if no graded contributions yet.
  double? get meanResidual => residualN > 0 ? residualSum / residualN : null;
}

/// Manages accounts: signup, login, lookup, and reputation updates. Reuses the
/// monorepo's hash-not-plaintext convention (passwords via [PasswordHasher];
/// tokens via [TokenService]).
class AccountService {
  AccountService(this._db, this._tokens, {PasswordHasher? hasher})
    : _hasher = hasher ?? PasswordHasher();

  final HubDatabase _db;
  final TokenService _tokens;
  final PasswordHasher _hasher;
  final Uuid _uuid = const Uuid();

  /// A throwaway hash, computed once at the hasher's own iteration count, that
  /// [login] verifies against when no account matches the public key. This makes
  /// the unknown-key path spend the same PBKDF2 work as the wrong-password path,
  /// closing the credential-validity timing oracle. It never matches a real
  /// account.
  late final String _decoyHash = _hasher.hash('');

  /// Default trust assigned to a brand-new contributor; `/v1/info` advertises
  /// it. Earned upward / downward by [recordGrade].
  static const double defaultTrust = 0.5;

  /// Create a new account and issue its first `contribute`-scoped token.
  /// [password] is optional: public-key-only accounts (appliance keys) are
  /// allowed, in which case login is via a long-lived token rather than a
  /// password. Throws [AccountConflict] if the public key is already enrolled.
  ({Account account, String bearerToken}) signup({
    required String publicKey,
    required String displayName,
    String? password,
    bool isAdmin = false,
  }) {
    final normalizedKey = publicKey.trim();
    final normalizedName = displayName.trim();
    if (normalizedKey.isEmpty) {
      throw ArgumentError.value(publicKey, 'publicKey', 'must not be empty');
    }
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be empty',
      );
    }
    final existing = _db.db.select(
      'SELECT id FROM accounts WHERE public_key = ?;',
      <Object?>[normalizedKey],
    );
    if (existing.isNotEmpty) {
      throw AccountConflict('public key already enrolled');
    }
    final id = _uuid.v4();
    final passwordHash = password == null ? null : _hasher.hash(password);
    _db.db.execute(
      'INSERT INTO accounts (id, display_name, public_key, password_hash, '
      'trust, is_admin, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        id,
        normalizedName,
        normalizedKey,
        passwordHash,
        defaultTrust,
        isAdmin ? 1 : 0,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    final account = getById(id)!;
    final token = _tokens.issue(
      accountId: id,
      scope: isAdmin ? HubScope.admin : HubScope.contribute,
    );
    return (account: account, bearerToken: token);
  }

  /// Authenticate by public key + password and issue a fresh token. Returns
  /// null on unknown key or wrong password (the caller maps both to 401 without
  /// disclosing which).
  ({Account account, String bearerToken})? login({
    required String publicKey,
    required String password,
  }) {
    final rows = _db.db.select(
      'SELECT id, password_hash, is_admin, suspended_at FROM accounts '
      'WHERE public_key = ?;',
      <Object?>[publicKey.trim()],
    );
    if (rows.isEmpty) {
      // Spend the same PBKDF2 work as a wrong-password attempt so the unknown-
      // key path is not faster, then fail closed.
      _hasher.verify(password, _decoyHash);
      return null;
    }
    final row = rows.first;
    final stored = row['password_hash'] as String?;
    if (stored == null || !_hasher.verify(password, stored)) return null;
    // A suspended account must not receive a fresh token: the resolve-time
    // kill switch already fails its tokens closed, but a 200 here writes a
    // false "successful login" audit row and grows the token table for an
    // account moderation has locked out (hub-sweep finding H1). The password
    // was still verified above so this path costs the same PBKDF2 work.
    if (row['suspended_at'] != null) return null;
    final id = row['id'] as String;
    final isAdmin = (row['is_admin'] as int) != 0;
    final token = _tokens.issue(
      accountId: id,
      scope: isAdmin ? HubScope.admin : HubScope.contribute,
    );
    return (account: getById(id)!, bearerToken: token);
  }

  Account? getById(String id) {
    final rows = _db.db.select(
      'SELECT * FROM accounts WHERE id = ?;',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  int get count {
    final rows = _db.db.select('SELECT COUNT(*) AS n FROM accounts;');
    return rows.first['n'] as int;
  }

  /// Fold one graded contribution's outcome into [accountId]'s reputation:
  /// [medianResidual] (lower is better, may be null if ungraded), and the
  /// accepted/rejected frame tallies. [trustFor] then derives the live trust.
  void recordGrade({
    required String accountId,
    double? medianResidual,
    int acceptedFrames = 0,
    int rejectedFrames = 0,
  }) {
    final account = getById(accountId);
    if (account == null) return;
    final newResidualSum = account.residualSum + (medianResidual ?? 0.0);
    final newResidualN = account.residualN + (medianResidual == null ? 0 : 1);
    final newAccepted = account.acceptedFrames + acceptedFrames;
    final newRejected = account.rejectedFrames + rejectedFrames;
    _db.db.execute(
      'UPDATE accounts SET residual_sum = ?, residual_n = ?, '
      'accepted_frames = ?, rejected_frames = ?, trust = ? WHERE id = ?;',
      <Object?>[
        newResidualSum,
        newResidualN,
        newAccepted,
        newRejected,
        _computeTrust(
          residualSum: newResidualSum,
          residualN: newResidualN,
          acceptedFrames: newAccepted,
          rejectedFrames: newRejected,
        ),
        accountId,
      ],
    );
  }

  /// Directly set an account's trust. Used by an operator (admin tooling) to
  /// pin a known-good observatory's weight, and by tests for deterministic
  /// fusion assertions. Clamped to [0.05, 1.0] to match the model's range.
  void setTrust(String accountId, double trust) {
    final clamped = trust < 0.05
        ? 0.05
        : trust > 1.0
        ? 1.0
        : trust;
    _db.db.execute('UPDATE accounts SET trust = ? WHERE id = ?;', <Object?>[
      clamped,
      accountId,
    ]);
  }

  Account _fromRow(Row row) {
    return Account(
      id: row['id'] as String,
      displayName: row['display_name'] as String,
      publicKey: row['public_key'] as String,
      trust: (row['trust'] as num).toDouble(),
      isAdmin: (row['is_admin'] as int) != 0,
      residualSum: (row['residual_sum'] as num).toDouble(),
      residualN: row['residual_n'] as int,
      acceptedFrames: row['accepted_frames'] as int,
      rejectedFrames: row['rejected_frames'] as int,
    );
  }

  /// Derive trust in [0, 1] from reputation history. Starts at [defaultTrust]
  /// with no history; rises as a contributor lands clean, low-residual frames
  /// and falls as rejections accrue. See `trust_model.dart` for the standalone
  /// formula used by the merge path.
  static double _computeTrust({
    required double residualSum,
    required int residualN,
    required int acceptedFrames,
    required int rejectedFrames,
  }) {
    return computeTrust(
      meanResidual: residualN > 0 ? residualSum / residualN : null,
      acceptedFrames: acceptedFrames,
      rejectedFrames: rejectedFrames,
    );
  }
}

/// Thrown when a signup collides with an already-enrolled public key. Mapped to
/// HTTP 409 by the route layer.
class AccountConflict implements Exception {
  AccountConflict(this.message);
  final String message;
  @override
  String toString() => 'AccountConflict: $message';
}

/// Trust model — a single, testable function so the merge path and the account
/// service agree. Trust ∈ [0.05, 1.0].
///
/// Components:
///  - acceptance ratio: accepted / (accepted + rejected), Laplace-smoothed so a
///    contributor with no history sits at [AccountService.defaultTrust].
///  - residual penalty: clean frames (low mean residual) keep full trust;
///    high-residual contributors are down-weighted smoothly.
/// One bad contributor cannot poison a shared stack: low trust shrinks their
/// weighted sums in the merge, and the merge additionally applies robust
/// per-tile sigma rejection (see `tile_quality.dart`).
double computeTrust({
  required double? meanResidual,
  required int acceptedFrames,
  required int rejectedFrames,
}) {
  const prior = AccountService.defaultTrust;
  const priorWeight = 8.0; // frames of "benefit of the doubt"
  final total = acceptedFrames + rejectedFrames;
  // Laplace-smoothed acceptance ratio toward the prior.
  final acceptance =
      (acceptedFrames + prior * priorWeight) / (total + priorWeight);

  // Residual penalty: 1.0 at residual 0, decaying with a soft scale. A median
  // residual (e.g. arcsec RMS or normalized flux residual) of ~1.0 still keeps
  // ~0.5 weight; only egregiously bad astrometry collapses the weight.
  final residual = meanResidual ?? 0.0;
  final residualFactor = 1.0 / (1.0 + (residual * residual));

  final trust = acceptance * residualFactor;
  if (trust < 0.05) return 0.05;
  if (trust > 1.0) return 1.0;
  return trust;
}
