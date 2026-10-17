import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hardware_presets/hardware_preset_models.dart';
import '../services/hardware_presets/hardware_presets_service.dart';
import 'database_provider.dart';

/// Riverpod plumbing for the hardware-presets library.
///
/// Wires the pure [HardwarePresetsService] to persistence. The user override
/// lists live as JSON blobs in `app_settings` keyed by
/// [HardwarePresetsService.telescopeOverridesSettingKey] /
/// [HardwarePresetsService.cameraOverridesSettingKey], and mutations persist
/// *before* updating in-memory state.
///
/// The built-in catalogs are immutable: editing a built-in preset stores an
/// `isBuiltIn: false` override copy under its (stable) id, which the service's
/// merge then prefers over the catalog entry. Built-ins can never be deleted.
final hardwarePresetsServiceProvider =
    StateNotifierProvider<HardwarePresetsNotifier, HardwarePresetsService>((
      ref,
    ) {
      final notifier = HardwarePresetsNotifier(ref);
      // Kick off hydration immediately. State starts at the built-ins-only base
      // service; once `_load()` resolves the persisted overrides are merged in.
      notifier._load();
      return notifier;
    });

/// All telescope presets (overrides merged over built-ins). Convenience read
/// for the preset-picker UI so it doesn't reach through the notifier.
final telescopePresetsProvider = Provider<List<TelescopePreset>>(
  (ref) => ref.watch(hardwarePresetsServiceProvider).allTelescopes(),
);

/// All camera-defaults presets (overrides merged over built-ins).
///
/// Named `cameraDefaultsPresetsProvider` rather than `cameraPresetsProvider`
/// to avoid colliding with the pre-existing barrel export of the same short
/// name in `camera_presets_provider.dart` (which owns gain/offset acquisition
/// presets, a different domain). The name also tracks the model
/// [CameraDefaultsPreset].
final cameraDefaultsPresetsProvider = Provider<List<CameraDefaultsPreset>>(
  (ref) => ref.watch(hardwarePresetsServiceProvider).allCameras(),
);

class HardwarePresetsNotifier extends StateNotifier<HardwarePresetsService> {
  HardwarePresetsNotifier(this._ref)
    : _base = const HardwarePresetsService(),
      super(const HardwarePresetsService());

  final Ref _ref;

  /// The built-ins-only base service. Every state update is derived from this
  /// via [HardwarePresetsService.withOverrides] so the immutable catalogs are
  /// preserved untouched regardless of override churn.
  final HardwarePresetsService _base;

  bool _isLoaded = false;
  Completer<void>? _loadCompleter;

  /// Captures a load failure (e.g. a malformed persisted blob) so it remains
  /// surfaceable through [loaded] no matter when the future is awaited: a
  /// swallowed load error reads as an empty preset library.
  Object? _loadError;
  StackTrace? _loadStackTrace;

  /// True once the initial load has finished, whether it succeeded or failed.
  bool get isLoaded => _isLoaded;

  /// Future that resolves when the initial override load is done. Rejects with
  /// the original error (and stack trace) if hydration failed — e.g. a
  /// corrupt persisted override blob throws [FormatException]. Awaited by the
  /// UI before rendering the preset picker and by tests for determinism.
  Future<void> get loaded {
    if (_isLoaded) {
      if (_loadError != null) {
        return Future.error(_loadError!, _loadStackTrace);
      }
      return Future.value();
    }
    _loadCompleter ??= Completer<void>();
    return _loadCompleter!.future;
  }

  Future<void> _load() async {
    try {
      final settingsDao = _ref.read(settingsDaoProvider);
      final telescopeRaw = await settingsDao.getSetting(
        HardwarePresetsService.telescopeOverridesSettingKey,
      );
      final cameraRaw = await settingsDao.getSetting(
        HardwarePresetsService.cameraOverridesSettingKey,
      );

      // A malformed blob throws FormatException here — surfaced, not swallowed.
      final telescopeOverrides =
          HardwarePresetsService.telescopeOverridesFromJson(
            telescopeRaw == null ? null : jsonDecode(telescopeRaw),
          );
      final cameraOverrides = HardwarePresetsService.cameraOverridesFromJson(
        cameraRaw == null ? null : jsonDecode(cameraRaw),
      );

      if (mounted) {
        state = _base.withOverrides(
          telescopeOverrides: telescopeOverrides,
          cameraOverrides: cameraOverrides,
        );
      }
      _isLoaded = true;
      _loadCompleter?.complete();
    } catch (error, stackTrace) {
      _loadError = error;
      _loadStackTrace = stackTrace;
      _isLoaded = true;
      _loadCompleter?.completeError(error, stackTrace);
    } finally {
      _loadCompleter = null;
    }
  }

  /// Insert-or-replace [preset] into the telescope overrides, keyed by [id], and
  /// persist. Built-ins are immutable: if [preset.id] matches a built-in, the
  /// stored override is forced to `isBuiltIn: false` so it reads back as a
  /// user-owned copy (and the service merge prefers it over the catalog entry).
  Future<void> saveTelescopePreset(TelescopePreset preset) async {
    final toStore = _isBuiltInTelescopeId(preset.id)
        ? preset.copyWith(isBuiltIn: false)
        : preset;
    final next = _upsertById<TelescopePreset>(
      _currentTelescopeOverrides(),
      toStore,
      (p) => p.id,
    );
    await _persistTelescopeOverrides(next);
    if (!mounted) return;
    state = state.withOverrides(telescopeOverrides: next);
  }

  /// Remove the telescope preset with [id] from the overrides and persist.
  /// Built-ins cannot be deleted: a built-in [id] throws [StateError],
  /// surfacing the programmer error per repo convention.
  Future<void> deleteTelescopePreset(String id) async {
    if (_isBuiltInTelescopeId(id)) {
      throw StateError(
        'Cannot delete built-in telescope preset "$id"; built-ins are immutable',
      );
    }
    final next = _currentTelescopeOverrides()
        .where((preset) => preset.id != id)
        .toList();
    await _persistTelescopeOverrides(next);
    if (!mounted) return;
    state = state.withOverrides(telescopeOverrides: next);
  }

  /// Insert-or-replace [preset] into the camera overrides, keyed by [id], and
  /// persist. As with telescopes, editing a built-in stores an
  /// `isBuiltIn: false` override copy under its id.
  Future<void> saveCameraPreset(CameraDefaultsPreset preset) async {
    final toStore = _isBuiltInCameraId(preset.id)
        ? preset.copyWith(isBuiltIn: false)
        : preset;
    final next = _upsertById<CameraDefaultsPreset>(
      _currentCameraOverrides(),
      toStore,
      (p) => p.id,
    );
    await _persistCameraOverrides(next);
    if (!mounted) return;
    state = state.withOverrides(cameraOverrides: next);
  }

  /// Remove the camera preset with [id] from the overrides and persist.
  /// Built-ins cannot be deleted: a built-in [id] throws [StateError].
  Future<void> deleteCameraPreset(String id) async {
    if (_isBuiltInCameraId(id)) {
      throw StateError(
        'Cannot delete built-in camera preset "$id"; built-ins are immutable',
      );
    }
    final next = _currentCameraOverrides()
        .where((preset) => preset.id != id)
        .toList();
    await _persistCameraOverrides(next);
    if (!mounted) return;
    state = state.withOverrides(cameraOverrides: next);
  }

  // Internals.

  /// The current telescope overrides, recovered as the merged-list entries that
  /// are not built-ins. Because the merge places overrides first and de-dupes
  /// by id, every non-built-in entry in [HardwarePresetsService.allTelescopes]
  /// is an override; the built-in catalog entries carry `isBuiltIn: true`.
  List<TelescopePreset> _currentTelescopeOverrides() => state
      .allTelescopes()
      .where((preset) => !preset.isBuiltIn)
      .toList(growable: false);

  List<CameraDefaultsPreset> _currentCameraOverrides() => state
      .allCameras()
      .where((preset) => !preset.isBuiltIn)
      .toList(growable: false);

  bool _isBuiltInTelescopeId(String id) =>
      builtInTelescopePresets.any((preset) => preset.id == id);

  bool _isBuiltInCameraId(String id) =>
      builtInCameraDefaultsPresets.any((preset) => preset.id == id);

  Future<void> _persistTelescopeOverrides(
    List<TelescopePreset> overrides,
  ) async {
    final settingsDao = _ref.read(settingsDaoProvider);
    await settingsDao.setSetting(
      HardwarePresetsService.telescopeOverridesSettingKey,
      HardwarePresetsService.encodeTelescopeOverrides(overrides),
    );
  }

  Future<void> _persistCameraOverrides(
    List<CameraDefaultsPreset> overrides,
  ) async {
    final settingsDao = _ref.read(settingsDaoProvider);
    await settingsDao.setSetting(
      HardwarePresetsService.cameraOverridesSettingKey,
      HardwarePresetsService.encodeCameraOverrides(overrides),
    );
  }

  /// Returns a new list with [item] inserted, or replacing any existing entry
  /// sharing its id (matched via [idOf]). Replacement preserves position so the
  /// override ordering is stable across edits; a new id is appended.
  static List<T> _upsertById<T>(
    List<T> items,
    T item,
    String Function(T) idOf,
  ) {
    final id = idOf(item);
    final result = List<T>.from(items);
    final index = result.indexWhere((existing) => idOf(existing) == id);
    if (index >= 0) {
      result[index] = item;
    } else {
      result.add(item);
    }
    return result;
  }
}
