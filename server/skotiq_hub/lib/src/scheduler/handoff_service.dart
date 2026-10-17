import 'dart:math';
import 'dart:typed_data';

import '../db/hub_database.dart';

/// Single-holder "follow-the-night" handoff per shared target: one contributor
/// holds the active claim (so the swarm does not pile redundant subs on the same
/// object at the same instant), then releases it as the target sets at their
/// site for the next contributor further west to pick up.
class HandoffService {
  HandoffService(this._db) : _random = Random.secure();

  final HubDatabase _db;
  final Random _random;

  /// How long a claim stays valid without renewal. A holder that goes dark
  /// (clouds, crash) frees the target for the next contributor automatically.
  static const Duration claimTtl = Duration(minutes: 30);

  /// Current claim state for [targetId], expiring stale claims lazily.
  HandoffState state(int targetId) {
    final raw = _stateRaw('handoff_claims', 'target_id', targetId);
    return HandoffState(
      targetId: targetId,
      holder: raw.holder,
      expiresAt: raw.expiresAt,
    );
  }

  /// Claim [targetId] for [accountId]. Succeeds if free or already held by the
  /// same account (renewal). Returns null if another account currently holds it.
  HandoffClaim? claim({required int targetId, required String accountId}) {
    final claimed = _claimRaw(
      'handoff_claims',
      'target_id',
      targetId,
      accountId,
    );
    if (claimed == null) return null;
    return HandoffClaim(
      targetId: targetId,
      claimToken: claimed.token,
      expiresAt: claimed.expiresAt,
    );
  }

  /// Release [targetId] if held by [accountId]. Returns true if a claim was
  /// released, false if the account did not hold it.
  bool release({required int targetId, required String accountId}) =>
      _releaseRaw('handoff_claims', 'target_id', targetId, accountId);

  // --- Session-scoped baton (co-imaging) -------------------------------------
  //
  // A LIVE co-imaging session's "who is imaging now" baton is a property of the
  // SESSION, not of the bare shared target: two distinct sessions that cone-merge
  // onto the same `shared_targets` row must NOT collapse onto one baton (that let
  // a stranger seize a victim session's hand-off / corrupt its attribution). The
  // single-holder claim core below is reused verbatim, keyed on the session id in
  // the dedicated `coimaging_batons` table, so each session has an isolated baton.

  /// Current baton holder for co-imaging [sessionId] (holder/expiry only).
  ({String? holder, DateTime? expiresAt}) sessionState(String sessionId) =>
      _stateRaw('coimaging_batons', 'session_id', sessionId);

  /// Claim the baton for co-imaging [sessionId]. Null when another account holds
  /// it. Renews when the same account already holds it.
  ({String token, DateTime expiresAt})? claimSession({
    required String sessionId,
    required String accountId,
  }) => _claimRaw('coimaging_batons', 'session_id', sessionId, accountId);

  /// Release the baton for co-imaging [sessionId] if held by [accountId].
  bool releaseSession({required String sessionId, required String accountId}) =>
      _releaseRaw('coimaging_batons', 'session_id', sessionId, accountId);

  // --- Generic single-holder claim core --------------------------------------
  // [table]/[col] are internal constants (never user input), so interpolating
  // them is safe; [key] is always bound as a parameter.

  ({String? holder, DateTime? expiresAt}) _stateRaw(
    String table,
    String col,
    Object key,
  ) {
    _expireStaleRaw(table, col, key);
    final rows = _db.db.select(
      'SELECT account_id, expires_at FROM $table WHERE $col = ?;',
      <Object?>[key],
    );
    if (rows.isEmpty) return (holder: null, expiresAt: null);
    return (
      holder: rows.first['account_id'] as String,
      expiresAt: DateTime.tryParse(rows.first['expires_at'] as String),
    );
  }

  ({String token, DateTime expiresAt})? _claimRaw(
    String table,
    String col,
    Object key,
    String accountId,
  ) {
    _expireStaleRaw(table, col, key);
    final current = _stateRaw(table, col, key);
    if (current.holder != null && current.holder != accountId) {
      return null;
    }
    final token = _generateToken();
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(claimTtl);
    _db.db.execute(
      'INSERT INTO $table ($col, account_id, claim_token, '
      'claimed_at, expires_at) VALUES (?, ?, ?, ?, ?) '
      'ON CONFLICT($col) DO UPDATE SET '
      'account_id = excluded.account_id, '
      'claim_token = excluded.claim_token, '
      'claimed_at = excluded.claimed_at, '
      'expires_at = excluded.expires_at;',
      <Object?>[
        key,
        accountId,
        token,
        now.toIso8601String(),
        expiresAt.toIso8601String(),
      ],
    );
    return (token: token, expiresAt: expiresAt);
  }

  bool _releaseRaw(String table, String col, Object key, String accountId) {
    final current = _stateRaw(table, col, key);
    if (current.holder != accountId) return false;
    _db.db.execute('DELETE FROM $table WHERE $col = ?;', <Object?>[key]);
    return true;
  }

  void _expireStaleRaw(String table, String col, Object key) {
    final rows = _db.db.select(
      'SELECT expires_at FROM $table WHERE $col = ?;',
      <Object?>[key],
    );
    if (rows.isEmpty) return;
    final exp = DateTime.tryParse(rows.first['expires_at'] as String);
    if (exp != null && !DateTime.now().toUtc().isBefore(exp)) {
      _db.db.execute('DELETE FROM $table WHERE $col = ?;', <Object?>[key]);
    }
  }

  String _generateToken() {
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// The current handoff state of a target.
class HandoffState {
  HandoffState({
    required this.targetId,
    required this.holder,
    required this.expiresAt,
  });

  final int targetId;
  final String? holder;
  final DateTime? expiresAt;
}

/// A successful claim handed to a contributor.
class HandoffClaim {
  HandoffClaim({
    required this.targetId,
    required this.claimToken,
    required this.expiresAt,
  });

  final int targetId;
  final String claimToken;
  final DateTime expiresAt;
}
