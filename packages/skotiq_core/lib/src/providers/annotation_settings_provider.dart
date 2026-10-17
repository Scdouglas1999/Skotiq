import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/annotation_settings.dart';
import '../services/logging_service.dart';
import 'database_provider.dart';

/// Built-in annotation presets
const builtInAnnotationPresets = <AnnotationPreset>[
  AnnotationPreset(
    name: 'Deep Field',
    visibleTypes: {AnnotationObjectFilter.galaxies},
    minMagnitude: 10.0,
    magnitudeCutoff: 18.0,
    showLabels: true,
    showMagnitudes: true,
    isBuiltIn: true,
  ),
  AnnotationPreset(
    name: 'Wide Field',
    visibleTypes: {
      AnnotationObjectFilter.galaxies,
      AnnotationObjectFilter.nebulae,
      AnnotationObjectFilter.starClusters,
      AnnotationObjectFilter.planetaryNebulae,
    },
    minMagnitude: -5.0,
    magnitudeCutoff: 12.0,
    showLabels: true,
    showMagnitudes: false,
    isBuiltIn: true,
  ),
  AnnotationPreset(
    name: 'Star Field',
    visibleTypes: {AnnotationObjectFilter.stars},
    minMagnitude: -5.0,
    magnitudeCutoff: 15.0,
    showLabels: false,
    showMagnitudes: false,
    isBuiltIn: true,
  ),
];

/// Provider for annotation display settings (persisted to database)
final annotationSettingsProvider =
    AsyncNotifierProvider<AnnotationSettingsNotifier, AnnotationSettings>(() {
      return AnnotationSettingsNotifier();
    });

/// Provider for annotation marker styles (persisted to database)
final annotationMarkerStyleProvider =
    AsyncNotifierProvider<AnnotationMarkerStyleNotifier, AnnotationMarkerStyle>(
      () {
        return AnnotationMarkerStyleNotifier();
      },
    );

/// Provider for tracking if mouse is hovering over image
final annotationHoverStateProvider = StateProvider<bool>((ref) => false);

/// Notifier for annotation settings with database persistence
class AnnotationSettingsNotifier extends AsyncNotifier<AnnotationSettings> {
  static const _settingsKey = 'annotation_settings';
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<AnnotationSettings> build() async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = await dao.getSetting(_settingsKey);

    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        return AnnotationSettings.fromJson(json);
      } catch (e, stackTrace) {
        ref
            .read(loggingServiceProvider)
            .error(
              'Failed to decode annotation settings: $e',
              source: 'AnnotationSettingsNotifier',
            );
        Error.throwWithStackTrace(
          StateError('Annotation settings are corrupt: $e'),
          stackTrace,
        );
      }
    }
    return const AnnotationSettings();
  }

  Future<void> _save(AnnotationSettings settings) async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = jsonEncode(settings.toJson());
    await dao.setSetting(_settingsKey, jsonStr);
    if (!identical(ref.read(settingsDaoProvider), dao)) {
      throw StateError(
        'The settings database changed while saving annotation settings.',
      );
    }
  }

  Future<void> _update(
    AnnotationSettings Function(AnnotationSettings current) change,
  ) {
    final operation = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Annotation settings are not loaded; refusing to overwrite them '
          'with defaults.',
        );
      }
      final updated = change(current);
      await _save(updated);
      state = AsyncData(updated);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> setEnabled(bool enabled) =>
      _update((current) => current.copyWith(enabled: enabled));

  Future<void> setMagnitudeCutoff(double magnitude) => _update(
    (current) => current.copyWith(magnitudeCutoff: magnitude.clamp(0.0, 25.0)),
  );

  Future<void> setMinMagnitude(double magnitude) => _update(
    (current) => current.copyWith(minMagnitude: magnitude.clamp(-10.0, 20.0)),
  );

  Future<void> toggleObjectType(AnnotationObjectFilter type) =>
      _update((current) {
        final types = Set<AnnotationObjectFilter>.from(current.visibleTypes);
        if (!types.remove(type)) types.add(type);
        return current.copyWith(visibleTypes: types);
      });

  Future<void> setObjectTypes(Set<AnnotationObjectFilter> types) => _update(
    (current) =>
        current.copyWith(visibleTypes: Set<AnnotationObjectFilter>.from(types)),
  );

  Future<void> setShowLabels(bool show) =>
      _update((current) => current.copyWith(showLabels: show));

  Future<void> setShowMagnitudes(bool show) =>
      _update((current) => current.copyWith(showMagnitudes: show));

  Future<void> setFadeWhenNotHovering(bool fade) =>
      _update((current) => current.copyWith(fadeWhenNotHovering: fade));

  Future<void> setHoverOpacity(double opacity) => _update(
    (current) => current.copyWith(hoverOpacity: opacity.clamp(0.0, 1.0)),
  );

  Future<void> setIdleOpacity(double opacity) => _update(
    (current) => current.copyWith(idleOpacity: opacity.clamp(0.0, 1.0)),
  );

  Future<void> setFadeAnimationMs(int ms) => _update(
    (current) => current.copyWith(fadeAnimationMs: ms.clamp(0, 2000)),
  );

  Future<void> setClickToIdentify(bool enabled) =>
      _update((current) => current.copyWith(clickToIdentify: enabled));

  Future<void> setClickSearchRadius(double arcsec) => _update(
    (current) =>
        current.copyWith(clickSearchRadiusArcsec: arcsec.clamp(1.0, 300.0)),
  );

  Future<void> setAutoAnnotate(bool auto) =>
      _update((current) => current.copyWith(autoAnnotate: auto));

  Future<void> setMaxObjectsToDisplay(int max) => _update(
    (current) => current.copyWith(maxObjectsToDisplay: max.clamp(10, 5000)),
  );

  Future<void> setCompassEnabled(bool enabled) =>
      _update((current) => current.copyWith(compassEnabled: enabled));

  Future<void> setScaleBarEnabled(bool enabled) =>
      _update((current) => current.copyWith(scaleBarEnabled: enabled));

  Future<void> setGridType(GridType gridType) =>
      _update((current) => current.copyWith(gridType: gridType));

  Future<void> setShowSolveResiduals(bool show) =>
      _update((current) => current.copyWith(showSolveResiduals: show));

  /// Apply an annotation preset to current settings
  Future<void> applyPreset(AnnotationPreset preset) => _update(
    (current) => current.copyWith(
      visibleTypes: Set<AnnotationObjectFilter>.from(preset.visibleTypes),
      minMagnitude: preset.minMagnitude,
      magnitudeCutoff: preset.magnitudeCutoff,
      showLabels: preset.showLabels,
      showMagnitudes: preset.showMagnitudes,
    ),
  );

  /// Cycle through grid types: none -> pixel -> celestial -> none
  Future<void> cycleGridType() => _update((current) {
    final next = switch (current.gridType) {
      GridType.none => GridType.pixel,
      GridType.pixel => GridType.celestial,
      GridType.celestial => GridType.none,
    };
    return current.copyWith(gridType: next);
  });

  Future<void> reset() => _update((_) => const AnnotationSettings());
}

/// Notifier for annotation marker styles with database persistence
class AnnotationMarkerStyleNotifier
    extends AsyncNotifier<AnnotationMarkerStyle> {
  static const _settingsKey = 'annotation_marker_style';
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<AnnotationMarkerStyle> build() async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = await dao.getSetting(_settingsKey);

    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        return AnnotationMarkerStyle.fromJson(json);
      } catch (e, stackTrace) {
        ref
            .read(loggingServiceProvider)
            .error(
              'Failed to decode annotation marker style: $e',
              source: 'AnnotationMarkerStyleNotifier',
            );
        Error.throwWithStackTrace(
          StateError('Annotation marker style is corrupt: $e'),
          stackTrace,
        );
      }
    }
    return const AnnotationMarkerStyle();
  }

  Future<void> _save(AnnotationMarkerStyle style) async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = jsonEncode(style.toJson());
    await dao.setSetting(_settingsKey, jsonStr);
    if (!identical(ref.read(settingsDaoProvider), dao)) {
      throw StateError(
        'The settings database changed while saving annotation marker style.',
      );
    }
  }

  Future<void> _update(
    AnnotationMarkerStyle Function(AnnotationMarkerStyle current) change,
  ) {
    final operation = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Annotation marker style is not loaded; refusing to overwrite it '
          'with defaults.',
        );
      }
      final updated = change(current);
      await _save(updated);
      state = AsyncData(updated);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  Future<void> setGalaxyColor(int color) =>
      _update((current) => current.copyWith(galaxyColor: color));

  Future<void> setNebulaColor(int color) =>
      _update((current) => current.copyWith(nebulaColor: color));

  Future<void> setClusterColor(int color) =>
      _update((current) => current.copyWith(clusterColor: color));

  Future<void> setPlanetaryNebulaColor(int color) =>
      _update((current) => current.copyWith(planetaryNebulaColor: color));

  Future<void> setStarColor(int color) =>
      _update((current) => current.copyWith(starColor: color));

  Future<void> setOtherColor(int color) =>
      _update((current) => current.copyWith(otherColor: color));

  Future<void> setStrokeWidth(double width) => _update(
    (current) => current.copyWith(strokeWidth: width.clamp(0.5, 5.0)),
  );

  Future<void> setLabelFontSize(double size) => _update(
    (current) => current.copyWith(labelFontSize: size.clamp(8.0, 24.0)),
  );

  Future<void> setScaleBySize(bool scale) =>
      _update((current) => current.copyWith(scaleBySize: scale));

  Future<void> setMinMarkerSize(double size) => _update(
    (current) => current.copyWith(minMarkerSize: size.clamp(5.0, 50.0)),
  );

  Future<void> setMaxMarkerSize(double size) => _update(
    (current) => current.copyWith(maxMarkerSize: size.clamp(20.0, 200.0)),
  );

  Future<void> reset() => _update((_) => const AnnotationMarkerStyle());
}

/// Provider for user-created annotation presets (persisted to database)
final annotationPresetsProvider =
    AsyncNotifierProvider<AnnotationPresetsNotifier, List<AnnotationPreset>>(
      () {
        return AnnotationPresetsNotifier();
      },
    );

class AnnotationPresetsNotifier extends AsyncNotifier<List<AnnotationPreset>> {
  static const _settingsKey = 'annotation_presets';
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<List<AnnotationPreset>> build() async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = await dao.getSetting(_settingsKey);

    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final jsonList = jsonDecode(jsonStr) as List<dynamic>;
        return jsonList
            .map((e) => AnnotationPreset.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e, stackTrace) {
        ref
            .read(loggingServiceProvider)
            .error(
              'Failed to decode annotation presets: $e',
              source: 'AnnotationPresetsNotifier',
            );
        Error.throwWithStackTrace(
          StateError('Annotation presets are corrupt: $e'),
          stackTrace,
        );
      }
    }
    return const [];
  }

  Future<void> _save(List<AnnotationPreset> presets) async {
    final dao = ref.read(settingsDaoProvider);
    final jsonStr = jsonEncode(presets.map((p) => p.toJson()).toList());
    await dao.setSetting(_settingsKey, jsonStr);
    if (!identical(ref.read(settingsDaoProvider), dao)) {
      throw StateError(
        'The settings database changed while saving annotation presets.',
      );
    }
  }

  Future<void> _update(
    List<AnnotationPreset> Function(List<AnnotationPreset> current) change,
  ) {
    final operation = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Annotation presets are not loaded; refusing to overwrite them '
          'with an empty list.',
        );
      }
      final updated = List<AnnotationPreset>.unmodifiable(change(current));
      await _save(updated);
      state = AsyncData(updated);
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Save the current annotation settings as a named preset
  Future<void> saveCurrentAsPreset(String name) {
    final settingsNotifier = ref.read(annotationSettingsProvider.notifier);
    final settings = settingsNotifier.state.valueOrNull;
    if (settings == null) {
      return Future<void>.error(
        StateError(
          'Annotation settings are not loaded; refusing to save a preset '
          'from defaults.',
        ),
      );
    }

    final preset = AnnotationPreset(
      name: name,
      visibleTypes: settings.visibleTypes,
      minMagnitude: settings.minMagnitude,
      magnitudeCutoff: settings.magnitudeCutoff,
      showLabels: settings.showLabels,
      showMagnitudes: settings.showMagnitudes,
      isBuiltIn: false,
    );

    return _update(
      (current) => current.where((p) => p.name != name).toList()..add(preset),
    );
  }

  Future<void> deletePreset(String name) =>
      _update((current) => current.where((p) => p.name != name).toList());
}

/// Provider for custom user-drawn annotations on the current image.
/// These are in-memory and scoped to the current image.
final customAnnotationsProvider =
    StateNotifierProvider<CustomAnnotationsNotifier, List<CustomAnnotation>>((
      ref,
    ) {
      return CustomAnnotationsNotifier();
    });

/// Active drawing tool for custom annotations (null = no tool active)
final customAnnotationToolProvider = StateProvider<CustomAnnotationType?>(
  (ref) => null,
);

class CustomAnnotationsNotifier extends StateNotifier<List<CustomAnnotation>> {
  CustomAnnotationsNotifier() : super(const []);

  void add(CustomAnnotation annotation) {
    state = [...state, annotation];
  }

  void remove(String id) {
    state = state.where((a) => a.id != id).toList();
  }

  void updateLabel(String id, String label) {
    state = state.map((a) {
      if (a.id == id) return a.copyWith(label: label);
      return a;
    }).toList();
  }

  void clear() {
    state = const [];
  }
}
