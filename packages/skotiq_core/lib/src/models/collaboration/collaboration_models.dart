// Shared model types for Collaborative Sky (6.0).
//
// These are the cross-workstream primitives every later collaborative feature
// (shared calibration libraries, distributed mosaics, live co-imaging) builds
// on: the PROVENANCE of a shared artifact, the CONSENT/LICENSE under which it
// may be reused, and a SCOPED-ROLE/PERMISSION model that extends the hub's
// coarse token scopes (read / contribute / admin) with per-device and
// per-action grants.
//
// They are plain, dependency-free Dart with tolerant `fromJson` parsing,
// matching the wire-model convention in `models/calibration/`. The hub
// (`server/skotiq_hub`) is a separate package and cannot import these, so
// it mirrors the SAME wire shapes and the SAME role/action string names in its
// own `auth/token_service.dart`; the JSON written here round-trips through the
// hub's `provenance_json` / `license` / scoped-token columns unchanged. Keep
// the string constants here in lock-step with the hub enum names.

import 'dart:convert';

/// Who and what produced a shared artifact (a calibration master, a mosaic
/// panel master, a co-imaging contribution), captured so a downloader can trust
/// what they pull and so every finished collaborative artifact can credit its
/// contributors.
///
/// All fields are nullable: provenance is best-effort and forward-compatible.
/// The calibration-specific fields ([frameCount], [darkCurrent], [sensorWidth],
/// [sensorHeight]) are what the calibration quality gate surfaces; the identity
/// fields ([accountId], [displayName], [rigId]) drive attribution everywhere.
///
/// SECURITY — the identity fields are SELF-REPORTED and NOT authenticated. They
/// are producer-controlled and a malicious/buggy uploader can name a different
/// account. They are untrusted hints only. The hub stamps [accountId] (and
/// [displayName]) from the authenticated principal on publish (see the hub's
/// `stampAuthoritativeProvenanceIdentity`), and any "who shot this" / credit UI
/// MUST key off the authoritative `account_id` row, never these JSON fields.
class Provenance {
  const Provenance({
    this.accountId,
    this.displayName,
    this.rigId,
    this.cameraModel,
    this.instrument,
    this.software,
    this.frameCount,
    this.darkCurrent,
    this.sensorWidth,
    this.sensorHeight,
    this.capturedAt,
    this.note,
  });

  /// Hub account id of the contributor (stable identity).
  final String? accountId;

  /// Human-readable contributor name for attribution UI.
  final String? displayName;

  /// Originating rig / device id (a single account may run several rigs).
  final String? rigId;

  /// Sensor / camera model string (e.g. `ZWO ASI2600MM Pro`).
  final String? cameraModel;

  /// Free-form optical-train / instrument descriptor (for flats this is the
  /// optics-specific identity that gates cross-train reuse).
  final String? instrument;

  /// Producing software + version (e.g. `Skotiq 6.0.0`).
  final String? software;

  /// Number of raw frames combined into the master / contribution.
  final int? frameCount;

  /// Measured dark-current statistic (e- / px / s) for a shared dark — the
  /// trust signal surfaced before download.
  final double? darkCurrent;

  /// Sensor dimensions in pixels (used by the calibration quality gate to
  /// refuse masters whose geometry does not match the puller's sensor).
  final int? sensorWidth;
  final int? sensorHeight;

  /// When the underlying frames were captured.
  final DateTime? capturedAt;

  /// Free-form note the producer chose to attach.
  final String? note;

  Provenance copyWith({
    String? accountId,
    String? displayName,
    String? rigId,
    String? cameraModel,
    String? instrument,
    String? software,
    int? frameCount,
    double? darkCurrent,
    int? sensorWidth,
    int? sensorHeight,
    DateTime? capturedAt,
    String? note,
  }) {
    return Provenance(
      accountId: accountId ?? this.accountId,
      displayName: displayName ?? this.displayName,
      rigId: rigId ?? this.rigId,
      cameraModel: cameraModel ?? this.cameraModel,
      instrument: instrument ?? this.instrument,
      software: software ?? this.software,
      frameCount: frameCount ?? this.frameCount,
      darkCurrent: darkCurrent ?? this.darkCurrent,
      sensorWidth: sensorWidth ?? this.sensorWidth,
      sensorHeight: sensorHeight ?? this.sensorHeight,
      capturedAt: capturedAt ?? this.capturedAt,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      if (accountId != null) 'accountId': accountId,
      if (displayName != null) 'displayName': displayName,
      if (rigId != null) 'rigId': rigId,
      if (cameraModel != null) 'cameraModel': cameraModel,
      if (instrument != null) 'instrument': instrument,
      if (software != null) 'software': software,
      if (frameCount != null) 'frameCount': frameCount,
      if (darkCurrent != null) 'darkCurrent': darkCurrent,
      if (sensorWidth != null) 'sensorWidth': sensorWidth,
      if (sensorHeight != null) 'sensorHeight': sensorHeight,
      if (capturedAt != null) 'capturedAt': capturedAt!.toIso8601String(),
      if (note != null) 'note': note,
    };
  }

  /// Encode to the compact JSON string stored in a `provenance_json` column.
  String toJsonString() => jsonEncode(toJson());

  factory Provenance.fromJson(Map<String, dynamic> json) {
    // Every field is type-guarded (never a bare `as` cast): a type-confused
    // value (e.g. `accountId: 123`) decodes to null rather than throwing a
    // _TypeError, so the fail-soft contract holds for any JSON shape.
    String? parseStr(Object? v) => v is String ? v : null;
    DateTime? parseAt(Object? v) => v is String ? DateTime.tryParse(v) : null;
    int? parseInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    double? parseDouble(Object? v) => v is num ? v.toDouble() : null;
    return Provenance(
      accountId: parseStr(json['accountId']),
      displayName: parseStr(json['displayName']),
      rigId: parseStr(json['rigId']),
      cameraModel: parseStr(json['cameraModel']),
      instrument: parseStr(json['instrument']),
      software: parseStr(json['software']),
      frameCount: parseInt(json['frameCount']),
      darkCurrent: parseDouble(json['darkCurrent']),
      sensorWidth: parseInt(json['sensorWidth']),
      sensorHeight: parseInt(json['sensorHeight']),
      capturedAt: parseAt(json['capturedAt']),
      note: parseStr(json['note']),
    );
  }

  /// Tolerant decode from a (possibly null/blank) `provenance_json` column.
  /// Returns an empty [Provenance] rather than throwing on malformed input so a
  /// missing/legacy sidecar never blocks a download.
  factory Provenance.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const Provenance();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return Provenance.fromJson(decoded);
    } on FormatException {
      // fall through to empty
    } catch (_) {
      // Any other decode/type-confusion failure also falls through to empty:
      // a malformed sidecar must never throw and block a download.
    }
    return const Provenance();
  }
}

/// The licenses a contributor may publish a shared artifact under. The wire
/// name (`wireName`) is what is stored in a `license` column and on the hub;
/// keep these in lock-step with the hub's accepted license set.
enum ContributionLicense {
  /// Reserved — not shared; private to the contributor.
  private('private'),

  /// Public domain dedication (no attribution required, any use).
  cc0('cc0'),

  /// Attribution required, any use including commercial + derivatives.
  ccBy('cc-by'),

  /// Attribution + share-alike (derivatives under the same license).
  ccBySa('cc-by-sa'),

  /// Attribution, non-commercial use only.
  ccByNc('cc-by-nc');

  const ContributionLicense(this.wireName);

  /// Stable string stored in DB / on the wire.
  final String wireName;

  /// Whether reuse under this license obliges the user to credit the producer.
  bool get requiresAttribution =>
      this != ContributionLicense.cc0 && this != ContributionLicense.private;

  /// Whether the artifact may be shared at all.
  bool get isShareable => this != ContributionLicense.private;

  /// Decode a stored/received wire value. An unknown or null token falls back to
  /// the MOST RESTRICTIVE interpretation ([private], non-shareable) rather than
  /// to an attribution-only license, so a newer client's unrecognized license
  /// (e.g. a No-Derivatives variant) or a corrupt/tampered `license` column
  /// denies reuse instead of silently broadening the granted rights. Callers
  /// representing an explicit user action (the publish UI / constructor default)
  /// may pass [fallback] to opt into a permissive default.
  static ContributionLicense fromWire(
    String? raw, {
    ContributionLicense fallback = ContributionLicense.private,
  }) {
    if (raw == null) return fallback;
    for (final l in ContributionLicense.values) {
      if (l.wireName == raw) return l;
    }
    return fallback;
  }
}

/// The explicit consent a contributor grants when publishing an artifact: the
/// license plus the fine-grained "what may be done with my data" flags
/// required before anything is shared publicly.
class ContributionConsent {
  const ContributionConsent({
    this.license = ContributionLicense.ccBy,
    this.shareRawSubframes = false,
    this.allowDerivatives = true,
    this.allowRedistribution = true,
    this.attributionName,
    this.consentedAt,
  });

  /// The publish license.
  final ContributionLicense license;

  /// Whether the contributor consents to sharing raw subframes (not just the
  /// integrated/additive master) — the most sensitive opt-in.
  final bool shareRawSubframes;

  /// Whether downstream users may produce derivative works (composites, crops).
  final bool allowDerivatives;

  /// Whether the artifact may be re-shared onward to other hubs/users.
  final bool allowRedistribution;

  /// The exact name the contributor wants credited (overrides the account
  /// display name when set).
  final String? attributionName;

  /// When consent was given (audit trail).
  final DateTime? consentedAt;

  /// Whether this consent permits any public sharing at all. Every publish path
  /// is gated on this being true.
  bool get permitsSharing => license.isShareable;

  /// The fail-closed consent returned when a stored/received consent record is
  /// missing, blank, or malformed. A consent record is a GATE, not best-effort
  /// metadata: if we cannot read what the producer authorized, we must assume
  /// they authorized NOTHING — never silently infer derivatives/redistribution
  /// rights the producer may never have granted. Contrast with [Provenance],
  /// which is deliberately fail-soft because a missing sidecar must not block a
  /// download; consent is the opposite, and denies on absence.
  static const ContributionConsent denied = ContributionConsent(
    license: ContributionLicense.private,
    shareRawSubframes: false,
    allowDerivatives: false,
    allowRedistribution: false,
  );

  ContributionConsent copyWith({
    ContributionLicense? license,
    bool? shareRawSubframes,
    bool? allowDerivatives,
    bool? allowRedistribution,
    String? attributionName,
    DateTime? consentedAt,
  }) {
    return ContributionConsent(
      license: license ?? this.license,
      shareRawSubframes: shareRawSubframes ?? this.shareRawSubframes,
      allowDerivatives: allowDerivatives ?? this.allowDerivatives,
      allowRedistribution: allowRedistribution ?? this.allowRedistribution,
      attributionName: attributionName ?? this.attributionName,
      consentedAt: consentedAt ?? this.consentedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'license': license.wireName,
      'shareRawSubframes': shareRawSubframes,
      'allowDerivatives': allowDerivatives,
      'allowRedistribution': allowRedistribution,
      if (attributionName != null) 'attributionName': attributionName,
      if (consentedAt != null) 'consentedAt': consentedAt!.toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  /// Reconstruct a RECORDED consent from its stored/received JSON. Every flag
  /// fails closed: an unknown/missing `license` decodes to [private]
  /// (non-shareable) and a missing boolean defaults to `false`, so a consent
  /// record stripped or partially corrupted in transit/storage never silently
  /// grants derivatives or onward redistribution the producer did not record.
  /// The permissive const-constructor defaults (cc-by / allow*) apply only to
  /// the interactive publish UI, where an explicit user action sets them.
  factory ContributionConsent.fromJson(Map<String, dynamic> json) {
    // Type-guard every field instead of bare casts: a type-confused value (e.g.
    // `allowRedistribution: "true"`) must decode to the fail-closed default, not
    // throw a _TypeError out of this security gate.
    bool flag(Object? v) => v is bool ? v : false;
    final rawLicense = json['license'];
    final rawAttribution = json['attributionName'];
    return ContributionConsent(
      license: ContributionLicense.fromWire(
        rawLicense is String ? rawLicense : null,
      ),
      shareRawSubframes: flag(json['shareRawSubframes']),
      allowDerivatives: flag(json['allowDerivatives']),
      allowRedistribution: flag(json['allowRedistribution']),
      attributionName: rawAttribution is String ? rawAttribution : null,
      consentedAt: json['consentedAt'] is String
          ? DateTime.tryParse(json['consentedAt'] as String)
          : null,
    );
  }

  /// Decode from a (possibly null/blank/malformed) consent column. Unlike
  /// [Provenance.fromJsonString], this fails CLOSED: a null, blank, or
  /// unparseable record yields [denied] (private, no derivatives, no
  /// redistribution) rather than a permissive default, because a consent record
  /// is a sharing gate, not best-effort metadata.
  factory ContributionConsent.fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return denied;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ContributionConsent.fromJson(decoded);
      }
    } on FormatException {
      // fall through to the fail-closed default
    } catch (_) {
      // Any other decode/type-confusion failure also fails closed to [denied]:
      // a consent gate must never throw on bad data and risk a generic catch
      // upstream mis-handling the error as "no record".
    }
    return denied;
  }
}

/// The coarse base role a token carries — the client mirror of the hub's
/// `HubScope`. `admin` implies `contribute` implies `read` (a strict ladder),
/// matching `HubScope.satisfies`.
enum CollaborativeRole {
  read('read'),
  contribute('contribute'),
  admin('admin');

  const CollaborativeRole(this.wireName);

  final String wireName;

  /// Whether a token with this role satisfies a requirement for [required]
  /// (ladder semantics — identical to the hub's `HubScope.satisfies`).
  bool satisfies(CollaborativeRole required) => index >= required.index;

  static CollaborativeRole fromWire(
    String? raw, {
    CollaborativeRole fallback = CollaborativeRole.read,
  }) {
    if (raw == null) return fallback;
    for (final r in CollaborativeRole.values) {
      if (r.wireName == raw) return r;
    }
    return fallback;
  }
}

/// The fine-grained actions a scoped grant may permit, beyond the coarse role.
/// These are the "contribute to this mosaic, not delete it" verbs.
/// The wire name is the stable string embedded in a scoped token; keep it in
/// lock-step with the hub's `CollabAction`.
enum CollaborativeAction {
  // Shared calibration libraries.
  calibrationPublish('calibration.publish'),
  calibrationDownload('calibration.download'),

  // Collaborative mosaics.
  mosaicPublish('mosaic.publish'),
  mosaicClaim('mosaic.claim'),
  mosaicUpload('mosaic.upload'),
  mosaicDownload('mosaic.download'),
  mosaicAssemble('mosaic.assemble'),

  // Live co-imaging.
  coimagingJoin('coimaging.join'),
  coimagingContribute('coimaging.contribute'),

  // Cross-cutting.
  retract('retract'),
  attributionRead('attribution.read'),
  tokenMint('token.mint'),
  moderate('moderate');

  const CollaborativeAction(this.wireName);

  final String wireName;

  /// The minimum base role implied by this action — used both to default the
  /// allowed action set for a plain role and to reject under-privileged grants.
  CollaborativeRole get minimumRole {
    switch (this) {
      case CollaborativeAction.calibrationDownload:
      case CollaborativeAction.mosaicDownload:
      case CollaborativeAction.attributionRead:
      case CollaborativeAction.tokenMint:
        return CollaborativeRole.read;
      case CollaborativeAction.calibrationPublish:
      case CollaborativeAction.mosaicPublish:
      case CollaborativeAction.mosaicClaim:
      case CollaborativeAction.mosaicUpload:
      case CollaborativeAction.coimagingJoin:
      case CollaborativeAction.coimagingContribute:
      case CollaborativeAction.retract:
        return CollaborativeRole.contribute;
      case CollaborativeAction.mosaicAssemble:
      case CollaborativeAction.moderate:
        return CollaborativeRole.admin;
    }
  }

  static CollaborativeAction? fromWire(String? raw) {
    if (raw == null) return null;
    for (final a in CollaborativeAction.values) {
      if (a.wireName == raw) return a;
    }
    return null;
  }

  /// Every action a plain [role] permits by default (no per-action narrowing) —
  /// i.e. all actions whose [minimumRole] the role satisfies.
  static Set<CollaborativeAction> defaultsFor(CollaborativeRole role) {
    return CollaborativeAction.values
        .where((a) => role.satisfies(a.minimumRole))
        .toSet();
  }
}

/// A scoped permission grant: a base [role], optionally narrowed to a single
/// [deviceId] (per-device scope) and/or to an explicit [actions] allow-list
/// (per-action scope). This is the client mirror of the hub's `ScopedGrant` and
/// the concrete realization of fine-grained scoped roles.
///
/// Semantics:
///   * [actions] == null  → all actions the [role] permits by default.
///   * [actions] != null  → ONLY those actions (still capped by the role's
///     ladder — an action whose `minimumRole` the role cannot satisfy is never
///     permitted even if explicitly listed).
///   * [deviceId] == null → grant applies to any device; otherwise the request
///     must present the matching device id.
class CollaborativePermission {
  const CollaborativePermission({
    required this.role,
    this.deviceId,
    this.actions,
    this.resourceType,
    this.resourceId,
  });

  final CollaborativeRole role;

  /// When non-null, the grant is bound to this single device id.
  final String? deviceId;

  /// When non-null, the explicit allow-list narrowing the role's defaults.
  final Set<CollaborativeAction>? actions;

  /// When non-null, the grant is bound to a single RESOURCE — the `(type, id)`
  /// of the collaborative artifact it may act on (e.g. `('mosaic', '42')`), the
  /// mirror of the hub `ScopedGrant.resourceType/resourceId`. Both must be set
  /// for a binding to take effect; a grant bound to one resource permits
  /// nothing on another.
  final String? resourceType;
  final String? resourceId;

  /// A plain whole-role grant for any device (the legacy token shape).
  factory CollaborativePermission.role(CollaborativeRole role) =>
      CollaborativePermission(role: role);

  /// A grant narrowed to a single collaborative resource (e.g. "contribute to
  /// mosaic 42, nothing else"): the base [role] plus an optional [actions]
  /// allow-list, bound to `(resourceType, resourceId)`.
  factory CollaborativePermission.forResource({
    required CollaborativeRole role,
    required String resourceType,
    required String resourceId,
    Set<CollaborativeAction>? actions,
    String? deviceId,
  }) => CollaborativePermission(
    role: role,
    deviceId: deviceId,
    actions: actions,
    resourceType: resourceType,
    resourceId: resourceId,
  );

  /// Whether this grant carries an effective resource binding (both fields set).
  bool get isResourceBound =>
      resourceType != null &&
      resourceType!.isNotEmpty &&
      resourceId != null &&
      resourceId!.isNotEmpty;

  /// Whether this grant permits [action], optionally from device [fromDevice]
  /// and on the resource [onResourceType]/[onResourceId]. A resource-bound grant
  /// denies any action whose target resource does not match the bound `(type,
  /// id)`; an unbound grant ignores the resource parameters.
  bool permits(
    CollaborativeAction action, {
    String? fromDevice,
    String? onResourceType,
    String? onResourceId,
  }) {
    if (!role.satisfies(action.minimumRole)) return false;
    if (deviceId != null && deviceId != fromDevice) return false;
    if (actions != null && !actions!.contains(action)) return false;
    if (isResourceBound) {
      if (onResourceType != resourceType || onResourceId != resourceId) {
        return false;
      }
    }
    return true;
  }

  /// Whether this grant satisfies a coarse role requirement (ladder), ignoring
  /// per-action narrowing — used where only the base level matters.
  bool satisfiesRole(CollaborativeRole required) => role.satisfies(required);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'role': role.wireName,
      if (deviceId != null) 'deviceId': deviceId,
      if (actions != null)
        'actions': actions!.map((a) => a.wireName).toList(growable: false),
      if (resourceType != null) 'resourceType': resourceType,
      if (resourceId != null) 'resourceId': resourceId,
    };
  }

  /// Serialize to the string stored in a token's `scope` column. A plain
  /// any-device whole-role grant serializes to just the bare role name (the
  /// legacy wire form, for backward compatibility); anything narrowed
  /// serializes to JSON.
  String toScopeString() {
    if (deviceId == null &&
        actions == null &&
        resourceType == null &&
        resourceId == null) {
      return role.wireName;
    }
    return jsonEncode(toJson());
  }

  factory CollaborativePermission.fromJson(Map<String, dynamic> json) {
    // Type-guard every field: a type-confused scope value must fail closed to a
    // read-only / unrecognized grant, not throw a _TypeError.
    final rawActions = json['actions'];
    Set<CollaborativeAction>? parsedActions;
    if (rawActions is List) {
      parsedActions = rawActions
          .map((e) => CollaborativeAction.fromWire(e is String ? e : null))
          .whereType<CollaborativeAction>()
          .toSet();
    }
    final rawRole = json['role'];
    final rawDevice = json['deviceId'];
    final rawResourceType = json['resourceType'];
    final rawResourceId = json['resourceId'];
    return CollaborativePermission(
      role: CollaborativeRole.fromWire(rawRole is String ? rawRole : null),
      deviceId: rawDevice is String ? rawDevice : null,
      actions: parsedActions,
      resourceType: rawResourceType is String ? rawResourceType : null,
      resourceId: rawResourceId is String ? rawResourceId : null,
    );
  }

  /// Parse a token `scope` column value: either a bare legacy role name
  /// (`read`/`contribute`/`admin`) or a JSON scoped grant. Returns a read-only
  /// grant on anything unrecognized (fail-closed).
  factory CollaborativePermission.fromScopeString(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return CollaborativePermission.role(CollaborativeRole.read);
    }
    final trimmed = raw.trim();
    if (trimmed.startsWith('{')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          return CollaborativePermission.fromJson(decoded);
        }
      } on FormatException {
        // fall through to bare-role parse / fail-closed
      } catch (_) {
        // Any other decode/type-confusion failure fails closed too: a corrupt
        // scope value must never throw out of permission resolution.
        return CollaborativePermission.role(CollaborativeRole.read);
      }
    }
    return CollaborativePermission.role(CollaborativeRole.fromWire(trimmed));
  }
}
