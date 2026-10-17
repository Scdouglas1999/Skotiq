part of '../flat_wizard_provider.dart';

/// The effective, capability-resolved camera config for the flat wizard.
///
/// The UI watches this to show the target as an absolute ADU and a percentage
/// of the DETECTED full-scale range, and to keep controls truthful. It is
/// resolved from the CONNECTED camera — host-authoritative on a
/// [NetworkBackend], where the capability probes route to the master — so the
/// phone never invents a range. [FlatWizardNotifier.runCapture] re-resolves it
/// at run start and publishes the run's config here, so the UI preview, the
/// backend command, the FITS header, and the DB record all use ONE config.
final flatCameraConfigProvider =
    StateNotifierProvider<FlatCameraConfigNotifier, FlatCaptureConfig>((ref) {
      return FlatCameraConfigNotifier(ref);
    });

class FlatCameraConfigNotifier extends StateNotifier<FlatCaptureConfig> {
  final Ref ref;
  int _resolveGeneration = 0;

  FlatCameraConfigNotifier(this.ref) : super(const FlatCaptureConfig()) {
    // Re-resolve whenever the connected camera changes (connect/disconnect or a
    // different device) so the detected range appears as soon as a camera is
    // available and never lingers stale after a swap.
    ref.listen(cameraStateProvider, (prev, next) {
      if (prev?.deviceId != next.deviceId ||
          prev?.connectionState != next.connectionState) {
        // Fire-and-forget; resolve() is self-contained and never throws.
        resolve();
      }
    });
    ref.listen(activeEquipmentProfileProvider, (prev, next) {
      if (!_sameProfileCaptureInputs(prev, next)) {
        resolve();
      }
    });
    // Resolve immediately for a camera that is ALREADY connected when the
    // provider is first read (the listener above only fires on later changes).
    resolve();
  }

  /// Resolve the effective config from the connected camera + active profile
  /// and publish it. Returns the resolved config. When no camera is connected,
  /// publishes a generic 16-bit display fallback so the UI remains legible;
  /// its `rangeKnown` is false, so capture callers must not automate against
  /// that guessed range.
  Future<FlatCaptureConfig> resolve({
    int? fallbackBinX,
    int? fallbackBinY,
    bool failIfStale = false,
  }) async {
    final generation = ++_resolveGeneration;
    final camera = ref.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected ||
        camera.deviceId == null) {
      const fallback = FlatCaptureConfig();
      if (mounted && generation == _resolveGeneration) state = fallback;
      return fallback;
    }
    final backend = ref.read(backendProvider);
    final profile = ref.read(activeEquipmentProfileProvider);
    final config = await FlatWizardService.resolveCaptureConfig(
      backend: backend,
      deviceId: camera.deviceId!,
      profileDefaultGain: profile?.defaultGain,
      profileDefaultOffset: profile?.defaultOffset,
      profileBinX: profile?.defaultBinX,
      profileBinY: profile?.defaultBinY,
      currentGain: camera.gain,
      currentOffset: camera.offset,
      fallbackBinX: fallbackBinX,
      fallbackBinY: fallbackBinY,
    );
    final liveCamera = ref.read(cameraStateProvider);
    final liveProfile = ref.read(activeEquipmentProfileProvider);
    final stale =
        generation != _resolveGeneration ||
        liveCamera.connectionState != DeviceConnectionState.connected ||
        liveCamera.deviceId != camera.deviceId ||
        !_sameProfileCaptureInputs(profile, liveProfile);
    if (stale) {
      if (failIfStale) {
        throw StateError(
          'Camera or equipment profile changed while resolving flat-capture '
          'capabilities',
        );
      }
      return state;
    }
    if (mounted) state = config;
    return config;
  }

  static bool _sameProfileCaptureInputs(
    EquipmentProfileModel? a,
    EquipmentProfileModel? b,
  ) =>
      a?.id == b?.id &&
      a?.defaultGain == b?.defaultGain &&
      a?.defaultOffset == b?.defaultOffset &&
      a?.defaultBinX == b?.defaultBinX &&
      a?.defaultBinY == b?.defaultBinY;
}
