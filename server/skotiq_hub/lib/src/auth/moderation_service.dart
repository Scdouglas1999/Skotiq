import 'package:uuid/uuid.dart';

import '../db/hub_database.dart';
import 'token_service.dart';

/// Account moderation — the operational lever that stops an abuser WITHOUT
/// deleting the account (deletion FK-cascades away the contribution /
/// attribution history a dispute needs).
///
/// A suspend stamps `accounts.suspended_at` (the kill switch
/// [TokenService.resolve] fails closed on), writes an append-only
/// `moderation_actions` row, and revokes every live token via
/// [TokenService.revokeAllForAccount] so the account is locked out instantly —
/// both the unexpired tokens it holds AND any future resolve. A reinstate clears
/// the column and records the lift. [checkAbuse] is the automatic flag: it
/// counts an account's rejected/denied activity inside a rolling
/// [defaultAbuseWindow] — and only since the most recent reinstate — and
/// auto-suspends past a threshold, so a flood of bad contributions stops itself
/// while an honest long-term account is never auto-suspended on a lifetime tally
/// and a reinstate genuinely un-sticks an account.
class ModerationService {
  ModerationService(this._db, this._tokens, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final HubDatabase _db;
  final TokenService _tokens;
  final Uuid _uuid;

  /// Number of recent rejected/denied actions that trips an auto-suspend.
  static const int defaultAbuseThreshold = 25;

  /// Rolling window the abuse tally is bounded to. Only rejects/denials NEWER
  /// than this count, so a flaky rig that accrues a handful of quality
  /// rejections across months of normal use never crosses the lifetime-cumulative
  /// threshold that used to permanently auto-suspend honest accounts.
  static const Duration defaultAbuseWindow = Duration(hours: 72);

  /// Whether [accountId] is currently suspended.
  bool isSuspended(String accountId) {
    final rows = _db.db.select(
      'SELECT suspended_at FROM accounts WHERE id = ?;',
      <Object?>[accountId],
    );
    if (rows.isEmpty) return false;
    return rows.first['suspended_at'] != null;
  }

  /// Suspend [targetAccountId]: stamp `suspended_at`, record the action, and
  /// revoke every live token. Idempotent — re-suspending an already-suspended
  /// account refreshes the reason and re-revokes. Returns whether the account
  /// exists (false → unknown account, nothing done).
  bool suspend({
    required String targetAccountId,
    String? moderatorAccountId,
    String? reason,
    bool auto = false,
  }) {
    final exists = _db.db.select(
      'SELECT 1 FROM accounts WHERE id = ?;',
      <Object?>[targetAccountId],
    );
    if (exists.isEmpty) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    _db.db.execute(
      'UPDATE accounts SET suspended_at = ?, suspended_reason = ? WHERE id = ?;',
      <Object?>[now, reason, targetAccountId],
    );
    _recordAction(
      targetAccountId: targetAccountId,
      moderatorAccountId: moderatorAccountId,
      action: 'suspend',
      reason: reason,
      auto: auto,
      at: now,
    );
    // Kill the live tokens too, not only future resolves: a long-lived appliance
    // token must stop working the instant an account is suspended.
    _tokens.revokeAllForAccount(targetAccountId);
    return true;
  }

  /// Reinstate [targetAccountId]: clear `suspended_at` and record the lift.
  /// Returns whether the account was actually suspended (false → no-op).
  bool reinstate({
    required String targetAccountId,
    String? moderatorAccountId,
    String? reason,
  }) {
    if (!isSuspended(targetAccountId)) return false;
    final now = DateTime.now().toUtc().toIso8601String();
    _db.db.execute(
      'UPDATE accounts SET suspended_at = NULL, suspended_reason = NULL '
      'WHERE id = ?;',
      <Object?>[targetAccountId],
    );
    _recordAction(
      targetAccountId: targetAccountId,
      moderatorAccountId: moderatorAccountId,
      action: 'reinstate',
      reason: reason,
      auto: false,
      at: now,
    );
    return true;
  }

  /// Count [accountId]'s recent rejected/denied activity and auto-suspend it
  /// when the count reaches [threshold]. Returns whether it suspended on this
  /// call. Called from the contribution-reject path so an account that floods
  /// the swarm with bad frames stops itself without an operator in the loop.
  ///
  /// Two bounds keep the flag honest: (1) only activity NEWER than [window] ago
  /// counts, so an honest rig that accrues a few quality rejections over months
  /// is never auto-suspended on a lifetime tally; (2) only activity NEWER than
  /// the most recent reinstate counts, so a lift truly un-sticks an account —
  /// the pre-lift rejects no longer count, so the very next rejected
  /// contribution does not immediately re-suspend it.
  ///
  /// The signal spans BOTH the durable tile-fusion `contributions` ledger AND
  /// the `audit_log` denial trail (the 401/403/422 rows the audit middleware
  /// records: forbidden probes, co-imaging contribution rejections, shared
  /// content-integrity poison rejections (a spoofed/degenerate calibration
  /// master → 422), and other non-fusion rejection paths), so abuse vectors
  /// beyond tile fusion also feed it. The two ledgers are disjoint by
  /// construction — a tile-fusion reject is
  /// a status-200 audit row, never a >= 400 one — so no event is double-counted.
  bool checkAbuse(
    String accountId, {
    int threshold = defaultAbuseThreshold,
    Duration window = defaultAbuseWindow,
  }) {
    if (isSuspended(accountId)) return false;
    final now = DateTime.now().toUtc();
    final windowStart = now.subtract(window).toIso8601String();
    // The slate is also cleared at the most recent reinstate: rejects/denials
    // logged before a lift must never re-trip the auto-suspend.
    final lastReinstate = _lastReinstateAt(accountId);
    final cutoff =
        (lastReinstate != null && lastReinstate.compareTo(windowStart) > 0)
        ? lastReinstate
        : windowStart;
    final recent = _recentRejectCount(accountId, cutoff);
    if (recent < threshold) return false;
    return suspend(
      targetAccountId: accountId,
      reason:
          'auto-suspended: $recent recent rejected/denied actions '
          '(threshold $threshold within ${window.inHours}h)',
      auto: true,
    );
  }

  /// ISO-8601 `created_at` of the most recent reinstate for [accountId], or null
  /// if it was never reinstated.
  String? _lastReinstateAt(String accountId) {
    final rows = _db.db.select(
      "SELECT created_at FROM moderation_actions "
      "WHERE target_account_id = ? AND action = 'reinstate' "
      "ORDER BY created_at DESC LIMIT 1;",
      <Object?>[accountId],
    );
    if (rows.isEmpty) return null;
    return rows.first['created_at'] as String?;
  }

  /// Count [accountId]'s rejected contributions plus denial audit rows whose
  /// timestamp is strictly after [cutoff] (an ISO-8601 string). Denial rows are
  /// scoped to authz/rejection statuses (401/403/422) so benign 400/404/409
  /// outcomes (typos, not-found, conflicts) never accrue against an honest user.
  int _recentRejectCount(String accountId, String cutoff) {
    final rejects = _db.db.select(
      "SELECT COUNT(*) AS n FROM contributions "
      "WHERE account_id = ? AND status = 'rejected' AND created_at > ?;",
      <Object?>[accountId, cutoff],
    );
    final denials = _db.db.select(
      'SELECT COUNT(*) AS n FROM audit_log '
      'WHERE account_id = ? AND at > ? AND status IN (401, 403, 422);',
      <Object?>[accountId, cutoff],
    );
    final r = (rejects.first['n'] as num?)?.toInt() ?? 0;
    final d = (denials.first['n'] as num?)?.toInt() ?? 0;
    return r + d;
  }

  /// Recent moderation actions for [accountId], newest first.
  List<Map<String, Object?>> actionsFor(String accountId, {int limit = 50}) {
    final capped = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final rows = _db.db.select(
      'SELECT id, target_account_id, moderator_account_id, action, reason, '
      'auto, created_at FROM moderation_actions WHERE target_account_id = ? '
      'ORDER BY created_at DESC LIMIT $capped;',
      <Object?>[accountId],
    );
    return rows
        .map(
          (r) => <String, Object?>{
            'id': r['id'],
            'targetAccountId': r['target_account_id'],
            'moderatorAccountId': r['moderator_account_id'],
            'action': r['action'],
            'reason': r['reason'],
            'auto': (r['auto'] as num?)?.toInt() == 1,
            'createdAt': r['created_at'],
          },
        )
        .toList(growable: false);
  }

  void _recordAction({
    required String targetAccountId,
    required String? moderatorAccountId,
    required String action,
    required String? reason,
    required bool auto,
    required String at,
  }) {
    _db.db.execute(
      'INSERT INTO moderation_actions '
      '(id, target_account_id, moderator_account_id, action, reason, auto, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?, ?);',
      <Object?>[
        _uuid.v4(),
        targetAccountId,
        moderatorAccountId,
        action,
        reason,
        auto ? 1 : 0,
        at,
      ],
    );
  }
}
