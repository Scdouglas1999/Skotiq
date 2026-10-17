/// Ready-to-image readiness model surface.
///
/// This file is the pure, fail-closed core of the "Ready to image" system
/// surfaced after onboarding / first light. It contains NO Flutter, NO
/// Riverpod, and NO I/O: it is a deterministic function of a handful of
/// booleans describing the user's current setup. The provider layer collects
/// those booleans from device-state / settings / plate-solver / dark-library
/// providers and feeds them to [buildReadinessReport]; the UI renders the
/// resulting [ReadinessReport].
///
/// Why pure: keeping the decision logic free of dependencies makes the
/// readiness rules exhaustively unit-testable and makes the fail-closed
/// contract auditable in one place. The rules below are intentionally
/// conservative — a device that is genuinely disconnected must never resolve
/// to [ReadinessLevel.ready]; a missing critical device resolves to
/// [ReadinessLevel.blocked] rather than degrading to a softer level.
library;

/// Severity of a single readiness check, and of the report overall.
///
/// The three levels map to the standard traffic-light treatment used across
/// the app (green / amber / red). [severity] defines a stable, total ordering
/// so callers can compute "the worst level present" without a hand-rolled
/// switch: `blocked` (2) > `caution` (1) > `ready` (0).
///
/// Do not reorder the enum constants — [severity] is derived from explicit
/// values, not [Enum.index], precisely so that adding or reordering constants
/// in the future cannot silently change the comparison semantics.
enum ReadinessLevel {
  /// Everything required for this check is in place (green).
  ready,

  /// The check is non-blocking but degraded — imaging can proceed, but some
  /// capability is unavailable or unverified (amber).
  caution,

  /// The check is failing in a way that prevents first light (red).
  blocked;

  /// Human-readable label for the level, used in chips/pills/summaries.
  String get label {
    switch (this) {
      case ReadinessLevel.ready:
        return 'Ready';
      case ReadinessLevel.caution:
        return 'Caution';
      case ReadinessLevel.blocked:
        return 'Blocked';
    }
  }

  /// Stable severity rank used for ordering and "worst level" reduction.
  /// Higher is worse. Defined explicitly (not via [Enum.index]) so the
  /// ordering contract is independent of declaration order.
  int get severity {
    switch (this) {
      case ReadinessLevel.ready:
        return 0;
      case ReadinessLevel.caution:
        return 1;
      case ReadinessLevel.blocked:
        return 2;
    }
  }

  /// Returns the more severe of [this] and [other]. Ties return [this].
  ReadinessLevel worstOf(ReadinessLevel other) =>
      other.severity > severity ? other : this;
}

/// Stable identifiers for each readiness check.
///
/// Used as the de-dup / lookup key for items and as a stable handle the UI can
/// switch on (e.g. to choose an icon per check). The string [name] is also
/// suitable for analytics keys; it must remain stable across releases.
enum ReadinessItemId {
  /// Equipment profile exists and the camera (the one truly-critical device
  /// for first light) is connected; mount is desirable but non-blocking.
  criticalDevices,

  /// Every OTHER device the active profile assigns (guider, focuser, filter
  /// wheel, rotator, dome, weather, safety monitor, …) is actually connected.
  profileDevices,

  /// Observing location (lat/lon) is configured.
  location,

  /// A capture output directory is configured.
  outputPath,

  /// A plate solver (ASTAP / astrometry.net) is installed and ready.
  plateSolver,

  /// The dark library has coverage matching the current configuration.
  darkLibrary,

  /// Focus state is known (a focus run has been performed this session).
  focusState,
}

/// A single readiness check with its current [level] and an optional
/// remediation route.
///
/// [fixRoute] is a go_router path (e.g. `/equipment`, `/settings`,
/// `/settings/plate-solving`) the UI can navigate to so the user can resolve
/// the issue; [fixLabel] is the call-to-action text (e.g. `Set location`).
/// Both are null when the item is [ReadinessLevel.ready] — there is nothing to
/// fix — so the UI can use `fixRoute != null` to decide whether to render an
/// action button.
class ReadinessItem {
  /// Stable identifier for this check.
  final ReadinessItemId id;

  /// Short human title (e.g. `Observing location`).
  final String title;

  /// One-line actionable detail describing the current state and, when not
  /// ready, what to do about it.
  final String detail;

  /// Current severity of this check.
  final ReadinessLevel level;

  /// go_router path to the screen that resolves this item, or null when there
  /// is nothing to fix (i.e. the item is [ReadinessLevel.ready]).
  final String? fixRoute;

  /// Call-to-action label paired with [fixRoute], or null when [fixRoute] is
  /// null. Invariant: [fixRoute] and [fixLabel] are both null or both set.
  final String? fixLabel;

  const ReadinessItem({
    required this.id,
    required this.title,
    required this.detail,
    required this.level,
    this.fixRoute,
    this.fixLabel,
  }) : assert(
         (fixRoute == null) == (fixLabel == null),
         'fixRoute and fixLabel must both be null or both be set',
       );

  factory ReadinessItem.fromStorageJson(Map<String, dynamic> json) {
    final id = ReadinessItemId.values.firstWhere(
      (value) => value.name == json['id'],
      orElse: () => ReadinessItemId.criticalDevices,
    );
    final level = ReadinessLevel.values.firstWhere(
      (value) => value.name == json['level'],
      orElse: () => ReadinessLevel.blocked,
    );
    return ReadinessItem(
      id: id,
      title: json['title'] as String? ?? id.name,
      detail: json['detail'] as String? ?? 'Readiness is unavailable',
      level: level,
      fixRoute: json['fixRoute'] as String?,
      fixLabel: json['fixLabel'] as String?,
    );
  }

  Map<String, dynamic> toStorageJson() => {
    'id': id.name,
    'title': title,
    'detail': detail,
    'level': level.name,
    'fixRoute': fixRoute,
    'fixLabel': fixLabel,
  };

  /// True when this item is fully satisfied.
  bool get isReady => level == ReadinessLevel.ready;

  /// True when there is a navigable remediation for this item.
  bool get hasFix => fixRoute != null;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ReadinessItem &&
        other.id == id &&
        other.title == title &&
        other.detail == detail &&
        other.level == level &&
        other.fixRoute == fixRoute &&
        other.fixLabel == fixLabel;
  }

  @override
  int get hashCode => Object.hash(id, title, detail, level, fixRoute, fixLabel);

  @override
  String toString() =>
      'ReadinessItem(${id.name}, ${level.name}, fixRoute: $fixRoute)';
}

/// Aggregate readiness across all checks.
///
/// The [overall] level is the worst level present across [items]
/// (fail-closed): any [ReadinessLevel.blocked] makes the whole report blocked,
/// otherwise any [ReadinessLevel.caution] makes it caution, otherwise ready.
/// An empty report is treated as [ReadinessLevel.blocked] — we never claim the
/// user is "ready to image" when we have no evidence at all.
///
/// Implements value equality so it can be used directly as Riverpod provider
/// state without spurious rebuilds when the underlying inputs are unchanged.
class ReadinessReport {
  /// The individual checks, in stable display order.
  final List<ReadinessItem> items;

  const ReadinessReport({required this.items});

  factory ReadinessReport.fromStorageJson(dynamic value) {
    if (value is! Map || value['items'] is! List) {
      return const ReadinessReport(items: []);
    }
    return ReadinessReport(
      items: [
        for (final raw in value['items'] as List)
          if (raw is Map)
            ReadinessItem.fromStorageJson(raw.cast<String, dynamic>()),
      ],
    );
  }

  Map<String, dynamic> toStorageJson() => {
    'items': [for (final item in items) item.toStorageJson()],
  };

  /// Worst level across all [items]. Fail-closed: an empty report is
  /// [ReadinessLevel.blocked], never [ReadinessLevel.ready].
  ReadinessLevel get overall {
    if (items.isEmpty) return ReadinessLevel.blocked;
    var worst = ReadinessLevel.ready;
    for (final item in items) {
      worst = worst.worstOf(item.level);
    }
    return worst;
  }

  /// All items currently at [ReadinessLevel.blocked], in display order.
  List<ReadinessItem> get blockedItems =>
      items.where((i) => i.level == ReadinessLevel.blocked).toList();

  /// All items currently at [ReadinessLevel.caution], in display order.
  List<ReadinessItem> get cautionItems =>
      items.where((i) => i.level == ReadinessLevel.caution).toList();

  /// True when the user can begin imaging (no blocking items).
  bool get isReadyToImage => overall != ReadinessLevel.blocked;

  /// Top-line summary label keyed off [overall].
  String get summaryLabel {
    switch (overall) {
      case ReadinessLevel.ready:
        return 'Ready to image';
      case ReadinessLevel.caution:
        return 'Almost ready';
      case ReadinessLevel.blocked:
        return 'Not ready';
    }
  }

  /// Look up a single item by its stable id, or null if not present.
  ReadinessItem? itemFor(ReadinessItemId id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ReadinessReport) return false;
    if (other.items.length != items.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (other.items[i] != items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() =>
      'ReadinessReport(${overall.name}, ${items.length} items)';
}

/// go_router paths used by readiness remediations. Kept here so the routes the
/// model references are spelled out in one place and match the router. These
/// are intentionally the existing app routes — readiness does not introduce
/// new screens, it points at the relevant settings/equipment surfaces.
const String _routeEquipment = '/equipment';
const String _routeSettings = '/settings';
const String _routePlateSolving = '/settings/plate-solving';

/// Builds the readiness report from the current setup signals.
///
/// This is the single source of truth for the readiness rules. It is pure and
/// total: given the same inputs it always returns an equal report. The rules
/// are deliberately fail-closed — see the per-item documentation below.
///
/// Inputs:
/// - [cameraConnected]: the active camera reports a live connection.
/// - [mountConnected]: the active mount reports a live connection.
/// - [hasProfile]: an equipment profile exists and is active.
/// - [locationSet]: an observing location (lat/lon) is configured.
/// - [outputPathSet]: a capture output directory is configured.
/// - [plateSolverReady]: a plate solver is installed and (for ASTAP) has a
///   catalog (see `PlateSolverDetection.astapReady` / `hasAnySolver`).
/// - [darkLibraryHasCoverage]: the dark library has frames matching the
///   current configuration.
/// - [focusKnown]: focus has been established (a focus run has succeeded).
/// - [offlineProfileDevices]: display names of device slots the active profile
///   assigns that are NOT connected right now (camera and mount excluded — they
///   have their own item). Empty means every assigned device is up.
/// - [hasActiveProfile]: a profile is selected as active. Distinct from
///   [hasProfile] (which only asks whether any profile exists at all).
/// - [assignedProfileDeviceCount]: how many slots the active profile assigns,
///   camera and mount INCLUDED. Zero means the profile is empty, which is what
///   separates "nothing is assigned" from "everything assigned is connected".
/// - [otherAssignedProfileDeviceCount]: the same count with camera and mount
///   removed — i.e. how many devices the profile-devices item actually covers.
ReadinessReport buildReadinessReport({
  required bool cameraConnected,
  required bool mountConnected,
  required bool hasProfile,
  required bool locationSet,
  required bool outputPathSet,
  required bool plateSolverReady,
  required bool darkLibraryHasCoverage,
  required bool focusKnown,
  List<String> offlineProfileDevices = const <String>[],
  // Required, not defaulted: a caller that forgets to supply the profile's
  // assignment counts would otherwise silently get the vacuous
  // "every device is connected" pass this parameter exists to prevent.
  required bool hasActiveProfile,
  required int assignedProfileDeviceCount,
  required int otherAssignedProfileDeviceCount,
}) {
  return ReadinessReport(
    items: [
      _buildCriticalDevices(
        hasProfile: hasProfile,
        cameraConnected: cameraConnected,
        mountConnected: mountConnected,
      ),
      _buildProfileDevices(
        offlineProfileDevices: offlineProfileDevices,
        hasActiveProfile: hasActiveProfile,
        assignedProfileDeviceCount: assignedProfileDeviceCount,
        otherAssignedProfileDeviceCount: otherAssignedProfileDeviceCount,
      ),
      _buildLocation(locationSet: locationSet),
      _buildOutputPath(outputPathSet: outputPathSet),
      _buildPlateSolver(plateSolverReady: plateSolverReady),
      _buildDarkLibrary(darkLibraryHasCoverage: darkLibraryHasCoverage),
      _buildFocusState(focusKnown: focusKnown),
    ],
  );
}

/// Critical devices.
///
/// Fail-closed contract: this is BLOCKED whenever there is no equipment
/// profile OR the camera is disconnected. The camera is the one truly-critical
/// device for first light — without it you cannot capture at all. A missing
/// mount is degrading but not blocking (you can still take frames, you just
/// cannot slew), so a connected camera with a disconnected mount is CAUTION.
/// READY requires profile + camera + mount all present.
ReadinessItem _buildCriticalDevices({
  required bool hasProfile,
  required bool cameraConnected,
  required bool mountConnected,
}) {
  if (!hasProfile) {
    return const ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail:
          'No equipment profile is set up yet. '
          'Create a profile and connect your camera to begin.',
      level: ReadinessLevel.blocked,
      fixRoute: _routeEquipment,
      fixLabel: 'Set up equipment',
    );
  }
  if (!cameraConnected) {
    // Both faults are named. Reporting only the highest-priority one hid the
    // mount completely whenever the camera was also down (the mount is
    // excluded from the profile-devices item as "already covered here"), so a
    // user reading the readiness list with everything disconnected concluded
    // the mount was fine.
    if (!mountConnected) {
      return const ReadinessItem(
        id: ReadinessItemId.criticalDevices,
        title: 'Critical devices',
        detail:
            'Camera and mount are not connected. A connected camera is '
            'required before you can capture, and the mount is required '
            'to slew or track.',
        level: ReadinessLevel.blocked,
        fixRoute: _routeEquipment,
        fixLabel: 'Connect devices',
      );
    }
    return const ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail:
          'Camera is not connected. A connected camera is required '
          'before you can capture.',
      level: ReadinessLevel.blocked,
      fixRoute: _routeEquipment,
      fixLabel: 'Connect camera',
    );
  }
  if (!mountConnected) {
    return const ReadinessItem(
      id: ReadinessItemId.criticalDevices,
      title: 'Critical devices',
      detail:
          'Camera connected. Mount is not connected — you can capture '
          'but cannot slew or track until the mount is online.',
      level: ReadinessLevel.caution,
      fixRoute: _routeEquipment,
      fixLabel: 'Connect mount',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.criticalDevices,
    title: 'Critical devices',
    detail: 'Camera and mount are connected.',
    level: ReadinessLevel.ready,
  );
}

/// Other profile devices.
///
/// CAUTION when the active profile assigns a device that is not connected. Not
/// blocking — you can image without a guider or a dome — but it must be VISIBLE,
/// which was the whole defect: a profile whose guider failed to connect on
/// launch produced no card, no banner and no readiness row, while the same
/// screen read "Ready to image / 2 items to review" and neither item was the
/// guider. The only explanation anywhere in the product was a tooltip on a
/// ~6 px status dot.
ReadinessItem _buildProfileDevices({
  required List<String> offlineProfileDevices,
  required bool hasActiveProfile,
  required int assignedProfileDeviceCount,
  required int otherAssignedProfileDeviceCount,
}) {
  // Empty-set guard. "Every device assigned in the active profile is
  // connected" is vacuously true over an empty profile, and it rendered as a
  // GREEN row on a fresh install with nothing assigned and nothing connected —
  // the most misleading thing a readiness panel can say. Each of the three
  // empty-set shapes gets its own honest sentence instead.
  if (!hasActiveProfile) {
    return const ReadinessItem(
      id: ReadinessItemId.profileDevices,
      title: 'Profile devices',
      detail:
          'No equipment profile is active, so there are no device '
          'assignments to check.',
      level: ReadinessLevel.ready,
    );
  }
  if (assignedProfileDeviceCount == 0) {
    return const ReadinessItem(
      id: ReadinessItemId.profileDevices,
      title: 'Profile devices',
      detail:
          'No devices are assigned to this profile, so nothing connects '
          'automatically. Assign your camera, mount and accessories.',
      level: ReadinessLevel.caution,
      fixRoute: _routeEquipment,
      fixLabel: 'Assign devices',
    );
  }
  if (offlineProfileDevices.isEmpty) {
    if (otherAssignedProfileDeviceCount == 0) {
      return const ReadinessItem(
        id: ReadinessItemId.profileDevices,
        title: 'Profile devices',
        detail:
            'This profile assigns no accessories beyond the camera and '
            'mount — nothing else to connect.',
        level: ReadinessLevel.ready,
      );
    }
    return const ReadinessItem(
      id: ReadinessItemId.profileDevices,
      title: 'Profile devices',
      detail:
          'Every accessory assigned in the active profile is connected '
          '(camera and mount are covered above).',
      level: ReadinessLevel.ready,
    );
  }
  final names = offlineProfileDevices.join(', ');
  final plural = offlineProfileDevices.length > 1;
  return ReadinessItem(
    id: ReadinessItemId.profileDevices,
    title: 'Profile devices',
    detail:
        'Assigned in your profile but not connected: $names. '
        '${plural ? 'They' : 'It'} will be unavailable this session.',
    level: ReadinessLevel.caution,
    fixRoute: _routeEquipment,
    fixLabel: plural ? 'Connect devices' : 'Connect device',
  );
}

/// Observing location.
///
/// BLOCKED when no location is set: an unknown site makes altitude/visibility,
/// meridian flips, and slew safety meaningless, so the rig is not ready.
/// Routes to Settings → Location.
ReadinessItem _buildLocation({required bool locationSet}) {
  if (!locationSet) {
    return const ReadinessItem(
      id: ReadinessItemId.location,
      title: 'Observing location',
      detail:
          'No observing location set. Enter your latitude and longitude '
          'so targets and slews are computed correctly.',
      level: ReadinessLevel.blocked,
      fixRoute: _routeSettings,
      fixLabel: 'Set location',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.location,
    title: 'Observing location',
    detail: 'Observing location is configured.',
    level: ReadinessLevel.ready,
  );
}

/// Output path.
///
/// BLOCKED when no capture directory is set: captures would have nowhere to
/// land. Routes to Settings → File Paths.
ReadinessItem _buildOutputPath({required bool outputPathSet}) {
  if (!outputPathSet) {
    return const ReadinessItem(
      id: ReadinessItemId.outputPath,
      title: 'Capture output folder',
      detail:
          'No capture folder selected. Choose where saved images should '
          'be written.',
      level: ReadinessLevel.blocked,
      fixRoute: _routeSettings,
      fixLabel: 'Choose folder',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.outputPath,
    title: 'Capture output folder',
    detail: 'Capture output folder is set.',
    level: ReadinessLevel.ready,
  );
}

/// Plate solver.
///
/// CAUTION (not blocked) when no solver is ready: you can still capture and
/// frame manually, but centering / automated alignment will be unavailable.
/// Routes to the dedicated Plate Solving settings page.
ReadinessItem _buildPlateSolver({required bool plateSolverReady}) {
  if (!plateSolverReady) {
    return const ReadinessItem(
      id: ReadinessItemId.plateSolver,
      title: 'Plate solver',
      detail:
          'No plate solver is configured. Install ASTAP (with a star '
          'catalog) or astrometry.net to enable centering and alignment.',
      level: ReadinessLevel.caution,
      fixRoute: _routePlateSolving,
      fixLabel: 'Set up plate solving',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.plateSolver,
    title: 'Plate solver',
    detail: 'Plate solver is installed and ready.',
    level: ReadinessLevel.ready,
  );
}

/// Dark library.
///
/// CAUTION when there is no matching dark coverage: imaging works, but
/// calibration will be limited until darks are captured for this
/// configuration. Routes to Settings → Dark Library.
ReadinessItem _buildDarkLibrary({required bool darkLibraryHasCoverage}) {
  if (!darkLibraryHasCoverage) {
    return const ReadinessItem(
      id: ReadinessItemId.darkLibrary,
      title: 'Dark library',
      detail:
          'No matching dark frames for your current camera settings. '
          'Capture darks for proper calibration.',
      level: ReadinessLevel.caution,
      fixRoute: _routeSettings,
      fixLabel: 'Open dark library',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.darkLibrary,
    title: 'Dark library',
    detail: 'Dark library has coverage for your current configuration.',
    level: ReadinessLevel.ready,
  );
}

/// Focus state.
///
/// CAUTION when focus has not been established this session: you can capture,
/// but frames may be soft until you run autofocus or set focus manually.
/// Routes to the Equipment screen (focuser controls).
ReadinessItem _buildFocusState({required bool focusKnown}) {
  if (!focusKnown) {
    return const ReadinessItem(
      id: ReadinessItemId.focusState,
      title: 'Focus',
      detail:
          'Focus has not been established yet. Run autofocus or set focus '
          'manually before imaging for sharp frames.',
      level: ReadinessLevel.caution,
      fixRoute: _routeEquipment,
      fixLabel: 'Adjust focus',
    );
  }
  return const ReadinessItem(
    id: ReadinessItemId.focusState,
    title: 'Focus',
    detail: 'Focus has been established.',
    level: ReadinessLevel.ready,
  );
}
