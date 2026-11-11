// Sky-Brightness Adaptive Exposure defaults. Owns the
// global default exposure-scaling config the executor consults when a
// TakeExposure node has no per-node override. Captures both the scalar
// reference values and the per-filter override maps.
//
// Owns:
//   * adaptiveExposureEnabled (master), adaptiveExposureTargetSnr
//   * adaptiveExposureReferenceMag, adaptiveExposureMinSecs,
//     adaptiveExposureMaxSecs
//   * adaptiveExposurePerFilterEnabled, *PerFilterMinSecs, *PerFilterMaxSecs
//
// Does NOT own:
//   * Per-node `ExposureNode.adaptiveExposure` overrides — those live in
//     the sequence model.
//   * Smart Night exposure-floor / ceiling (a separate planning system
//     with its own clamps) → see `smart_night.dart`.
part of '../settings_provider.dart';

/// Setters for sky-brightness adaptive exposure defaults.
extension AdaptiveExposureSettingsSection on AppSettingsNotifier {
  AppSettingsState _requireAdaptiveExposureSettings() {
    final current = _currentValueOrNull;
    if (current == null) {
      throw StateError('Adaptive-exposure settings are not loaded yet.');
    }
    return current;
  }

  void _validateAdaptiveExposureBounds(
    double minSecs,
    double maxSecs, {
    String label = 'Adaptive exposure',
  }) {
    if (!minSecs.isFinite || minSecs <= 0) {
      throw ArgumentError('$label minimum must be a positive finite value.');
    }
    if (!maxSecs.isFinite || maxSecs <= 0) {
      throw ArgumentError('$label maximum must be a positive finite value.');
    }
    if (minSecs > maxSecs) {
      throw ArgumentError('$label minimum cannot exceed its maximum.');
    }
  }

  /// Master switch for the global default sky-brightness adaptive
  /// exposure. Off => the executor's runtime default is cleared and
  /// only per-node `ExposureNode.adaptiveExposure` overrides apply.
  Future<void> setAdaptiveExposureEnabled(bool value) =>
      _set(AppSettingDefs.adaptiveExposureEnabled, value);

  /// Target SNR for the adaptive scaling (informational; the live
  /// math uses background flux ratio, not a direct SNR solver).
  Future<void> setAdaptiveExposureTargetSnr(double value) =>
      _set(AppSettingDefs.adaptiveExposureTargetSnr, value);

  /// Reference sky brightness in mag/arcsec² that the nominal duration
  /// was calibrated for. Bigger = darker; a dark site is 21.5+, an
  /// urban backyard is 18-19.
  Future<void> setAdaptiveExposureReferenceMag(double value) =>
      _set(AppSettingDefs.adaptiveExposureReferenceMag, value);

  /// Persist the global clamp as one validated unit so an intermediate save
  /// can never leave the executor with min > max.
  Future<void> setAdaptiveExposureBounds({
    required double minSecs,
    required double maxSecs,
  }) async {
    _validateAdaptiveExposureBounds(minSecs, maxSecs);
    await _setAll([
      AppSettingDefs.adaptiveExposureMinSecs.to(minSecs),
      AppSettingDefs.adaptiveExposureMaxSecs.to(maxSecs),
    ]);
  }

  /// Compatibility setters retain the existing public API while enforcing the
  /// same cross-field invariant as [setAdaptiveExposureBounds].
  Future<void> setAdaptiveExposureMinSecs(double value) async {
    final current = _requireAdaptiveExposureSettings();
    await setAdaptiveExposureBounds(
      minSecs: value,
      maxSecs: current.adaptiveExposureMaxSecs,
    );
  }

  Future<void> setAdaptiveExposureMaxSecs(double value) async {
    final current = _requireAdaptiveExposureSettings();
    await setAdaptiveExposureBounds(
      minSecs: current.adaptiveExposureMinSecs,
      maxSecs: value,
    );
  }

  /// Per-filter enable map. JSON-serialised for storage.
  Future<void> setAdaptiveExposurePerFilterEnabled(
    Map<String, bool> map,
  ) async {
    final saved = Map<String, bool>.unmodifiable(map);
    await _set(AppSettingDefs.adaptiveExposurePerFilterEnabled, saved);
  }

  /// Persist both per-filter maps atomically after resolving each missing side
  /// against the global bound. This prevents a valid-looking single override
  /// from creating an inverted effective range.
  Future<void> setAdaptiveExposurePerFilterBounds({
    required Map<String, double> minSecs,
    required Map<String, double> maxSecs,
  }) async {
    final current = _requireAdaptiveExposureSettings();
    final savedMin = Map<String, double>.unmodifiable(minSecs);
    final savedMax = Map<String, double>.unmodifiable(maxSecs);
    final filters = <String>{...savedMin.keys, ...savedMax.keys};
    for (final filter in filters) {
      if (filter.trim().isEmpty) {
        throw ArgumentError('Adaptive-exposure filter name cannot be blank.');
      }
      _validateAdaptiveExposureBounds(
        savedMin[filter] ?? current.adaptiveExposureMinSecs,
        savedMax[filter] ?? current.adaptiveExposureMaxSecs,
        label: 'Adaptive exposure for $filter',
      );
    }

    await _setAll([
      AppSettingDefs.adaptiveExposurePerFilterMinSecs.to(savedMin),
      AppSettingDefs.adaptiveExposurePerFilterMaxSecs.to(savedMax),
    ]);
  }

  Future<void> setAdaptiveExposurePerFilterMinSecs(
    Map<String, double> map,
  ) async {
    final current = _requireAdaptiveExposureSettings();
    await setAdaptiveExposurePerFilterBounds(
      minSecs: map,
      maxSecs: current.adaptiveExposurePerFilterMaxSecs,
    );
  }

  Future<void> setAdaptiveExposurePerFilterMaxSecs(
    Map<String, double> map,
  ) async {
    final current = _requireAdaptiveExposureSettings();
    await setAdaptiveExposurePerFilterBounds(
      minSecs: current.adaptiveExposurePerFilterMinSecs,
      maxSecs: map,
    );
  }
}
