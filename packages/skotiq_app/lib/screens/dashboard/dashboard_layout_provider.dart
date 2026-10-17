import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'dashboard_layout.dart';

const _dashboardLayoutKey = 'dashboard_layout_v1';

class DashboardLayoutNotifier extends AsyncNotifier<DashboardLayout> {
  @override
  Future<DashboardLayout> build() async {
    final dao = ref.read(settingsDaoProvider);
    final stored = await dao.getSetting(_dashboardLayoutKey);

    if (stored == null || stored.trim().isEmpty) {
      return DashboardLayout.defaultLayout();
    }

    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Dashboard layout must be a JSON object.');
      }
      final layout = DashboardLayout.fromJson(decoded);

      // Migrate older layouts onto the current default. This fires for v3/v4/v5
      // users (currentVersion is 6), moving everyone onto the dense cockpit
      // default while preserving their show/hide choices where ids overlap.
      // New ids (the merged cockpit tiles, plus the v6 quality/session-vitals/
      // sky-context/forensics additions) use their default enabled state; the
      // four superseded panels are force-disabled (see _migrateToCurrentVersion).
      if (layout.version < DashboardLayout.currentVersion) {
        final migrated = _migrateToCurrentVersion(layout);
        await _persist(migrated);
        return migrated;
      }

      return layout.mergeWithDefaults(DashboardLayout.defaultLayout());
    } catch (error) {
      throw FormatException('Failed to parse dashboard layout: $error');
    }
  }

  /// Migrate an older layout onto the current default by rebuilding tiles from
  /// `defaultLayout()` while preserving each tile's enabled/disabled state by
  /// id. Tiles present in the stored layout but not in the current default drop
  /// out (correct — they are no longer part of the shipped layout); new tiles
  /// in the default keep their default enabled state.
  DashboardLayout _migrateToCurrentVersion(DashboardLayout oldLayout) {
    final defaults = DashboardLayout.defaultLayout();
    final enabledMap = {for (final t in oldLayout.tiles) t.widgetId: t.enabled};

    // Preserve user's enabled/disabled choices, use default zone assignments.
    // Two force-disable exceptions during migration:
    //   * Quick Stats — redundant with the Command Bar stats.
    //   * The four cockpit panels superseded by the merged `cockpitNowImaging`
    //     and `cockpitFrames` tiles; without this a stored layout holding the
    //     old panels enabled would render both sets.
    // Ids absent from a stored layout take their default enabled state, so the
    // net result matches defaultLayout().
    //   * The cockpit tiles the Observatory Tonight grid replaces (v7): the
    //     five `tonight*` panels say the same things in the layout 06 specifies,
    //     and leaving the old ones enabled would render both sets. They stay in
    //     the widget picker for anyone who wants one back.
    const forceDisabled = <DashboardWidgetId>{
      DashboardWidgetId.quickStats,
      DashboardWidgetId.cockpitTargetHeader,
      DashboardWidgetId.cockpitLiveFrame,
      DashboardWidgetId.cockpitExposureProgress,
      DashboardWidgetId.cockpitRecentFrames,
      DashboardWidgetId.cockpitNowImaging,
      DashboardWidgetId.cockpitFrames,
      DashboardWidgetId.cockpitGuiding,
      DashboardWidgetId.cockpitEquipmentTelemetry,
      DashboardWidgetId.cockpitWeatherSafety,
      DashboardWidgetId.cockpitQuality,
      DashboardWidgetId.cockpitTriggerFeed,
      DashboardWidgetId.cockpitLightCurve,
    };

    final tiles = defaults.tiles.map((tile) {
      var wasEnabled = enabledMap[tile.widgetId];

      if (forceDisabled.contains(tile.widgetId)) {
        wasEnabled = false;
      }

      return tile.copyWith(enabled: wasEnabled ?? tile.enabled);
    }).toList();

    return DashboardLayout(
      version: DashboardLayout.currentVersion,
      tiles: tiles,
      secondaryZoneWidth: 0.4,
    );
  }

  Future<void> resetLayout() async {
    final defaults = DashboardLayout.defaultLayout();
    await _persist(defaults);
    state = AsyncData(defaults);
  }

  Future<void> reorder(
      DashboardWidgetId dragged, DashboardWidgetId target) async {
    final layout = state.value;
    if (layout == null) {
      throw StateError('Dashboard layout not loaded yet.');
    }

    final tiles = [...layout.tiles];
    final fromIndex = tiles.indexWhere((tile) => tile.widgetId == dragged);
    final toIndex = tiles.indexWhere((tile) => tile.widgetId == target);

    if (fromIndex == -1 || toIndex == -1) {
      throw StateError('Dashboard layout missing tile for reorder.');
    }
    if (fromIndex == toIndex) {
      return;
    }

    final moved = tiles.removeAt(fromIndex);
    tiles.insert(toIndex, moved);

    final updated = layout.copyWith(tiles: tiles).normalize();
    await _persist(updated);
    state = AsyncData(updated);
  }

  /// Move a tile to a different zone
  Future<void> setTileZone(DashboardWidgetId id, DashboardZone zone) async {
    final layout = state.value;
    if (layout == null) {
      throw StateError('Dashboard layout not loaded yet.');
    }

    final tiles = layout.tiles
        .map((tile) => tile.widgetId == id ? tile.copyWith(zone: zone) : tile)
        .toList();

    if (!tiles.any((tile) => tile.widgetId == id)) {
      throw StateError('Dashboard layout missing tile for zone change.');
    }

    final updated = layout.copyWith(tiles: tiles).normalize();
    await _persist(updated);
    state = AsyncData(updated);
  }

  /// Update the secondary zone width (0.25 to 0.5)
  Future<void> setSecondaryZoneWidth(double width) async {
    final layout = state.value;
    if (layout == null) {
      throw StateError('Dashboard layout not loaded yet.');
    }

    final clampedWidth = width.clamp(0.25, 0.5);
    final updated = layout.copyWith(secondaryZoneWidth: clampedWidth);
    await _persist(updated);
    state = AsyncData(updated);
  }

  Future<void> setTileSize(DashboardWidgetId id, DashboardTileSize size) async {
    final layout = state.value;
    if (layout == null) {
      throw StateError('Dashboard layout not loaded yet.');
    }

    final tiles = layout.tiles
        .map((tile) => tile.widgetId == id ? tile.copyWith(size: size) : tile)
        .toList();

    if (!tiles.any((tile) => tile.widgetId == id)) {
      throw StateError('Dashboard layout missing tile for resize.');
    }

    final updated = layout.copyWith(tiles: tiles).normalize();
    await _persist(updated);
    state = AsyncData(updated);
  }

  Future<void> setTileEnabled(DashboardWidgetId id, bool enabled) async {
    final layout = state.value;
    if (layout == null) {
      throw StateError('Dashboard layout not loaded yet.');
    }

    final tiles = layout.tiles
        .map((tile) =>
            tile.widgetId == id ? tile.copyWith(enabled: enabled) : tile)
        .toList();

    if (!tiles.any((tile) => tile.widgetId == id)) {
      throw StateError('Dashboard layout missing tile for enable.');
    }

    final updated = layout.copyWith(tiles: tiles).normalize();
    await _persist(updated);
    state = AsyncData(updated);
  }

  Future<void> _persist(DashboardLayout layout) async {
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(_dashboardLayoutKey, jsonEncode(layout.toJson()));
  }
}

// Why keep-alive (not autoDispose): the dashboard layout is a user
// preference persisted to the settings DAO; the async build() reads from
// SQLite and migrates older layouts onto the current version. Disposing on
// navigation would force
// every revisit (which happens on every app launch and tab switch) to
// re-run that I/O + migration, causing a visible flash of the default
// layout while loading. Memory cost is trivial (a single DashboardLayout
// value object), and writes flow through this notifier so a single
// authoritative copy is correct.
final dashboardLayoutProvider =
    AsyncNotifierProvider<DashboardLayoutNotifier, DashboardLayout>(() {
  return DashboardLayoutNotifier();
});

/// True while the dashboard is showing the standby briefing instead of the
/// arrangeable cockpit tiles: nothing connected, nothing loaded, nothing
/// running.
///
/// Shared with the header actions so the two cannot disagree about which
/// surface "Edit Dashboard" is offering to arrange.
final dashboardStandbyProvider = Provider<bool>((ref) {
  final executionState = ref.watch(sequenceExecutionStateProvider);
  // Terminal states count as inactive: after a completed or failed run the
  // executor never returns to `idle` on its own, and requiring exactly `idle`
  // would strand a user who has since unloaded and disconnected on a dead
  // cockpit instead of the briefing.
  final executionInactive = executionState == SequenceExecutionState.idle ||
      executionState == SequenceExecutionState.completed ||
      executionState == SequenceExecutionState.failed;
  if (!executionInactive) return false;
  if (ref.watch(sessionStateProvider.select((s) => s.isCapturing)))
    return false;

  bool connected(ProviderListenable<DeviceConnectionState> state) =>
      ref.watch(state) == DeviceConnectionState.connected;
  if (connected(cameraStateProvider.select((s) => s.connectionState)) ||
      connected(mountStateProvider.select((s) => s.connectionState)) ||
      connected(guiderStateProvider.select((s) => s.connectionState)) ||
      connected(focuserStateProvider.select((s) => s.connectionState))) {
    return false;
  }

  final sequence = ref.watch(currentSequenceProvider);
  final hasLoadedSequence = sequence != null &&
      (sequence.targetHeaders.isNotEmpty || sequence.totalExposures > 0);
  return !hasLoadedSequence;
});
