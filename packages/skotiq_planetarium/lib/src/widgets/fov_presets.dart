import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../coordinate_system.dart';
import '../services/survey_image_service.dart';

/// A persistent, equipment-derived field-of-view framing preset.
///
/// A preset captures one imaging rig — a telescope focal length plus a camera
/// sensor (physical width/height in mm and pixel size) — from which the angular
/// field of view (degrees) and image scale (arcsec/px) are *computed*, never
/// stored. Several presets can be shown on the sky at once, each with its own
/// position angle and (optionally) a center offset from the view center, so the
/// user can compare rigs and frame a target before committing a sequence.
///
/// The FOV / image-scale math is delegated to [FOVCalculator] so this stays the
/// single source of truth shared with the rest of the planetarium (and matches
/// the app's Framing `OpticalConfig` formulas, which are the same
/// `2·atan(sensor / 2f)` / `206265·pixel/f` relations).
@immutable
class FovPreset {
  /// Stable identifier, unique within the preset collection. Used as the React-
  /// style key for list reconciliation and to address a preset for edits.
  final String id;

  /// Human-readable label, e.g. "ASI2600 + ED80".
  final String name;

  /// Effective telescope focal length in millimeters (already including any
  /// reducer/Barlow the user has folded in).
  final double focalLengthMm;

  /// Camera sensor width in millimeters.
  final double sensorWidthMm;

  /// Camera sensor height in millimeters.
  final double sensorHeightMm;

  /// Camera pixel pitch in microns. Drives the arcsec/px image scale.
  final double pixelSizeMicrons;

  /// Position angle of the sensor's long axis, in degrees, measured from the
  /// view's "up" direction. This is the camera rotation the user will dial in
  /// on a rotator, so it persists with the preset.
  final double positionAngleDeg;

  /// Stroke color for the overlay. Schematic, high-contrast hues read best over
  /// the dark sky canvas.
  final Color color;

  /// Whether this preset is currently drawn on the sky.
  final bool visible;

  /// Optional sky position this overlay is pinned to. When null the overlay is
  /// drawn at the current view center (it "follows" the view); when set it is
  /// anchored to a fixed RA/Dec (e.g. snapped to a selected target) and stays
  /// put as the view pans.
  final CelestialCoordinate? center;

  const FovPreset({
    required this.id,
    required this.name,
    required this.focalLengthMm,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
    required this.pixelSizeMicrons,
    this.positionAngleDeg = 0,
    this.color = const Color(0xFF00E676),
    this.visible = true,
    this.center,
  });

  /// Build a preset from a planetarium [CameraSensorSpecs] + [TelescopeSpecs]
  /// pair (the bundled common-equipment catalog), applying an optional focal
  /// reducer/Barlow [focalMultiplier].
  factory FovPreset.fromEquipment({
    required String id,
    required CameraSensorSpecs camera,
    required TelescopeSpecs telescope,
    double focalMultiplier = 1.0,
    double positionAngleDeg = 0,
    Color color = const Color(0xFF00E676),
    String? name,
  }) {
    return FovPreset(
      id: id,
      name: name ?? '${camera.name} + ${telescope.name}',
      focalLengthMm: telescope.focalLengthMm * focalMultiplier,
      sensorWidthMm: camera.widthMm,
      sensorHeightMm: camera.heightMm,
      pixelSizeMicrons: camera.pixelSizeMicrons,
      positionAngleDeg: positionAngleDeg,
      color: color,
    );
  }

  /// Computed field of view (width, height) in degrees, or null if the optics
  /// are degenerate (zero focal length).
  (double width, double height)? get fovDegrees {
    if (focalLengthMm <= 0) return null;
    return FOVCalculator.calculateFOV(
      sensorWidthMm: sensorWidthMm,
      sensorHeightMm: sensorHeightMm,
      focalLengthMm: focalLengthMm,
    );
  }

  /// Computed image scale in arcseconds per pixel, or null if degenerate.
  double? get imageScaleArcsecPerPx {
    if (focalLengthMm <= 0) return null;
    return FOVCalculator.calculateImageScale(
      pixelSizeMicrons: pixelSizeMicrons,
      focalLengthMm: focalLengthMm,
    );
  }

  FovPreset copyWith({
    String? name,
    double? focalLengthMm,
    double? sensorWidthMm,
    double? sensorHeightMm,
    double? pixelSizeMicrons,
    double? positionAngleDeg,
    Color? color,
    bool? visible,
    CelestialCoordinate? center,
    bool clearCenter = false,
  }) {
    return FovPreset(
      id: id,
      name: name ?? this.name,
      focalLengthMm: focalLengthMm ?? this.focalLengthMm,
      sensorWidthMm: sensorWidthMm ?? this.sensorWidthMm,
      sensorHeightMm: sensorHeightMm ?? this.sensorHeightMm,
      pixelSizeMicrons: pixelSizeMicrons ?? this.pixelSizeMicrons,
      positionAngleDeg: positionAngleDeg ?? this.positionAngleDeg,
      color: color ?? this.color,
      visible: visible ?? this.visible,
      center: clearCenter ? null : (center ?? this.center),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'focalLengthMm': focalLengthMm,
    'sensorWidthMm': sensorWidthMm,
    'sensorHeightMm': sensorHeightMm,
    'pixelSizeMicrons': pixelSizeMicrons,
    'positionAngleDeg': positionAngleDeg,
    // Store ARGB so the schematic hue round-trips exactly.
    'color': color.toARGB32(),
    'visible': visible,
    if (center != null) 'centerRaHours': center!.ra,
    if (center != null) 'centerDecDeg': center!.dec,
  };

  /// Reconstruct a preset from [toJson] output. Returns null when a required
  /// numeric field is missing or unparseable so a single corrupt entry can be
  /// dropped without discarding the whole collection.
  static FovPreset? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final focal = (json['focalLengthMm'] as num?)?.toDouble();
    final w = (json['sensorWidthMm'] as num?)?.toDouble();
    final h = (json['sensorHeightMm'] as num?)?.toDouble();
    final px = (json['pixelSizeMicrons'] as num?)?.toDouble();
    if (id is! String ||
        focal == null ||
        w == null ||
        h == null ||
        px == null) {
      return null;
    }
    final raHours = (json['centerRaHours'] as num?)?.toDouble();
    final decDeg = (json['centerDecDeg'] as num?)?.toDouble();
    return FovPreset(
      id: id,
      name: json['name'] as String? ?? 'Preset',
      focalLengthMm: focal,
      sensorWidthMm: w,
      sensorHeightMm: h,
      pixelSizeMicrons: px,
      positionAngleDeg: (json['positionAngleDeg'] as num?)?.toDouble() ?? 0,
      color: Color((json['color'] as num?)?.toInt() ?? 0xFF00E676),
      visible: json['visible'] as bool? ?? true,
      center: (raHours != null && decDeg != null)
          ? CelestialCoordinate(ra: raHours, dec: decDeg)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FovPreset &&
      other.id == id &&
      other.name == name &&
      other.focalLengthMm == focalLengthMm &&
      other.sensorWidthMm == sensorWidthMm &&
      other.sensorHeightMm == sensorHeightMm &&
      other.pixelSizeMicrons == pixelSizeMicrons &&
      other.positionAngleDeg == positionAngleDeg &&
      other.color == color &&
      other.visible == visible &&
      other.center?.ra == center?.ra &&
      other.center?.dec == center?.dec;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    focalLengthMm,
    sensorWidthMm,
    sensorHeightMm,
    pixelSizeMicrons,
    positionAngleDeg,
    color,
    visible,
    center?.ra,
    center?.dec,
  );
}

/// The collection of FOV framing presets plus which one is "active" (the target
/// of preset-level edits and the one drag/rotate gestures on the sky affect).
@immutable
class FovPresetsState {
  final List<FovPreset> presets;

  /// Id of the active preset, or null when none is selected. Always refers to a
  /// preset present in [presets] (the notifier keeps this invariant).
  final String? activeId;

  const FovPresetsState({this.presets = const [], this.activeId});

  FovPreset? get active {
    if (activeId == null) return null;
    for (final p in presets) {
      if (p.id == activeId) return p;
    }
    return null;
  }

  FovPresetsState copyWith({
    List<FovPreset>? presets,
    String? activeId,
    bool clearActive = false,
  }) {
    return FovPresetsState(
      presets: presets ?? this.presets,
      activeId: clearActive ? null : (activeId ?? this.activeId),
    );
  }

  /// Serialize the whole collection to a JSON string for host persistence.
  String toJsonString() => jsonEncode({
    'activeId': activeId,
    'presets': presets.map((p) => p.toJson()).toList(),
  });

  /// Parse a collection previously produced by [toJsonString]. Malformed input
  /// (or individual malformed presets) is tolerated: a bad blob yields an empty
  /// collection rather than throwing, so a corrupt persisted value can never
  /// brick the planetarium.
  static FovPresetsState fromJsonString(String source) {
    if (source.isEmpty) return const FovPresetsState();
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) return const FovPresetsState();
      final rawList = decoded['presets'];
      final presets = <FovPreset>[];
      if (rawList is List) {
        for (final entry in rawList) {
          if (entry is Map<String, dynamic>) {
            final preset = FovPreset.fromJson(entry);
            if (preset != null) presets.add(preset);
          }
        }
      }
      final rawActive = decoded['activeId'];
      final activeId =
          (rawActive is String && presets.any((p) => p.id == rawActive))
          ? rawActive
          : null;
      return FovPresetsState(presets: presets, activeId: activeId);
    } on FormatException {
      return const FovPresetsState();
    }
  }
}

/// Owns the FOV preset collection.
///
/// State is held in-memory; the host app persists it by listening to this
/// notifier and writing [FovPresetsState.toJsonString] to durable storage, then
/// rehydrating with [hydrate] on startup. Keeping persistence out of the
/// planetarium package preserves its zero-platform-dependency design (no
/// `shared_preferences`) while still being fully wired in the app.
class FovPresetsNotifier extends StateNotifier<FovPresetsState> {
  FovPresetsNotifier() : super(const FovPresetsState());

  /// Replace the entire collection from persisted JSON. Used once on startup;
  /// no-op for an empty/blank source so a fresh install keeps the default
  /// (empty) collection.
  void hydrate(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return;
    state = FovPresetsState.fromJsonString(jsonString);
  }

  /// Add a preset and make it active.
  void add(FovPreset preset) {
    state = state.copyWith(
      presets: [...state.presets, preset],
      activeId: preset.id,
    );
  }

  /// Replace a preset (matched by id) in place, preserving order.
  void update(FovPreset preset) {
    final next = [
      for (final p in state.presets) p.id == preset.id ? preset : p,
    ];
    state = state.copyWith(presets: next);
  }

  /// Remove a preset by id, clearing the active selection if it was the one
  /// removed.
  void remove(String id) {
    final next = state.presets.where((p) => p.id != id).toList();
    state = FovPresetsState(
      presets: next,
      activeId: state.activeId == id ? null : state.activeId,
    );
  }

  /// Mark [id] as the active preset (no-op if it is not present).
  void setActive(String id) {
    if (!state.presets.any((p) => p.id == id)) return;
    state = state.copyWith(activeId: id);
  }

  /// Toggle a preset's visibility on the sky.
  void toggleVisible(String id) {
    final next = [
      for (final p in state.presets)
        p.id == id ? p.copyWith(visible: !p.visible) : p,
    ];
    state = state.copyWith(presets: next);
  }

  /// Set the active preset's position angle (degrees), normalized to [0, 360).
  void setActivePositionAngle(double degrees) {
    final active = state.active;
    if (active == null) return;
    final normalized = degrees % 360;
    update(
      active.copyWith(
        positionAngleDeg: normalized < 0 ? normalized + 360 : normalized,
      ),
    );
  }

  /// Pin the active preset to a fixed sky position (e.g. snap-to-target).
  void setActiveCenter(CelestialCoordinate center) {
    final active = state.active;
    if (active == null) return;
    update(active.copyWith(center: center));
  }

  /// Un-pin the active preset so it follows the view center again.
  void clearActiveCenter() {
    final active = state.active;
    if (active == null) return;
    update(active.copyWith(clearCenter: true));
  }
}

/// Provider for the FOV preset collection. Planetarium-local (in-memory);
/// persistence is layered on by the host app.
final fovPresetsProvider =
    StateNotifierProvider<FovPresetsNotifier, FovPresetsState>((ref) {
      return FovPresetsNotifier();
    });
