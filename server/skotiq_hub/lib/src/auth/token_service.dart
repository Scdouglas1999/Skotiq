import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../db/hub_database.dart';

/// Access scopes a bearer token may carry: clients `read` shared tiles,
/// imagers `contribute`, operators `admin`. `admin` implies the lower scopes.
enum HubScope {
  read,
  contribute,
  admin;

  /// Stable wire name (the value persisted in `tokens.scope` for a plain grant).
  String get wireName => name;

  static HubScope? parse(String raw) {
    switch (raw) {
      case 'read':
        return HubScope.read;
      case 'contribute':
        return HubScope.contribute;
      case 'admin':
        return HubScope.admin;
    }
    return null;
  }

  /// Whether a token with this scope satisfies a requirement for [required].
  bool satisfies(HubScope required) => index >= required.index;
}

/// Fine-grained collaborative actions a scoped token may permit beyond the
/// coarse [HubScope] — the "contribute to this mosaic, not delete it" verbs the
/// Collaborative Sky needs. The wire name is the stable string
/// embedded in a scoped token's JSON; it is kept in lock-step with the client
/// `CollaborativeAction` in `skotiq_core` so a grant minted on one side is
/// understood by the other.
enum CollabAction {
  calibrationPublish('calibration.publish', HubScope.contribute),
  calibrationDownload('calibration.download', HubScope.read),
  mosaicPublish('mosaic.publish', HubScope.contribute),
  mosaicClaim('mosaic.claim', HubScope.contribute),
  mosaicUpload('mosaic.upload', HubScope.contribute),
  mosaicDownload('mosaic.download', HubScope.read),
  mosaicAssemble('mosaic.assemble', HubScope.admin),
  coimagingJoin('coimaging.join', HubScope.contribute),
  coimagingContribute('coimaging.contribute', HubScope.contribute),
  tileContribute('tile.contribute', HubScope.contribute),
  targetEnsure('target.ensure', HubScope.contribute),
  handoffManage('handoff.manage', HubScope.contribute),
  retract('retract', HubScope.contribute),
  attributionRead('attribution.read', HubScope.read),
  tokenMint('token.mint', HubScope.read),
  moderate('moderate', HubScope.admin),
  // Read-class verbs governing the browse/detail gates. Declaring them on
  // the read handlers lets a resource-bound grant ("contribute to mosaic 42")
  // read ITS OWN resource while being confined OUT of every other resource and
  // the global lists — closing the action-less read-gate scope leak. Hub-only,
  // like the other gate-only verbs above (tileContribute/targetEnsure/…).
  tileRead('tile.read', HubScope.read),
  targetRead('target.read', HubScope.read),
  mosaicRead('mosaic.read', HubScope.read),
  coimagingRead('coimaging.read', HubScope.read);

  const CollabAction(this.wireName, this.minimumScope);

  final String wireName;

  /// The minimum base [HubScope] this action implies — a grant whose base scope
  /// cannot satisfy this never permits the action, even if it lists it.
  final HubScope minimumScope;

  static CollabAction? fromWire(String? raw) {
    if (raw == null) return null;
    for (final a in CollabAction.values) {
      if (a.wireName == raw) return a;
    }
    return null;
  }
}

/// A scoped permission grant persisted in a token's `scope` column: a base
/// [scope], optionally narrowed to a single [deviceId] (per-device scope) and/or
/// an explicit [actions] allow-list (per-action scope). This is the hub mirror
/// of the client `CollaborativePermission`.
///
/// Backward compatibility: a plain whole-role any-device grant serializes to the
/// bare role name (`read`/`contribute`/`admin`) — the legacy wire form every
/// pre-6.0 token already stores — so existing tokens resolve unchanged. Anything
/// narrowed serializes to a JSON object.
class ScopedGrant {
  const ScopedGrant({
    required this.scope,
    this.deviceId,
    this.actions,
    this.resourceType,
    this.resourceId,
  });

  /// A plain whole-role any-device grant (the legacy token shape).
  const ScopedGrant.role(HubScope scope) : this(scope: scope);

  final HubScope scope;

  /// When non-null, the grant is bound to this single device id.
  final String? deviceId;

  /// When non-null, the explicit allow-list narrowing the role's defaults.
  final Set<CollabAction>? actions;

  /// When non-null, the grant is bound to a single RESOURCE — the `(type, id)`
  /// of the collaborative artifact it may act on (e.g. `('mosaic', '42')`).
  /// This per-resource scoping is load-bearing: a `mosaic.upload` grant
  /// bound to mosaic 42 permits nothing on mosaic 99. A grant with a
  /// [resourceType] but no [resourceId] (or vice-versa) is malformed and binds
  /// nothing; both must be present for a binding to take effect.
  final String? resourceType;
  final String? resourceId;

  /// Whether this grant carries an effective resource binding (both fields set).
  bool get isResourceBound =>
      resourceType != null &&
      resourceType!.isNotEmpty &&
      resourceId != null &&
      resourceId!.isNotEmpty;

  /// Whether this grant permits [action], optionally from device [fromDevice]
  /// and on the resource identified by [onResourceType]/[onResourceId].
  ///
  /// A resource-bound grant DENIES any action whose target resource does not
  /// match the bound `(type, id)` — including an action carrying no resource
  /// context at all (a global verb cannot be performed by a token narrowed to
  /// one resource). An unbound grant ignores the resource parameters, so legacy
  /// and whole-role tokens are unaffected.
  bool permits(
    CollabAction action, {
    String? fromDevice,
    String? onResourceType,
    String? onResourceId,
  }) {
    if (!scope.satisfies(action.minimumScope)) return false;
    if (deviceId != null && deviceId != fromDevice) return false;
    if (actions != null && !actions!.contains(action)) return false;
    if (isResourceBound) {
      if (onResourceType != resourceType || onResourceId != resourceId) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'role': scope.wireName,
    if (deviceId != null) 'deviceId': deviceId,
    if (actions != null)
      'actions': actions!.map((a) => a.wireName).toList(growable: false),
    if (resourceType != null) 'resourceType': resourceType,
    if (resourceId != null) 'resourceId': resourceId,
  };

  /// Serialize to the string stored in `tokens.scope` — bare role name when
  /// plain, JSON when narrowed.
  String toScopeString() {
    if (deviceId == null &&
        actions == null &&
        resourceType == null &&
        resourceId == null) {
      return scope.wireName;
    }
    return jsonEncode(toJson());
  }

  /// Parse a `tokens.scope` value — either a bare legacy role name or a JSON
  /// scoped grant. Returns null when the base role is unrecognized (so the
  /// resolver fails closed exactly like the legacy `HubScope.parse` path).
  static ScopedGrant? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          final base = HubScope.parse(decoded['role'] as String? ?? '');
          if (base == null) return null;
          Set<CollabAction>? actions;
          final rawActions = decoded['actions'];
          if (rawActions is List) {
            actions = rawActions
                .map((e) => CollabAction.fromWire(e as String?))
                .whereType<CollabAction>()
                .toSet();
          }
          return ScopedGrant(
            scope: base,
            deviceId: decoded['deviceId'] as String?,
            actions: actions,
            resourceType: decoded['resourceType'] as String?,
            resourceId: decoded['resourceId'] as String?,
          );
        }
      } on FormatException {
        return null;
      } catch (_) {
        // Token resolution must NEVER throw on a corrupt/type-confused scope
        // value (a non-string role / deviceId / action would otherwise raise a
        // _TypeError out of `as` casts). Any cast/decode failure fails closed by
        // DENYING the whole token — returning null exactly like an unrecognized
        // role — rather than silently coercing a malformed field (which for a
        // dropped deviceId would widen a device-bound grant to any-device).
        return null;
      }
      return null;
    }
    final base = HubScope.parse(trimmed);
    return base == null ? null : ScopedGrant.role(base);
  }
}

/// An authenticated principal resolved from a bearer token.
class AuthIdentity {
  AuthIdentity({
    required this.accountId,
    required this.grant,
    required this.tokenHash,
  });

  final String accountId;

  /// The full scoped grant the token carries (base scope + optional per-device /
  /// per-action narrowing).
  final ScopedGrant grant;

  /// The coarse base scope — retained as a first-class field so the existing
  /// `_authorize`/`satisfies` call sites keep working unchanged.
  HubScope get scope => grant.scope;

  /// Whether this identity may perform [action] (optionally from [fromDevice]
  /// and on the resource [onResourceType]/[onResourceId]). The fine-grained
  /// gate the Collaborative Sky handlers call.
  bool permits(
    CollabAction action, {
    String? fromDevice,
    String? onResourceType,
    String? onResourceId,
  }) => grant.permits(
    action,
    fromDevice: fromDevice,
    onResourceType: onResourceType,
    onResourceId: onResourceId,
  );

  /// SHA-256 of the raw token — the only form ever stored or put in a request
  /// context, so a diagnostic dump of the context cannot leak the secret.
  final String tokenHash;
}

/// Overwrite the SELF-REPORTED identity fields in a client-supplied
/// `provenance_json` blob with the AUTHENTICATED principal before it is stored,
/// returning the corrected JSON string.
///
/// This is the calibration/mosaic publish trust boundary, the analogue of
/// `sanitizeContributionProvenance` for the fused-tile path: the `accountId`,
/// `displayName`, and `rigId` identity fields a `Provenance` carries are
/// producer-controlled and can name a different account, so an uploader could
/// otherwise forge "who shot this" credit. We key access control off the real
/// `account_id` column; this overwrites the embedded `accountId` so it agrees
/// with the authenticated principal and any attribution UI reading the JSON
/// cannot be spoofed. `displayName` is the human-readable credit string the
/// attribution UI renders and has no client-trustworthy source: it is set ONLY
/// from the server-resolved [authoritativeDisplayName], and when none is
/// supplied the self-reported value is STRIPPED (never passed through) so an
/// uploader cannot persist `displayName:'Famous Astrophotographer'`. The `rigId`
/// hint likewise has no authoritative column to validate against, so it too is
/// STRIPPED rather than trusted. Non-identity provenance (camera, frame count,
/// dark current, …) is preserved untouched. A null/blank/malformed blob yields a
/// minimal object carrying just the authenticated identity.
String stampAuthoritativeProvenanceIdentity(
  String? provenanceJson, {
  required String accountId,
  String? authoritativeDisplayName,
}) {
  Map<String, Object?> prov;
  if (provenanceJson == null || provenanceJson.trim().isEmpty) {
    prov = <String, Object?>{};
  } else {
    try {
      final decoded = jsonDecode(provenanceJson);
      prov = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
    } on FormatException {
      prov = <String, Object?>{};
    } catch (_) {
      // A type-confused blob (e.g. a non-Map shape that slips past the `is Map`
      // guard during conversion) must fail closed to a bare authenticated
      // identity, never propagate out of the trust boundary.
      prov = <String, Object?>{};
    }
  }
  prov['accountId'] = accountId;
  // `displayName` is the credit string the attribution UI renders; the client
  // value is never trusted. Set it only from the server-authoritative name, and
  // otherwise DROP the self-reported one rather than passing it through (which
  // would let an uploader spoof someone else's name).
  if (authoritativeDisplayName != null) {
    prov['displayName'] = authoritativeDisplayName;
  } else {
    prov.remove('displayName');
  }
  // `rigId` is a self-reported identity hint with no server-verifiable column to
  // join against, so a forged value could spoof any rig-attribution surface.
  // Drop it rather than pass it through.
  prov.remove('rigId');
  return jsonEncode(prov);
}

/// Issues and resolves bearer tokens. The hub stores only the SHA-256 of each
/// raw token (never the token itself), and compares hashes — the same
/// hash-not-plaintext discipline `TokenManager`/`server_identity` use.
class TokenService {
  TokenService(this._db) : _random = Random.secure();

  final HubDatabase _db;
  final Random _random;

  /// Generate a cryptographically secure 32-byte token, hex-encoded (64 chars),
  /// persist its hash for [accountId] with [scope], and return the RAW token to
  /// hand to the caller exactly once.
  String issue({
    required String accountId,
    required HubScope scope,
    Duration? lifetime,
  }) {
    return issueScoped(
      accountId: accountId,
      grant: ScopedGrant.role(scope),
      lifetime: lifetime,
    );
  }

  /// Issue a token carrying a fine-grained [grant] (per-device / per-action
  /// narrowing). A plain whole-role grant persists exactly as the legacy
  /// [issue] would (the bare role name), so the two paths interoperate.
  String issueScoped({
    required String accountId,
    required ScopedGrant grant,
    Duration? lifetime,
  }) {
    final raw = _generateRawToken();
    final hash = hashToken(raw);
    final now = DateTime.now().toUtc();
    _db.db.execute(
      'INSERT INTO tokens (token_hash, account_id, scope, created_at, '
      'expires_at) VALUES (?, ?, ?, ?, ?);',
      <Object?>[
        hash,
        accountId,
        grant.toScopeString(),
        now.toIso8601String(),
        lifetime == null ? null : now.add(lifetime).toIso8601String(),
      ],
    );
    return raw;
  }

  /// Resolve a raw bearer token to its [AuthIdentity], or null if unknown,
  /// expired, pointing at a deleted account, or whose account is SUSPENDED.
  ///
  /// The join on `accounts.suspended_at` is the moderation kill switch: a
  /// suspended account's still-unexpired tokens all fail closed here, so a
  /// compromised/abusive account is stopped instantly without waiting for token
  /// expiry. `revokeAllForAccount` additionally drops the rows on suspend; this
  /// check is the belt-and-braces that holds even for a token minted in the
  /// race window before the revoke ran.
  AuthIdentity? resolve(String rawToken) {
    final hash = hashToken(rawToken);
    final rows = _db.db.select(
      'SELECT t.account_id AS account_id, t.scope AS scope, '
      't.expires_at AS expires_at, a.suspended_at AS suspended_at '
      'FROM tokens t JOIN accounts a ON a.id = t.account_id '
      'WHERE t.token_hash = ?;',
      <Object?>[hash],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    // Fail closed on a suspended account — every token it holds is dead.
    if (row['suspended_at'] != null) return null;
    final expiresAt = row['expires_at'] as String?;
    if (expiresAt != null) {
      final exp = DateTime.tryParse(expiresAt);
      if (exp != null && !DateTime.now().toUtc().isBefore(exp)) {
        // Expired: purge and deny.
        _db.db.execute('DELETE FROM tokens WHERE token_hash = ?;', <Object?>[
          hash,
        ]);
        return null;
      }
    }
    final grant = ScopedGrant.tryParse(row['scope'] as String);
    if (grant == null) return null;
    return AuthIdentity(
      accountId: row['account_id'] as String,
      grant: grant,
      tokenHash: hash,
    );
  }

  /// Revoke every token for [accountId] (used on account suspension).
  void revokeAllForAccount(String accountId) {
    _db.db.execute('DELETE FROM tokens WHERE account_id = ?;', <Object?>[
      accountId,
    ]);
  }

  /// Revoke a single token by its SHA-256 [tokenHash] (self-revoke / logout).
  /// Returns whether a row was removed.
  bool revokeTokenHash(String tokenHash) {
    _db.db.execute('DELETE FROM tokens WHERE token_hash = ?;', <Object?>[
      tokenHash,
    ]);
    return _db.db.updatedRows > 0;
  }

  String _generateRawToken() {
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// SHA-256 hex of a raw token. Public so the audit layer can log a token's
  /// stable identity without the secret.
  static String hashToken(String rawToken) {
    return sha256.convert(utf8.encode(rawToken)).toString();
  }
}
