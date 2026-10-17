import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../../backend/network_backend.dart';
import '../../models/defect_map.dart';
import '../../providers/backend_provider.dart';

/// Service for the defect-map / bad-pixel cosmetic correction pipeline.
///
/// Wraps the native bridge calls. When running as a remote client (a tablet
/// talking to a headless appliance) the dark frames and the on-disk defect
/// map live on the HOST, so every stateful operation routes over
/// `/api/calibration/defect-maps/*` instead of the local FFI bridge. Calling
/// status, clear, or sequencer-push against a controller's FFI would inspect a
/// different process and produce a split-brain UI.
class DefectMapService {
  final Ref _ref;

  DefectMapService(this._ref);

  /// The active [NetworkBackend] when running as a remote client, else null.
  NetworkBackend? get _remote {
    final backend = _ref.read(backendProvider);
    return backend is NetworkBackend ? backend : null;
  }

  /// Build a defect map for `cameraId` from the supplied dark / bias
  /// frame paths. At least
  /// [minRequiredDarkFrames] frames are required for the consistency
  /// check; supplying fewer is an error rather than a silent fall-back.
  ///
  /// On a remote client the supplied paths are HOST paths; when the caller
  /// instead picked a host directory (the remote dark frames are not
  /// enumerable client-side), it passes [darkFramesDirectory] and the host
  /// enumerates the FITS/XISF darks itself.
  Future<DefectMapStatus> build({
    required String cameraId,
    required List<String> darkFramePaths,
    required double sensorTemperatureCelsius,
    String? darkFramesDirectory,
  }) async {
    final remote = _remote;
    if (remote != null) {
      return remote.buildDefectMap(
        cameraId: cameraId,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
        darkFramePaths: darkFramePaths.isEmpty ? null : darkFramePaths,
        darkFramesDirectory: darkFramesDirectory,
      );
    }
    final result = await bridge.apiDefectMapBuild(
      cameraId: cameraId,
      darkFramePaths: darkFramePaths,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
    );
    return _fromBridge(result);
  }

  /// Toggle whether the defect map for `cameraId` is applied to lights
  /// at capture time.
  Future<void> apply({
    required String cameraId,
    required bool applyDuringCapture,
  }) {
    final remote = _remote;
    if (remote != null) {
      return remote.applyDefectMap(
        cameraId: cameraId,
        applyDuringCapture: applyDuringCapture,
      );
    }
    return bridge.apiDefectMapApply(
      cameraId: cameraId,
      applyDuringCapture: applyDuringCapture,
    );
  }

  /// Push the active defect map (or clear it) into the running
  /// sequencer.
  ///
  /// This is the "wire it up" call: persisting the preference via
  /// [apply] is not enough — the sequencer reads its live
  /// `defect_map_apply` state via a separate channel so the per-frame
  /// capture path can apply the correction without per-frame disk
  /// I/O. The Dart side calls this whenever the user toggles
  /// apply-during-capture, changes the kernel / method / save-original
  /// flag, or the connected camera changes.
  ///
  /// When `enabled = false` the bridge pushes `None` to the sequencer
  /// (defect correction disabled). When `enabled = true` the bridge
  /// loads the `.ndm` file from disk, validates the kernel/method,
  /// and pushes the pre-loaded map state.
  Future<void> applyToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
    required DefectMapMethod method,
    required DefectMapKernelSize kernel,
    required bool saveOriginal,
  }) {
    final remote = _remote;
    if (remote != null) {
      return remote.applyDefectMapToSequencer(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
        enabled: enabled,
        method: method,
        kernel: kernel,
        saveOriginal: saveOriginal,
      );
    }
    return bridge.apiSequencerApplyDefectMap(
      cameraId: cameraId,
      width: width,
      height: height,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
      enabled: enabled,
      method: method.wireValue,
      kernelDiameter: kernel.diameter,
      saveOriginal: saveOriginal,
    );
  }

  /// Remove the stored defect map for `cameraId` at the sensor size and
  /// temperature bucket implied by the inputs, and reset the apply flag.
  Future<void> clear({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) {
    final remote = _remote;
    if (remote != null) {
      return remote.clearDefectMap(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
      );
    }
    return bridge.apiDefectMapClear(
      cameraId: cameraId,
      width: width,
      height: height,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
    );
  }

  /// Look up the status of the stored defect map. Returns null if no
  /// map has been built yet for the supplied camera/size/bucket.
  Future<DefectMapStatus?> getStatus({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final remote = _remote;
    if (remote != null) {
      return remote.getDefectMapStatus(
        cameraId: cameraId,
        width: width,
        height: height,
        sensorTemperatureCelsius: sensorTemperatureCelsius,
      );
    }
    final raw = await bridge.apiDefectMapGetStatus(
      cameraId: cameraId,
      width: width,
      height: height,
      sensorTemperatureCelsius: sensorTemperatureCelsius,
    );
    if (raw == null) return null;
    return _fromBridge(raw);
  }

  /// Minimum dark frame count the bridge requires before it will run
  /// the defect detection. Mirrored from the Rust constant.
  static const int minRequiredDarkFrames = 5;

  DefectMapStatus _fromBridge(bridge.ApiDefectMapStatus s) => DefectMapStatus(
    cameraId: s.cameraId,
    width: s.width,
    height: s.height,
    temperatureBucket: DefectMapTemperatureBucket(
      s.temperatureBucketDecicelsius,
    ),
    defectivePixelCount: s.defectivePixelCount,
    lastRebuiltUnixSeconds: s.lastRebuiltUnixSeconds,
    applyDuringCapture: s.applyDuringCapture,
    storedOnDisk: s.storedOnDisk,
  );
}
