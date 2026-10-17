part of '../planetarium_providers.dart';

// Mount position provider

/// Tracking status for the mount
enum MountTrackingStatus { disconnected, parked, slewing, tracking, stopped }

/// Mount position state for displaying on planetarium
class MountPositionState {
  final double? raHours;
  final double? decDegrees;
  final MountTrackingStatus status;
  final bool isConnected;

  const MountPositionState({
    this.raHours,
    this.decDegrees,
    this.status = MountTrackingStatus.disconnected,
    this.isConnected = false,
  });

  /// Get the mount position as celestial coordinates
  CelestialCoordinate? get coordinates {
    if (raHours == null || decDegrees == null) return null;
    return CelestialCoordinate(ra: raHours!, dec: decDegrees!);
  }

  MountPositionState copyWith({
    double? raHours,
    double? decDegrees,
    MountTrackingStatus? status,
    bool? isConnected,
  }) {
    return MountPositionState(
      raHours: raHours ?? this.raHours,
      decDegrees: decDegrees ?? this.decDegrees,
      status: status ?? this.status,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}

class MountPositionNotifier extends StateNotifier<MountPositionState> {
  MountPositionNotifier() : super(const MountPositionState());

  /// Update the mount position from external source (e.g., equipment provider)
  void updatePosition({
    required double? raHours,
    required double? decDegrees,
    required MountTrackingStatus status,
    required bool isConnected,
  }) {
    state = MountPositionState(
      raHours: raHours,
      decDegrees: decDegrees,
      status: status,
      isConnected: isConnected,
    );
  }

  void setDisconnected() {
    state = const MountPositionState();
  }
}

final mountPositionProvider =
    StateNotifierProvider<MountPositionNotifier, MountPositionState>((ref) {
      return MountPositionNotifier();
    });

// Selected object provider

/// Currently selected celestial object.
///
/// Deliberately holds only *identity* — the object and its catalog coordinates.
/// Anything that depends on when you are looking (alt/az, rise/transit/set,
/// observability) is derived per-frame by [selectedObjectAltAzProvider] /
/// [selectedObjectVisibilityProvider] from the planetarium clock.
///
/// Caching a `currentAltAz` / `visibility` tuple at selection time makes the
/// HUD lie the moment the user does the one thing the time controls exist for:
/// after clicking TONIGHT the bar still reads "Selected Alt: 63.6 deg" in
/// above-horizon green for a target that is by then 17 deg BELOW the horizon.
/// A planning altitude that does not move when you scrub time is worse than no
/// altitude at all, so no such cache exists here.
class SelectedObjectState {
  final CelestialObject? object;
  final CelestialCoordinate? coordinates;

  const SelectedObjectState({this.object, this.coordinates});
}

class SelectedObjectNotifier extends StateNotifier<SelectedObjectState> {
  SelectedObjectNotifier() : super(const SelectedObjectState());

  void selectObject(CelestialObject object) {
    state = SelectedObjectState(
      object: object,
      coordinates: object.coordinates,
    );
  }

  void selectCoordinates(CelestialCoordinate coord) {
    state = SelectedObjectState(coordinates: coord);
  }

  void clearSelection() {
    state = const SelectedObjectState();
  }
}

final selectedObjectProvider =
    StateNotifierProvider<SelectedObjectNotifier, SelectedObjectState>((ref) {
      return SelectedObjectNotifier();
    });

/// The selected object's altitude/azimuth **at the planetarium's current
/// observation time**, or null when nothing is selected or no site is on
/// record.
///
/// Minute precision (the sky's own clock granularity) keeps this from rebuilding
/// the HUD every second; an object moves at most ~0.25 deg per minute.
final selectedObjectAltAzProvider = Provider<(double alt, double az)?>((ref) {
  final coords = ref.watch(selectedObjectProvider.select((s) => s.coordinates));
  if (coords == null) return null;

  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final time = ref.watch(observationMinuteProvider);

  return AstronomyCalculations.objectAltAz(
    raDeg: coords.raDegrees,
    decDeg: coords.dec,
    dt: time,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );
});

/// Rise / transit / set for the selected object on the planetarium's current
/// observation date, or null when nothing is selected or no site is on record.
final selectedObjectVisibilityProvider = Provider<ObjectVisibility?>((ref) {
  final coords = ref.watch(selectedObjectProvider.select((s) => s.coordinates));
  if (coords == null) return null;

  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final date = ref.watch(_currentNightDateProvider);

  return AstronomyCalculations.calculateObjectVisibility(
    raDeg: coords.raDegrees,
    decDeg: coords.dec,
    date: date,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );
});

// Equipment FOV provider

/// Equipment configuration for FOV display
class EquipmentFOVState {
  final CameraSensorSpecs? camera;
  final TelescopeSpecs? telescope;
  final double focalReducer;
  final double rotation;

  const EquipmentFOVState({
    this.camera,
    this.telescope,
    this.focalReducer = 1.0,
    this.rotation = 0,
  });

  /// Get effective focal length
  double? get effectiveFocalLength {
    if (telescope == null) return null;
    return telescope!.focalLengthMm * focalReducer;
  }

  /// Get calculated FOV
  (double width, double height)? get fov {
    if (camera == null || effectiveFocalLength == null) return null;

    return FOVCalculator.calculateFOV(
      sensorWidthMm: camera!.widthMm,
      sensorHeightMm: camera!.heightMm,
      focalLengthMm: effectiveFocalLength!,
    );
  }

  /// Get image scale in arcsec/pixel
  double? get imageScale {
    if (camera == null || effectiveFocalLength == null) return null;

    return FOVCalculator.calculateImageScale(
      pixelSizeMicrons: camera!.pixelSizeMicrons,
      focalLengthMm: effectiveFocalLength!,
    );
  }

  EquipmentFOVState copyWith({
    CameraSensorSpecs? camera,
    TelescopeSpecs? telescope,
    double? focalReducer,
    double? rotation,
  }) {
    return EquipmentFOVState(
      camera: camera ?? this.camera,
      telescope: telescope ?? this.telescope,
      focalReducer: focalReducer ?? this.focalReducer,
      rotation: rotation ?? this.rotation,
    );
  }
}

class EquipmentFOVNotifier extends StateNotifier<EquipmentFOVState> {
  EquipmentFOVNotifier() : super(const EquipmentFOVState());

  void setCamera(CameraSensorSpecs camera) {
    state = state.copyWith(camera: camera);
  }

  void setTelescope(TelescopeSpecs telescope) {
    state = state.copyWith(telescope: telescope);
  }

  /// Replace both optics slots at once, clearing either when null.
  ///
  /// [setCamera] / [setTelescope] can only ever *set* a slot (their copyWith
  /// falls back to the previous value), so a rig that stops being knowable —
  /// profile switched to one with no focal length, camera disconnected — would
  /// otherwise leave the previous rig's box on the sky as if it were still
  /// installed. This is the entry point the equipment binding uses so an
  /// unknown rig draws nothing instead of a stale one.
  ///
  /// Rotation is deliberately preserved: it is the user's framing angle (or the
  /// live rotator's), not a property of the optics.
  void setRig({CameraSensorSpecs? camera, TelescopeSpecs? telescope}) {
    if (identical(camera, state.camera) &&
        identical(telescope, state.telescope)) {
      return;
    }
    state = EquipmentFOVState(
      camera: camera,
      telescope: telescope,
      focalReducer: state.focalReducer,
      rotation: state.rotation,
    );
  }

  void setFocalReducer(double multiplier) {
    state = state.copyWith(focalReducer: multiplier);
  }

  void setRotation(double rotation) {
    state = state.copyWith(rotation: rotation % 360);
  }
}

final equipmentFOVProvider =
    StateNotifierProvider<EquipmentFOVNotifier, EquipmentFOVState>((ref) {
      return EquipmentFOVNotifier();
    });
