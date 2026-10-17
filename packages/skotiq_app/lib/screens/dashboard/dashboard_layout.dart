import 'package:flutter/foundation.dart';

/// Zone-based layout architecture for NINA-style command center design.
///
/// Layout structure:
/// - Primary: Main content area (live preview, capture controls) - 60%
/// - Secondary: Supporting info (sequence, guiding, equipment) - 40% resizable
/// - Tertiary: Bottom row compact widgets (mount, focus, weather)
enum DashboardZone {
  primary,
  secondary,
  tertiary,
}

extension DashboardZoneX on DashboardZone {
  String get storageKey {
    return switch (this) {
      DashboardZone.primary => 'primary',
      DashboardZone.secondary => 'secondary',
      DashboardZone.tertiary => 'tertiary',
    };
  }

  static DashboardZone fromStorageKey(String value) {
    return switch (value) {
      'primary' => DashboardZone.primary,
      'secondary' => DashboardZone.secondary,
      'tertiary' => DashboardZone.tertiary,
      _ => throw FormatException('Unknown dashboard zone: $value'),
    };
  }

  /// Get the default zone for a widget ID (used for migration from v2 layouts)
  static DashboardZone defaultForWidget(DashboardWidgetId widgetId) {
    return switch (widgetId) {
      // The Observatory Tonight grid is one flow, not three zones; `primary`
      // is the only zone it ever reports.
      DashboardWidgetId.tonightPreview => DashboardZone.primary,
      DashboardWidgetId.tonightEquipment => DashboardZone.primary,
      DashboardWidgetId.tonightGuiding => DashboardZone.primary,
      DashboardWidgetId.tonightProgress => DashboardZone.primary,
      DashboardWidgetId.tonightSafety => DashboardZone.primary,

      // Merged cockpit tiles live in the hero column.
      DashboardWidgetId.cockpitNowImaging => DashboardZone.primary,
      DashboardWidgetId.cockpitFrames => DashboardZone.primary,

      // Cockpit panels (live monitoring): hero column up top, supporting
      // telemetry down the right rail, opt-in extras stay in their natural
      // home so enabling them via Edit Dashboard lands them sensibly.
      DashboardWidgetId.cockpitTargetHeader => DashboardZone.primary,
      DashboardWidgetId.cockpitLiveFrame => DashboardZone.primary,
      DashboardWidgetId.cockpitExposureProgress => DashboardZone.primary,
      DashboardWidgetId.cockpitRecentFrames => DashboardZone.primary,
      DashboardWidgetId.cockpitFilterIntegration => DashboardZone.secondary,
      DashboardWidgetId.cockpitEquipmentTelemetry => DashboardZone.secondary,
      DashboardWidgetId.cockpitGuiding => DashboardZone.secondary,
      DashboardWidgetId.cockpitWeatherSafety => DashboardZone.secondary,
      DashboardWidgetId.cockpitSessionWarnings => DashboardZone.secondary,
      DashboardWidgetId.cockpitTriggerFeed => DashboardZone.secondary,
      DashboardWidgetId.cockpitScheduler => DashboardZone.secondary,
      DashboardWidgetId.cockpitCloudMotion => DashboardZone.secondary,
      DashboardWidgetId.cockpitAdaptiveConditions => DashboardZone.secondary,
      DashboardWidgetId.cockpitLightCurve => DashboardZone.secondary,
      DashboardWidgetId.cockpitObservatory => DashboardZone.secondary,
      DashboardWidgetId.cockpitSecondaryRig => DashboardZone.secondary,
      DashboardWidgetId.cockpitQuality => DashboardZone.secondary,
      DashboardWidgetId.cockpitSessionVitals => DashboardZone.secondary,
      DashboardWidgetId.cockpitSkyContext => DashboardZone.secondary,
      DashboardWidgetId.cockpitForensics => DashboardZone.secondary,
      DashboardWidgetId.cockpitNarrator => DashboardZone.secondary,
      DashboardWidgetId.cockpitMorningReport => DashboardZone.secondary,

      // Primary zone: main content area (hero widgets)
      DashboardWidgetId.livePreview => DashboardZone.primary,
      DashboardWidgetId.captureSettings => DashboardZone.primary,

      // Secondary zone: supporting information and controls
      DashboardWidgetId.sequenceStatus => DashboardZone.secondary,
      DashboardWidgetId.guiding => DashboardZone.secondary,
      DashboardWidgetId.equipmentStatus => DashboardZone.secondary,
      DashboardWidgetId.quickActions => DashboardZone.secondary,

      // Tertiary zone: compact status widgets
      DashboardWidgetId.mountControl => DashboardZone.tertiary,
      DashboardWidgetId.focus => DashboardZone.tertiary,
      DashboardWidgetId.weather => DashboardZone.tertiary,
      DashboardWidgetId.tonight => DashboardZone.tertiary,
      DashboardWidgetId.alerts => DashboardZone.tertiary,
      DashboardWidgetId.quickStats => DashboardZone.tertiary,
      DashboardWidgetId.storage => DashboardZone.tertiary,
    };
  }
}

enum DashboardWidgetId {
  // Observatory wave 3 — the five panels 06 §Tonight lays out in the grid.
  // They are registry tiles, not hard-coded children, so Edit layout can still
  // reorder, resize and hide them.
  tonightPreview,
  tonightEquipment,
  tonightGuiding,
  tonightProgress,
  tonightSafety,

  // Merged cockpit tiles (density pass 2026-06-01). These supersede the four
  // individual panels below and are the enabled-by-default monitoring surface.
  cockpitNowImaging,
  cockpitFrames,

  // Cockpit panels (transplanted from the Sequencer Run dashboard). These are
  // the live monitoring surface and are enabled by default (see defaultLayout).
  cockpitTargetHeader,
  cockpitLiveFrame,
  cockpitExposureProgress,
  cockpitRecentFrames,
  cockpitFilterIntegration,
  cockpitEquipmentTelemetry,
  cockpitGuiding,
  cockpitWeatherSafety,
  cockpitSessionWarnings,
  cockpitTriggerFeed,
  cockpitScheduler,
  cockpitCloudMotion,
  cockpitAdaptiveConditions,
  cockpitLightCurve,
  cockpitObservatory,
  cockpitSecondaryRig,

  // Wave: dashboard enrichment (v6). Quality + Frame Forensics registered from
  // their already-built Run dashboard panels; Session Vitals + Sky Context are
  // new cockpit panels. Quality ships enabled by default; the rest are opt-in.
  cockpitQuality,
  cockpitSessionVitals,
  cockpitSkyContext,
  cockpitForensics,

  // Night Narrator (v7). Live, plain-language interpretation of the session's
  // science data — the dashboard surface of the Narrator feed. Opt-in.
  cockpitNarrator,

  // Morning Report. Last night's accepted/rejected summary; taps through to
  // Session Review. Self-hides when there's no last session. Opt-in.
  cockpitMorningReport,

  // Legacy control/info cards. Kept for migration + power users, but disabled
  // by default now that the cockpit panels own the dashboard.
  livePreview,
  captureSettings,
  sequenceStatus,
  guiding,
  mountControl,
  equipmentStatus,
  weather,
  focus,
  alerts,
  quickActions,
  quickStats,
  tonight,
  storage,
}

extension DashboardWidgetIdX on DashboardWidgetId {
  String get storageKey {
    return switch (this) {
      DashboardWidgetId.tonightPreview => 'tonightPreview',
      DashboardWidgetId.tonightEquipment => 'tonightEquipment',
      DashboardWidgetId.tonightGuiding => 'tonightGuiding',
      DashboardWidgetId.tonightProgress => 'tonightProgress',
      DashboardWidgetId.tonightSafety => 'tonightSafety',
      DashboardWidgetId.cockpitNowImaging => 'cockpitNowImaging',
      DashboardWidgetId.cockpitFrames => 'cockpitFrames',
      DashboardWidgetId.cockpitTargetHeader => 'cockpitTargetHeader',
      DashboardWidgetId.cockpitLiveFrame => 'cockpitLiveFrame',
      DashboardWidgetId.cockpitExposureProgress => 'cockpitExposureProgress',
      DashboardWidgetId.cockpitRecentFrames => 'cockpitRecentFrames',
      DashboardWidgetId.cockpitFilterIntegration => 'cockpitFilterIntegration',
      DashboardWidgetId.cockpitEquipmentTelemetry =>
        'cockpitEquipmentTelemetry',
      DashboardWidgetId.cockpitGuiding => 'cockpitGuiding',
      DashboardWidgetId.cockpitWeatherSafety => 'cockpitWeatherSafety',
      DashboardWidgetId.cockpitSessionWarnings => 'cockpitSessionWarnings',
      DashboardWidgetId.cockpitTriggerFeed => 'cockpitTriggerFeed',
      DashboardWidgetId.cockpitScheduler => 'cockpitScheduler',
      DashboardWidgetId.cockpitCloudMotion => 'cockpitCloudMotion',
      DashboardWidgetId.cockpitAdaptiveConditions =>
        'cockpitAdaptiveConditions',
      DashboardWidgetId.cockpitLightCurve => 'cockpitLightCurve',
      DashboardWidgetId.cockpitObservatory => 'cockpitObservatory',
      DashboardWidgetId.cockpitSecondaryRig => 'cockpitSecondaryRig',
      DashboardWidgetId.cockpitQuality => 'cockpitQuality',
      DashboardWidgetId.cockpitSessionVitals => 'cockpitSessionVitals',
      DashboardWidgetId.cockpitSkyContext => 'cockpitSkyContext',
      DashboardWidgetId.cockpitForensics => 'cockpitForensics',
      DashboardWidgetId.cockpitNarrator => 'cockpitNarrator',
      DashboardWidgetId.cockpitMorningReport => 'cockpitMorningReport',
      DashboardWidgetId.livePreview => 'livePreview',
      DashboardWidgetId.captureSettings => 'captureSettings',
      DashboardWidgetId.sequenceStatus => 'sequenceStatus',
      DashboardWidgetId.guiding => 'guiding',
      DashboardWidgetId.mountControl => 'mountControl',
      DashboardWidgetId.equipmentStatus => 'equipmentStatus',
      DashboardWidgetId.weather => 'weather',
      DashboardWidgetId.focus => 'focus',
      DashboardWidgetId.alerts => 'alerts',
      DashboardWidgetId.quickActions => 'quickActions',
      DashboardWidgetId.quickStats => 'quickStats',
      DashboardWidgetId.tonight => 'tonight',
      DashboardWidgetId.storage => 'storage',
    };
  }

  static DashboardWidgetId fromStorageKey(String value) {
    return switch (value) {
      'tonightPreview' => DashboardWidgetId.tonightPreview,
      'tonightEquipment' => DashboardWidgetId.tonightEquipment,
      'tonightGuiding' => DashboardWidgetId.tonightGuiding,
      'tonightProgress' => DashboardWidgetId.tonightProgress,
      'tonightSafety' => DashboardWidgetId.tonightSafety,
      'cockpitNowImaging' => DashboardWidgetId.cockpitNowImaging,
      'cockpitFrames' => DashboardWidgetId.cockpitFrames,
      'cockpitTargetHeader' => DashboardWidgetId.cockpitTargetHeader,
      'cockpitLiveFrame' => DashboardWidgetId.cockpitLiveFrame,
      'cockpitExposureProgress' => DashboardWidgetId.cockpitExposureProgress,
      'cockpitRecentFrames' => DashboardWidgetId.cockpitRecentFrames,
      'cockpitFilterIntegration' => DashboardWidgetId.cockpitFilterIntegration,
      'cockpitEquipmentTelemetry' =>
        DashboardWidgetId.cockpitEquipmentTelemetry,
      'cockpitGuiding' => DashboardWidgetId.cockpitGuiding,
      'cockpitWeatherSafety' => DashboardWidgetId.cockpitWeatherSafety,
      'cockpitSessionWarnings' => DashboardWidgetId.cockpitSessionWarnings,
      'cockpitTriggerFeed' => DashboardWidgetId.cockpitTriggerFeed,
      'cockpitScheduler' => DashboardWidgetId.cockpitScheduler,
      'cockpitCloudMotion' => DashboardWidgetId.cockpitCloudMotion,
      'cockpitAdaptiveConditions' =>
        DashboardWidgetId.cockpitAdaptiveConditions,
      'cockpitLightCurve' => DashboardWidgetId.cockpitLightCurve,
      'cockpitObservatory' => DashboardWidgetId.cockpitObservatory,
      'cockpitSecondaryRig' => DashboardWidgetId.cockpitSecondaryRig,
      'cockpitQuality' => DashboardWidgetId.cockpitQuality,
      'cockpitSessionVitals' => DashboardWidgetId.cockpitSessionVitals,
      'cockpitSkyContext' => DashboardWidgetId.cockpitSkyContext,
      'cockpitForensics' => DashboardWidgetId.cockpitForensics,
      'cockpitNarrator' => DashboardWidgetId.cockpitNarrator,
      'cockpitMorningReport' => DashboardWidgetId.cockpitMorningReport,
      'livePreview' => DashboardWidgetId.livePreview,
      'captureSettings' => DashboardWidgetId.captureSettings,
      'sequenceStatus' => DashboardWidgetId.sequenceStatus,
      'guiding' => DashboardWidgetId.guiding,
      'mountControl' => DashboardWidgetId.mountControl,
      'equipmentStatus' => DashboardWidgetId.equipmentStatus,
      'weather' => DashboardWidgetId.weather,
      'focus' => DashboardWidgetId.focus,
      'alerts' => DashboardWidgetId.alerts,
      'quickActions' => DashboardWidgetId.quickActions,
      'quickStats' => DashboardWidgetId.quickStats,
      'tonight' => DashboardWidgetId.tonight,
      'storage' => DashboardWidgetId.storage,
      _ => throw FormatException('Unknown dashboard widget id: $value'),
    };
  }
}

enum DashboardTileSize {
  small,
  medium,
  large,
}

extension DashboardTileSizeX on DashboardTileSize {
  String get storageKey {
    return switch (this) {
      DashboardTileSize.small => 'small',
      DashboardTileSize.medium => 'medium',
      DashboardTileSize.large => 'large',
    };
  }

  String get label {
    return switch (this) {
      DashboardTileSize.small => 'Small',
      DashboardTileSize.medium => 'Medium',
      DashboardTileSize.large => 'Large',
    };
  }

  int get span {
    return switch (this) {
      DashboardTileSize.small => 1,
      DashboardTileSize.medium => 2,
      DashboardTileSize.large => 3,
    };
  }

  /// The tile's width in the Observatory 12-column grid (06 §Tonight).
  ///
  /// 06 only needs 8 (the live preview) and 4 (everything beside it); `small`
  /// gets 3 so the resize cycle a user drives from Edit layout still visibly
  /// changes something.
  int get columnSpan {
    return switch (this) {
      DashboardTileSize.small => 3,
      DashboardTileSize.medium => 4,
      DashboardTileSize.large => 8,
    };
  }

  DashboardTileSize next() {
    return switch (this) {
      DashboardTileSize.small => DashboardTileSize.medium,
      DashboardTileSize.medium => DashboardTileSize.large,
      DashboardTileSize.large => DashboardTileSize.small,
    };
  }

  static DashboardTileSize fromStorageKey(String value) {
    return switch (value) {
      'small' => DashboardTileSize.small,
      'medium' => DashboardTileSize.medium,
      'large' => DashboardTileSize.large,
      _ => throw FormatException('Unknown dashboard tile size: $value'),
    };
  }
}

@immutable
class DashboardTileConfig {
  final DashboardWidgetId widgetId;
  final DashboardTileSize size;
  final bool enabled;
  final int order;
  final DashboardZone zone;

  const DashboardTileConfig({
    required this.widgetId,
    required this.size,
    required this.enabled,
    required this.order,
    required this.zone,
  });

  DashboardTileConfig copyWith({
    DashboardWidgetId? widgetId,
    DashboardTileSize? size,
    bool? enabled,
    int? order,
    DashboardZone? zone,
  }) {
    return DashboardTileConfig(
      widgetId: widgetId ?? this.widgetId,
      size: size ?? this.size,
      enabled: enabled ?? this.enabled,
      order: order ?? this.order,
      zone: zone ?? this.zone,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': widgetId.storageKey,
      'size': size.storageKey,
      'enabled': enabled,
      'order': order,
      'zone': zone.storageKey,
    };
  }

  factory DashboardTileConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final size = json['size'];
    final enabled = json['enabled'];
    final order = json['order'];
    final zone = json['zone'];

    if (id is! String) {
      throw const FormatException('Dashboard tile id must be a string.');
    }
    if (size is! String) {
      throw const FormatException('Dashboard tile size must be a string.');
    }
    if (enabled is! bool) {
      throw const FormatException('Dashboard tile enabled must be a boolean.');
    }
    if (order is! int) {
      throw const FormatException('Dashboard tile order must be an integer.');
    }

    final widgetId = DashboardWidgetIdX.fromStorageKey(id);

    // Zone is optional for v2 migration - infer from widget ID if missing
    DashboardZone parsedZone;
    if (zone is String) {
      parsedZone = DashboardZoneX.fromStorageKey(zone);
    } else {
      parsedZone = DashboardZoneX.defaultForWidget(widgetId);
    }

    return DashboardTileConfig(
      widgetId: widgetId,
      size: DashboardTileSizeX.fromStorageKey(size),
      enabled: enabled,
      order: order,
      zone: parsedZone,
    );
  }
}

@immutable
class DashboardLayout {
  /// Schema version of a persisted layout. Bumped whenever the default tile
  /// set gains or retires tiles; `_migrateToCurrentVersion` is the authority on
  /// what a bump does to a stored layout.
  /// 7 = the Observatory Tonight grid (06 §Tonight). The five `tonight*` tiles
  /// become the default surface and the cockpit tiles they replace are
  /// force-disabled by the migration in `dashboard_layout_provider.dart`; a
  /// user who wants one back re-enables it from the widget picker.
  static const int currentVersion = 7;

  final int version;
  final List<DashboardTileConfig> tiles;

  /// Width of the secondary zone as a fraction of available space (0.25 to 0.5)
  final double secondaryZoneWidth;

  const DashboardLayout({
    required this.version,
    required this.tiles,
    this.secondaryZoneWidth = 0.4,
  });

  DashboardLayout copyWith({
    int? version,
    List<DashboardTileConfig>? tiles,
    double? secondaryZoneWidth,
  }) {
    return DashboardLayout(
      version: version ?? this.version,
      tiles: tiles ?? this.tiles,
      secondaryZoneWidth: secondaryZoneWidth ?? this.secondaryZoneWidth,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'tiles': tiles.map((tile) => tile.toJson()).toList(),
      'secondaryZoneWidth': secondaryZoneWidth,
    };
  }

  factory DashboardLayout.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final tiles = json['tiles'];
    final secondaryZoneWidth = json['secondaryZoneWidth'];

    if (version is! int) {
      throw const FormatException(
          'Dashboard layout version must be an integer.');
    }
    if (tiles is! List) {
      throw const FormatException('Dashboard layout tiles must be a list.');
    }

    final parsedTiles = tiles.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Dashboard tile entry must be an object.');
      }
      return DashboardTileConfig.fromJson(entry);
    }).toList();

    return DashboardLayout(
      version: version,
      tiles: parsedTiles,
      secondaryZoneWidth: (secondaryZoneWidth is num)
          ? secondaryZoneWidth.toDouble().clamp(0.25, 0.5)
          : 0.4,
    ).normalize();
  }

  DashboardLayout normalize() {
    final sorted = [...tiles]..sort((a, b) => a.order.compareTo(b.order));
    final ids = <DashboardWidgetId>{};
    for (final tile in sorted) {
      if (!ids.add(tile.widgetId)) {
        throw FormatException(
            'Duplicate dashboard tile: ${tile.widgetId.storageKey}');
      }
    }
    final normalized = <DashboardTileConfig>[];
    for (var i = 0; i < sorted.length; i++) {
      normalized.add(sorted[i].copyWith(order: i));
    }
    return DashboardLayout(
      version: version,
      tiles: normalized,
      secondaryZoneWidth: secondaryZoneWidth,
    );
  }

  DashboardLayout mergeWithDefaults(DashboardLayout defaults) {
    final existingIds = tiles.map((tile) => tile.widgetId).toSet();
    final merged = [...tiles];

    for (final tile in defaults.tiles) {
      if (!existingIds.contains(tile.widgetId)) {
        merged.add(tile.copyWith(order: merged.length));
      }
    }

    return DashboardLayout(
      version: defaults.version,
      tiles: merged,
      secondaryZoneWidth: secondaryZoneWidth,
    ).normalize();
  }

  /// Get tiles for a specific zone, sorted by order
  List<DashboardTileConfig> tilesForZone(DashboardZone zone) {
    return tiles.where((t) => t.zone == zone && t.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  static DashboardLayout defaultLayout() {
    final tiles = <DashboardTileConfig>[
      // The Observatory grid (06 §Tonight): live preview c8, then equipment,
      // guiding, progress and safety at c4 each. `order` IS the reading order
      // of the grid, and `zone` is vestigial here — the Tonight grid is one
      // flow — so every default tile sits in `primary`.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonightPreview,
        size: DashboardTileSize.large,
        enabled: true,
        order: 0,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonightEquipment,
        size: DashboardTileSize.medium,
        enabled: true,
        order: 1,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonightGuiding,
        size: DashboardTileSize.medium,
        enabled: true,
        order: 2,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonightProgress,
        size: DashboardTileSize.medium,
        enabled: true,
        order: 3,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonightSafety,
        size: DashboardTileSize.medium,
        enabled: true,
        order: 4,
        zone: DashboardZone.primary,
      ),

      // The cockpit tiles the five above replace. Still registered, still
      // reachable from the widget picker, off by default.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitNowImaging,
        size: DashboardTileSize.large,
        enabled: false,
        order: 5,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitFrames,
        size: DashboardTileSize.large,
        enabled: false,
        order: 6,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitGuiding,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 7,
        zone: DashboardZone.primary,
      ),

      // Secondary zone (right rail): supporting telemetry.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitEquipmentTelemetry,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 3,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitWeatherSafety,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 4,
        zone: DashboardZone.secondary,
      ),
      // Quality joins the dense right-rail default (v6): frame accept/reject
      // rate + HFR trend is core monitoring, and the panel hides itself until
      // grading produces events, so an idle dashboard stays clean.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitQuality,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 5,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitTriggerFeed,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 6,
        zone: DashboardZone.secondary,
      ),

      // Superseded cockpit panels — the four individual panels the merged
      // tiles replace. Present (so power users can re-enable) but disabled.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitTargetHeader,
        size: DashboardTileSize.large,
        enabled: false,
        order: 7,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitLiveFrame,
        size: DashboardTileSize.large,
        enabled: false,
        order: 8,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitExposureProgress,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 9,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitRecentFrames,
        size: DashboardTileSize.large,
        enabled: false,
        order: 10,
        zone: DashboardZone.primary,
      ),

      // Other cockpit panels disabled by default — opt-in via edit dashboard.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitSessionWarnings,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 11,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitFilterIntegration,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 12,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitScheduler,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 13,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitCloudMotion,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 14,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitAdaptiveConditions,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 15,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitLightCurve,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 16,
        zone: DashboardZone.secondary,
      ),

      // New v6 cockpit panels — opt-in. Session Vitals (run efficiency +
      // counters) and Sky Context (altitude/airmass/moon/darkness) join the
      // right rail; both degrade to a slim idle row when there's no run/target.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitSessionVitals,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 17,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitSkyContext,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 18,
        zone: DashboardZone.secondary,
      ),

      // Legacy control/info cards — retained for power users + migration,
      // disabled by default now that the cockpit panels own the dashboard.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.livePreview,
        size: DashboardTileSize.large,
        enabled: false,
        order: 19,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.captureSettings,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 20,
        zone: DashboardZone.primary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.sequenceStatus,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 21,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.guiding,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 22,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.equipmentStatus,
        size: DashboardTileSize.small,
        enabled: false,
        order: 23,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.quickActions,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 24,
        zone: DashboardZone.secondary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.mountControl,
        size: DashboardTileSize.small,
        enabled: false,
        order: 25,
        zone: DashboardZone.tertiary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.focus,
        size: DashboardTileSize.small,
        enabled: false,
        order: 26,
        zone: DashboardZone.tertiary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.weather,
        size: DashboardTileSize.small,
        enabled: false,
        order: 27,
        zone: DashboardZone.tertiary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.tonight,
        size: DashboardTileSize.small,
        enabled: false,
        order: 28,
        zone: DashboardZone.tertiary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.alerts,
        size: DashboardTileSize.small,
        enabled: false,
        order: 29,
        zone: DashboardZone.tertiary,
      ),
      // Quick Stats disabled - redundant with Command Bar stats
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.quickStats,
        size: DashboardTileSize.small,
        enabled: false,
        order: 30,
        zone: DashboardZone.tertiary,
      ),
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.storage,
        size: DashboardTileSize.small,
        enabled: false,
        order: 31,
        zone: DashboardZone.tertiary,
      ),

      // Observatory / dome telemetry. Disabled by default because most rigs
      // are portable (no dome/roof/flat-panel); operators with an observatory
      // enable it via Edit Dashboard. Lives in the right-rail telemetry zone.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitObservatory,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 32,
        zone: DashboardZone.secondary,
      ),

      // Dual-rig secondary camera control. Disabled by default because most
      // setups are single-camera; piggyback operators enable it via Edit
      // Dashboard.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitSecondaryRig,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 33,
        zone: DashboardZone.secondary,
      ),

      // Frame Forensics — opt-in rejection forensics grouped by likely cause.
      // Disabled by default; hides itself until rejections exist.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitForensics,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 34,
        zone: DashboardZone.secondary,
      ),

      // Night Narrator (v7) — live plain-language interpretation of the
      // session's science data. Opt-in (disabled by default) so existing dense
      // dashboards aren't reshuffled; degrades to its watching empty state when
      // no events have fired yet.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitNarrator,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 35,
        zone: DashboardZone.secondary,
      ),

      // Morning Report — last night's accepted/rejected summary, taps through
      // to Session Review. Opt-in; self-hides when there's no last session.
      const DashboardTileConfig(
        widgetId: DashboardWidgetId.cockpitMorningReport,
        size: DashboardTileSize.medium,
        enabled: false,
        order: 36,
        zone: DashboardZone.secondary,
      ),
    ];

    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      // `order` is renumbered from list position rather than written per
      // entry: with the Observatory tiles inserted at the head, hand-written
      // orders collided, and a duplicate order makes `reorder` move the wrong
      // tile.
      tiles: <DashboardTileConfig>[
        for (var i = 0; i < tiles.length; i++) tiles[i].copyWith(order: i),
      ],
      secondaryZoneWidth: 0.4,
    );
  }
}
