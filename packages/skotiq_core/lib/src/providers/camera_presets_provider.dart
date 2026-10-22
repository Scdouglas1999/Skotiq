import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart' show CameraRecommendedSettings;
import '../models/equipment/equipment_models.dart'
    show CameraStateSnapshot, DeviceConnectionState;
import '../models/imaging/camera_preset.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/device_capability_provider.dart';
import 'imaging_provider.dart';

/// Provider for managing camera gain/offset presets
final cameraPresetsProvider =
    StateNotifierProvider<
      CameraPresetsNotifier,
      AsyncValue<List<CameraPreset>>
    >((ref) {
      // Reload when the settings rows change underneath, e.g. on the host.
      ref.watch(settingsDaoProvider);
      return CameraPresetsNotifier(ref);
    });

/// Provider for the currently selected preset ID
final selectedPresetIdProvider = StateProvider<String?>((ref) => null);

/// The literal gain/offset of the factory-shipped "unity_gain" preset.
///
/// [CameraPresetsNotifier.seedFromRecommended] only overwrites the unity_gain
/// preset while it still matches these literals, i.e. the user has not
/// customized it. Once the user renames or re-tunes it, the SDK recommendation
/// must not clobber their choice.
const int kDefaultUnityGain = 139;
const int kDefaultUnityOffset = 30;

/// Stable id of the factory unity-gain preset created by
/// [CameraPresetsNotifier._createDefaultPresets].
const String kUnityGainPresetId = 'unity_gain';

/// Eagerly-initialized side-effect provider that seeds the unity_gain preset
/// from the connected camera's [CameraRecommendedSettings] on the
/// disconnected/connecting -> connected edge.
///
/// The seed needs the camera's gain range (from
/// [equipmentCameraCapabilitiesProvider]) and the preset notifier, both of
/// which are Riverpod-scoped, so it lives here rather than in
/// [CameraStateNotifier].
///
/// Read this once during app bootstrap (`container.read(...)`) so the listener
/// is attached before the first camera connects. It lives for the lifetime of
/// the container.
final cameraPresetsSeedOnConnectProvider = Provider<void>((ref) {
  ref.listen<CameraStateSnapshot>(cameraStateProvider, (previous, next) {
    // Fire only on the transition INTO connected so we don't re-seed on every
    // status tick (temperature/cooler-power updates re-emit the snapshot).
    final wasConnected =
        previous != null &&
        previous.connectionState == DeviceConnectionState.connected;
    final nowConnected =
        next.connectionState == DeviceConnectionState.connected;
    if (wasConnected || !nowConnected) return;

    final deviceId = next.deviceId;
    if (deviceId == null || deviceId.isEmpty) return;

    // Run the async query off the listener callback. The notifier guards
    // against clobbering user-customized presets, so a late completion is safe.
    unawaited(_seedFromConnectedCamera(ref, deviceId));
  });
});

/// Queries the recommendation + gain range for [deviceId] and forwards them to
/// the preset notifier. Failures surface as warnings; seeding is a convenience
/// layered on top of an already-connected camera, never a precondition.
Future<void> _seedFromConnectedCamera(Ref ref, String deviceId) async {
  final backend = ref.read(deviceBackendProvider);

  bool isStillCurrent() {
    try {
      final camera = ref.read(cameraStateProvider);
      return identical(ref.read(deviceBackendProvider), backend) &&
          camera.connectionState == DeviceConnectionState.connected &&
          camera.deviceId == deviceId;
    } catch (_) {
      // The provider scope was disposed while the convenience seed was in
      // flight. There is no longer an authority that can accept the result.
      return false;
    }
  }

  final CameraRecommendedSettings rec;
  try {
    rec = await backend.cameraGetRecommendedSettings(deviceId);
  } catch (_) {
    // No recommendation available (typical for ASCOM/Alpaca/INDI). Honest
    // no-op: the unity_gain preset keeps its published default.
    return;
  }
  if (!isStillCurrent()) return;

  // Pull the gain range so the recommendation is clamped to what the hardware
  // actually accepts. A null/failed capability query leaves the bounds open,
  // which seedFromRecommended treats as "clamp to the value itself" (no-op).
  int? gainMin;
  int? gainMax;
  try {
    final caps = await ref.read(
      equipmentCameraCapabilitiesProvider(deviceId).future,
    );
    gainMin = caps?.gainMin;
    gainMax = caps?.gainMax;
  } catch (_) {
    // Capability query threw; leave the bounds unknown and let
    // seedFromRecommended fall back to clamping against the value itself.
  }
  if (!isStillCurrent()) return;

  await ref
      .read(cameraPresetsProvider.notifier)
      .seedFromRecommended(
        rec,
        gainMin: gainMin,
        gainMax: gainMax,
        authorityGuard: isStillCurrent,
      );
}

class CameraPresetsNotifier
    extends StateNotifier<AsyncValue<List<CameraPreset>>> {
  final Ref _ref;
  static const String _storageKey = 'camera_presets';
  late final Future<void> _loadFuture;
  Future<void> _mutationTail = Future<void>.value();

  CameraPresetsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _loadFuture = _loadPresets();
  }

  /// Load presets from storage
  Future<void> _loadPresets() async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      final jsonString = await dao.getSetting(_storageKey);

      if (jsonString == null || jsonString.isEmpty) {
        // Initialize with default presets
        final defaults = _createDefaultPresets();
        await _savePresets(defaults);
        state = AsyncValue.data(defaults);
      } else {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        final presets = jsonList
            .map((json) => CameraPreset.fromJson(json as Map<String, dynamic>))
            .toList();
        state = AsyncValue.data(presets);
      }
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  /// Create default camera presets
  List<CameraPreset> _createDefaultPresets() {
    final now = DateTime.now();
    return [
      CameraPreset(
        id: 'high_dynamic_range',
        name: 'High Dynamic Range',
        gain: 0,
        offset: 10,
        createdAt: now,
      ),
      CameraPreset(
        id: 'low_read_noise',
        name: 'Low Read Noise',
        gain: 100,
        offset: 50,
        createdAt: now,
      ),
      CameraPreset(
        id: kUnityGainPresetId,
        name: 'Unity Gain',
        gain: kDefaultUnityGain,
        offset: kDefaultUnityOffset,
        createdAt: now,
      ),
    ];
  }

  /// Save presets to storage
  Future<void> _savePresets(List<CameraPreset> presets) async {
    final dao = _ref.read(settingsDaoProvider);
    final jsonList = presets.map((p) => p.toJson()).toList();
    final jsonString = jsonEncode(jsonList);
    await dao.setSetting(_storageKey, jsonString);
  }

  Future<void> _mutate(
    FutureOr<List<CameraPreset>?> Function(List<CameraPreset> current) change, {
    void Function()? afterSave,
    bool Function()? authorityGuard,
  }) {
    final operation = _mutationTail.then((_) async {
      await _loadFuture;
      if (authorityGuard != null && !authorityGuard()) return;
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError('Camera presets are unavailable: ${state.error}');
      }
      final updated = await change(List<CameraPreset>.unmodifiable(current));
      if (updated == null) return;
      if (authorityGuard != null && !authorityGuard()) return;
      await _savePresets(updated);
      if (!mounted) return;
      if (authorityGuard != null && !authorityGuard()) {
        // Mutations are serialized by [_mutationTail], so restoring the
        // confirmed list here cannot overwrite a newer user edit. It prevents
        // a camera that changed during the settings write from poisoning the
        // next camera's pristine seed check.
        await _savePresets(current);
        return;
      }
      state = AsyncValue.data(List<CameraPreset>.unmodifiable(updated));
      afterSave?.call();
    });
    _mutationTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  /// Add a new preset
  Future<void> addPreset(CameraPreset preset) => _mutate((currentPresets) {
    if (currentPresets.any(
      (p) => p.name.toLowerCase() == preset.name.toLowerCase(),
    )) {
      throw Exception('A preset with this name already exists');
    }
    return [...currentPresets, preset];
  });

  /// Update an existing preset
  Future<void> updatePreset(String id, CameraPreset updatedPreset) => _mutate((
    currentPresets,
  ) {
    final index = currentPresets.indexWhere((p) => p.id == id);

    if (index == -1) {
      throw Exception('Preset not found');
    }

    final updatedPresets = [...currentPresets];
    updatedPresets[index] = updatedPreset.copyWith(updatedAt: DateTime.now());
    return updatedPresets;
  });

  /// Delete a preset
  Future<void> deletePreset(String id) => _mutate(
    (currentPresets) {
      if (!currentPresets.any((preset) => preset.id == id)) return null;
      return currentPresets.where((preset) => preset.id != id).toList();
    },
    afterSave: () {
      if (_ref.read(selectedPresetIdProvider) == id) {
        _ref.read(selectedPresetIdProvider.notifier).state = null;
      }
    },
  );

  /// Apply a preset (updates exposure settings)
  void applyPreset(String id) {
    final preset = state.valueOrNull?.firstWhere(
      (p) => p.id == id,
      orElse: () => throw Exception('Preset not found'),
    );

    if (preset == null) return;

    // Update the selected preset
    _ref.read(selectedPresetIdProvider.notifier).state = id;

    // Applying a preset is an explicit user choice of gain/offset. Mark the
    // exposure settings dirty so profile hydration does not overwrite the
    // (syncExposureFromProfileProvider) does not immediately overwrite the
    // values the user just selected.
    // Update exposure settings
    final currentSettings = _ref.read(exposureSettingsProvider);
    _ref
        .read(manualExposureSettingsUpdaterProvider)
        .update(
          currentSettings.copyWith(gain: preset.gain, offset: preset.offset),
        );
  }

  /// Seed the factory unity-gain preset from a camera's manufacturer
  /// recommendation, clamped to the camera's accepted gain range.
  ///
  /// Behavior contract:
  /// - Only the unity_gain preset that STILL matches the published factory
  ///   default (gain [kDefaultUnityGain] / offset [kDefaultUnityOffset], with
  ///   its original id) is touched. A renamed or re-tuned preset — or one the
  ///   user deleted — is left untouched: their customization wins.
  /// - When [CameraRecommendedSettings.unityGain] is null the literals are
  ///   left in place. This is the honest fallback: most ASCOM/Alpaca/INDI and
  ///   several native vendor SDKs publish no unity gain, and fabricating one
  ///   would be a silent lie.
  /// - The recommended gain is clamped into `[gainMin, gainMax]` when those
  ///   bounds are known. A null bound clamps against the recommended value
  ///   itself (i.e. that side is unconstrained), so an unknown range never
  ///   shifts the value.
  /// - The offset becomes [CameraRecommendedSettings.defaultOffset] when the
  ///   SDK reports one, otherwise the published default offset is retained.
  Future<void> seedFromRecommended(
    CameraRecommendedSettings rec, {
    int? gainMin,
    int? gainMax,
    bool Function()? authorityGuard,
  }) {
    final unityGain = rec.unityGain;
    // No recommended unity gain -> keep the honest literal default.
    if (unityGain == null) return Future<void>.value();

    return _mutate((currentPresets) {
      final index = currentPresets.indexWhere(
        (p) => p.id == kUnityGainPresetId,
      );
      if (index == -1) return null; // User deleted it; respect that.

      final existing = currentPresets[index];
      // Only seed while the preset is still the untouched factory default. A
      // user-renamed or re-tuned preset must not be clobbered.
      final isPristine =
          existing.name == 'Unity Gain' &&
          existing.gain == kDefaultUnityGain &&
          existing.offset == kDefaultUnityOffset;
      if (!isPristine) return null;

      // Clamp into the camera's accepted range. A null bound is unconstrained,
      // so clamp against the value itself on that side (a no-op).
      final int clampedGain = unityGain.clamp(
        gainMin ?? unityGain,
        gainMax ?? unityGain,
      );
      final seededOffset = rec.defaultOffset ?? kDefaultUnityOffset;

      // Nothing actually changes — avoid a needless write/state emit.
      if (clampedGain == existing.gain && seededOffset == existing.offset) {
        return null;
      }

      final updatedPresets = [...currentPresets];
      updatedPresets[index] = existing.copyWith(
        gain: clampedGain,
        offset: seededOffset,
        updatedAt: DateTime.now(),
      );

      return updatedPresets;
    }, authorityGuard: authorityGuard);
  }

  /// Reset to default presets
  Future<void> resetToDefaults() => _mutate(
    (_) => _createDefaultPresets(),
    afterSave: () => _ref.read(selectedPresetIdProvider.notifier).state = null,
  );
}
