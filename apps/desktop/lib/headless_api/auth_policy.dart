import 'dart:collection';

import 'route_metadata.dart' as route_metadata;

enum HeadlessTokenScope { view, control, admin }

HeadlessTokenScope? parseHeadlessTokenScope(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'view':
    case 'view-only':
    case 'readonly':
    case 'read-only':
      return HeadlessTokenScope.view;
    case 'control':
    case 'imaging-control':
    case 'imaging':
      return HeadlessTokenScope.control;
    case 'admin':
      return HeadlessTokenScope.admin;
    default:
      return null;
  }
}

String headlessTokenScopeName(HeadlessTokenScope scope) {
  switch (scope) {
    case HeadlessTokenScope.view:
      return 'view';
    case HeadlessTokenScope.control:
      return 'control';
    case HeadlessTokenScope.admin:
      return 'admin';
  }
}

/// Per-device / per-feature axis a fine-grained grant can carve. A coarse
/// `view`/`control` token maps to "every resource at that level" via
/// [HeadlessAuthGrant.fromCoarse]; a fine-grained token (e.g. "control camera
/// but not mount") names only the resources it covers.
///
/// `devices` is the connect/disconnect surface (`/api/devices/*`). It is its
/// own resource because those endpoints are device-agnostic — the device kind
/// lives in the request body, not the path — so a fine-grained token must
/// explicitly hold `devices:control` to power gear on or off. Coarse `control`
/// includes it, so existing tokens are unaffected.
enum HeadlessResource {
  camera,
  mount,
  focuser,
  filterWheel,
  rotator,
  dome,
  cover,
  guiding,
  safety,
  switchGear,
  sequencer,
  framing,
  calibration,
  catalog,
  filesystem,
  backup,
  settings,
  plugins,
  devices,
  // Collaborative Sky resources (`/api/mosaic/`, `/api/coimaging/`,
  // `/api/constellation/`). First-class resources rather than [system], so a
  // fine-grained token can hold `mosaic:control` without also holding `system`.
  mosaic,
  coimaging,
  constellation,
  // Darkroom peer delivery (`/api/darkroom/`). The published-master pull
  // surface. First-class for the same reason as the collaborative resources
  // above: without it these routes fell through to [system], so a fine-grained
  // token needed `system` (admin-adjacent) to collect a night, and every
  // `system` grant silently gained the right to stream the rig's masters.
  darkroom,
  system,
  info,
}

/// Access level on a single [HeadlessResource]. `view` reads state, `control`
/// reads + mutates. `none` is the absence of any grant for the resource.
enum HeadlessAccessLevel { none, view, control }

String headlessResourceName(HeadlessResource resource) {
  switch (resource) {
    case HeadlessResource.camera:
      return 'camera';
    case HeadlessResource.mount:
      return 'mount';
    case HeadlessResource.focuser:
      return 'focuser';
    case HeadlessResource.filterWheel:
      return 'filter-wheel';
    case HeadlessResource.rotator:
      return 'rotator';
    case HeadlessResource.dome:
      return 'dome';
    case HeadlessResource.cover:
      return 'cover';
    case HeadlessResource.guiding:
      return 'guiding';
    case HeadlessResource.safety:
      return 'safety';
    case HeadlessResource.switchGear:
      return 'switch';
    case HeadlessResource.sequencer:
      return 'sequencer';
    case HeadlessResource.framing:
      return 'framing';
    case HeadlessResource.calibration:
      return 'calibration';
    case HeadlessResource.catalog:
      return 'catalog';
    case HeadlessResource.filesystem:
      return 'filesystem';
    case HeadlessResource.backup:
      return 'backup';
    case HeadlessResource.settings:
      return 'settings';
    case HeadlessResource.plugins:
      return 'plugins';
    case HeadlessResource.devices:
      return 'devices';
    case HeadlessResource.mosaic:
      return 'mosaic';
    case HeadlessResource.coimaging:
      return 'coimaging';
    case HeadlessResource.constellation:
      return 'constellation';
    case HeadlessResource.darkroom:
      return 'darkroom';
    case HeadlessResource.system:
      return 'system';
    case HeadlessResource.info:
      return 'info';
  }
}

HeadlessResource? parseHeadlessResource(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'camera':
      return HeadlessResource.camera;
    case 'mount':
      return HeadlessResource.mount;
    case 'focuser':
      return HeadlessResource.focuser;
    case 'filter-wheel':
    case 'filterwheel':
      return HeadlessResource.filterWheel;
    case 'rotator':
      return HeadlessResource.rotator;
    case 'dome':
      return HeadlessResource.dome;
    case 'cover':
      return HeadlessResource.cover;
    case 'guiding':
    case 'guider':
      return HeadlessResource.guiding;
    case 'safety':
    case 'weather':
      return HeadlessResource.safety;
    case 'switch':
      return HeadlessResource.switchGear;
    case 'sequencer':
      return HeadlessResource.sequencer;
    case 'framing':
      return HeadlessResource.framing;
    case 'calibration':
      return HeadlessResource.calibration;
    case 'catalog':
      return HeadlessResource.catalog;
    case 'filesystem':
    case 'files':
      return HeadlessResource.filesystem;
    case 'backup':
      return HeadlessResource.backup;
    case 'settings':
      return HeadlessResource.settings;
    case 'plugins':
      return HeadlessResource.plugins;
    case 'devices':
      return HeadlessResource.devices;
    case 'mosaic':
      return HeadlessResource.mosaic;
    case 'coimaging':
    case 'co-imaging':
      return HeadlessResource.coimaging;
    case 'constellation':
    // The live collaboration surface (`/api/collaboration/*`) shares the
    // collaborative `constellation` resource, so a fine-grained token may name
    // it with either the `collaboration` or `constellation` key.
    case 'collaboration':
      return HeadlessResource.constellation;
    case 'darkroom':
      return HeadlessResource.darkroom;
    case 'system':
      return HeadlessResource.system;
    case 'info':
      return HeadlessResource.info;
    default:
      return null;
  }
}

String headlessAccessLevelName(HeadlessAccessLevel level) {
  switch (level) {
    case HeadlessAccessLevel.none:
      return 'none';
    case HeadlessAccessLevel.view:
      return 'view';
    case HeadlessAccessLevel.control:
      return 'control';
  }
}

HeadlessAccessLevel? parseHeadlessAccessLevel(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'view':
    case 'view-only':
    case 'readonly':
    case 'read-only':
      return HeadlessAccessLevel.view;
    case 'control':
      return HeadlessAccessLevel.control;
    default:
      return null;
  }
}

int _accessRank(HeadlessAccessLevel level) {
  switch (level) {
    case HeadlessAccessLevel.none:
      return 0;
    case HeadlessAccessLevel.view:
      return 1;
    case HeadlessAccessLevel.control:
      return 2;
  }
}

/// The access a single endpoint demands. Produced by
/// [HeadlessAuthPolicy.requiredCapabilityFor] from the (still authoritative)
/// route-metadata decision tree, and checked against a presented
/// [HeadlessAuthGrant].
class RouteCapability {
  final HeadlessResource resource;
  final HeadlessAccessLevel level;

  /// Requires an admin grant regardless of [resource]/[level].
  final bool adminOnly;

  /// Satisfiable by any grant (the public surface, e.g. `GET /api/info`).
  final bool public;

  const RouteCapability(
    this.resource,
    this.level, {
    this.adminOnly = false,
    this.public = false,
  });

  const RouteCapability.public()
    : resource = HeadlessResource.info,
      level = HeadlessAccessLevel.none,
      adminOnly = false,
      public = true;

  const RouteCapability.admin(this.resource)
    : level = HeadlessAccessLevel.none,
      adminOnly = true,
      public = false;
}

/// An immutable capability set granted to a bearer token: an access level per
/// [HeadlessResource] plus an [isAdmin] flag that permits everything.
///
/// Three construction paths, all funnelling through [permits] for enforcement:
///   * [HeadlessAuthGrant.fromCoarse] — the back-compat bridge. A legacy
///     `view`/`control`/`admin` scope expands to "every resource at that
///     level" so existing tokens keep their exact reach (pinned by the
///     characterization test over the endpoint catalog).
///   * [HeadlessAuthGrant.forResources] — a fine-grained grant naming only the
///     resources it covers.
///   * [HeadlessAuthGrant.parseSpec] — the single canonical text format reused
///     by config (`SKOTIQ_SCOPED_TOKEN`), pairing (`requestedScope`), and
///     the in-memory paired map so the surfaces never diverge.
class HeadlessAuthGrant {
  final UnmodifiableMapView<HeadlessResource, HeadlessAccessLevel> levels;
  final bool isAdmin;

  HeadlessAuthGrant._(
    Map<HeadlessResource, HeadlessAccessLevel> levels,
    this.isAdmin,
  ) : levels = UnmodifiableMapView(levels);

  factory HeadlessAuthGrant.admin() => HeadlessAuthGrant._(const {}, true);

  factory HeadlessAuthGrant.forResources(
    Map<HeadlessResource, HeadlessAccessLevel> levels, {
    bool isAdmin = false,
  }) {
    final filtered = <HeadlessResource, HeadlessAccessLevel>{};
    for (final entry in levels.entries) {
      if (entry.value != HeadlessAccessLevel.none) {
        filtered[entry.key] = entry.value;
      }
    }
    return HeadlessAuthGrant._(filtered, isAdmin);
  }

  /// Back-compat bridge: expand a coarse scope to a grant with identical reach.
  factory HeadlessAuthGrant.fromCoarse(HeadlessTokenScope scope) {
    switch (scope) {
      case HeadlessTokenScope.admin:
        return HeadlessAuthGrant.admin();
      case HeadlessTokenScope.control:
        return HeadlessAuthGrant._(
          _everyResourceAt(HeadlessAccessLevel.control),
          false,
        );
      case HeadlessTokenScope.view:
        return HeadlessAuthGrant._(
          _everyResourceAt(HeadlessAccessLevel.view),
          false,
        );
    }
  }

  static Map<HeadlessResource, HeadlessAccessLevel> _everyResourceAt(
    HeadlessAccessLevel level,
  ) {
    return {for (final r in HeadlessResource.values) r: level};
  }

  HeadlessAccessLevel levelFor(HeadlessResource resource) {
    if (isAdmin) return HeadlessAccessLevel.control;
    return levels[resource] ?? HeadlessAccessLevel.none;
  }

  bool permits(RouteCapability capability) {
    if (capability.public) return true;
    if (capability.adminOnly) return isAdmin;
    return _accessRank(levelFor(capability.resource)) >=
        _accessRank(capability.level);
  }

  /// Best-effort coarse projection for the legacy `/api/info` scope list and
  /// the back-compat 403 fields. A fine-grained grant that mutates any resource
  /// reports as `control`; a read-only one as `view`.
  HeadlessTokenScope get coarseScope {
    if (isAdmin) return HeadlessTokenScope.admin;
    if (levels.values.contains(HeadlessAccessLevel.control)) {
      return HeadlessTokenScope.control;
    }
    return HeadlessTokenScope.view;
  }

  /// Canonical text form. Coarse grants round-trip to `admin`/`control`/`view`;
  /// fine-grained grants to a sorted `resource:level` comma list.
  String toSpec() {
    if (isAdmin) return 'admin';
    final entries = levels.entries.toList()
      ..sort((a, b) => a.key.index.compareTo(b.key.index));
    if (entries.isEmpty) return 'view';
    final everyControl =
        entries.length == HeadlessResource.values.length &&
        entries.every((e) => e.value == HeadlessAccessLevel.control);
    if (everyControl) return 'control';
    final everyView =
        entries.length == HeadlessResource.values.length &&
        entries.every((e) => e.value == HeadlessAccessLevel.view);
    if (everyView) return 'view';
    return entries
        .map(
          (e) =>
              '${headlessResourceName(e.key)}:${headlessAccessLevelName(e.value)}',
        )
        .join(',');
  }

  /// Parse the canonical text form. Returns null on a malformed spec so the
  /// caller can fail closed. Accepts the coarse shortcuts (`view`, `control`,
  /// `admin`, plus the documented aliases) and the fine-grained
  /// `camera:control,mount:view` form.
  static HeadlessAuthGrant? parseSpec(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;

    final coarse = parseHeadlessTokenScope(trimmed);
    if (coarse != null) return HeadlessAuthGrant.fromCoarse(coarse);

    final map = <HeadlessResource, HeadlessAccessLevel>{};
    for (final part in trimmed.split(',')) {
      final token = part.trim();
      if (token.isEmpty) continue;
      final kv = token.split(':');
      if (kv.length != 2) return null;
      final resource = parseHeadlessResource(kv[0]);
      final level = parseHeadlessAccessLevel(kv[1]);
      if (resource == null || level == null) return null;
      map[resource] = level;
    }
    if (map.isEmpty) return null;
    return HeadlessAuthGrant.forResources(map);
  }
}

class HeadlessAuthPolicy {
  const HeadlessAuthPolicy._();

  static HeadlessTokenScope requiredScopeFor({
    required String method,
    required String path,
  }) {
    final scopeName = route_metadata.requiredAuthScopeNameForEndpoint(
      method: method,
      path: path,
    );
    // Public endpoints never reach this check in the middleware (they are
    // short-circuited before token resolution), but keep the mapping
    // truthful for any other caller: public is satisfiable by any scope.
    if (scopeName == 'public') {
      return HeadlessTokenScope.view;
    }
    // Fail CLOSED on anything unrecognised. The route metadata only emits
    // public/view/control/admin today; if a future scope name is added
    // there without updating the parser, the safe failure mode is to
    // require the highest privilege, not silently grant view access.
    return parseHeadlessTokenScope(scopeName) ?? HeadlessTokenScope.admin;
  }

  /// The fine-grained capability an endpoint demands. Derives the resource
  /// from [route_metadata.resourceKeyForEndpoint] and the access level from the
  /// authoritative coarse decision tree, so the two can never disagree.
  static RouteCapability requiredCapabilityFor({
    required String method,
    required String path,
  }) {
    final scopeName = route_metadata.requiredAuthScopeNameForEndpoint(
      method: method,
      path: path,
    );
    if (scopeName == 'public') {
      return const RouteCapability.public();
    }
    final resource =
        parseHeadlessResource(
          route_metadata.resourceKeyForEndpoint(method: method, path: path),
        ) ??
        HeadlessResource.system;
    switch (scopeName) {
      case 'view':
        return RouteCapability(resource, HeadlessAccessLevel.view);
      case 'control':
        return RouteCapability(resource, HeadlessAccessLevel.control);
      case 'admin':
        return RouteCapability.admin(resource);
      default:
        // Fail CLOSED: an unrecognised scope name requires admin, mirroring
        // [requiredScopeFor].
        return RouteCapability.admin(resource);
    }
  }

  static bool allows({
    required HeadlessTokenScope actual,
    required String method,
    required String path,
  }) {
    final required = requiredScopeFor(method: method, path: path);
    return _rank(actual) >= _rank(required);
  }

  /// Fine-grained enforcement: does [grant] satisfy the capability this
  /// endpoint demands? The coarse [allows] is a special case of this via
  /// [HeadlessAuthGrant.fromCoarse] (pinned by the characterization test).
  static bool permits({
    required HeadlessAuthGrant grant,
    required String method,
    required String path,
  }) {
    return grant.permits(requiredCapabilityFor(method: method, path: path));
  }

  /// The body of a scope refusal, derived from the SAME grant and endpoint the
  /// refusal was decided on so it can never describe a different decision.
  ///
  /// `requiredResource` + `requiredLevel` name what the endpoint demands, and
  /// `tokenLevel` names what the presented credential actually holds on that
  /// resource — the one fact that explains the refusal.
  ///
  /// The coarse pair (`requiredScope`/`tokenScope`) is the back-compat bridge
  /// and is emitted ONLY when it reads as a refusal on its own terms. A
  /// fine-grained grant projects to `view` under [HeadlessAuthGrant.coarseScope]
  /// however few resources it names, so on a view-level route the body used to
  /// carry `requiredScope: view` beside `tokenScope: view` — the two fields a
  /// human reads first, asserting the requirement was met while denying it.
  /// When the coarse projection does not account for the outcome those fields
  /// are left out rather than printed as a contradiction.
  ///
  /// `error` and the leading clause of `message` are the wire contract paired
  /// clients already match on to tell a scope refusal from any other denial
  /// (`rig_catalog_settings._describeFailure`), so both keep their exact text.
  static Map<String, Object?> scopeDenialBody({
    required HeadlessAuthGrant grant,
    required String method,
    required String path,
  }) {
    final capability = requiredCapabilityFor(method: method, path: path);
    final requiredScope = requiredScopeFor(method: method, path: path);
    final resourceName = headlessResourceName(capability.resource);
    final requiredLevelName = capability.adminOnly
        ? 'admin'
        : headlessAccessLevelName(capability.level);
    final heldLevelName = grant.isAdmin
        ? 'admin'
        : headlessAccessLevelName(grant.levelFor(capability.resource));
    final body = <String, Object?>{
      'error': 'Access denied',
      'message':
          'Token scope is not permitted for this endpoint: this credential '
          'holds $heldLevelName on $resourceName, and $requiredLevelName is '
          'required.',
      'requiredResource': resourceName,
      'requiredLevel': requiredLevelName,
      'tokenLevel': heldLevelName,
    };
    if (_rank(grant.coarseScope) < _rank(requiredScope)) {
      body['requiredScope'] = headlessTokenScopeName(requiredScope);
      body['tokenScope'] = headlessTokenScopeName(grant.coarseScope);
    }
    return body;
  }

  static int _rank(HeadlessTokenScope scope) {
    switch (scope) {
      case HeadlessTokenScope.view:
        return 0;
      case HeadlessTokenScope.control:
        return 1;
      case HeadlessTokenScope.admin:
        return 2;
    }
  }
}
