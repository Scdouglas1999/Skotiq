import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../../providers/linked_host.dart';
import '../../models/defect_map.dart';
import '../../backend/remote_host.dart';

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

  /// The linked host's defect maps, or null when the rig is this machine.
  HostCalibrationTools? get _remote =>
      _ref.read(linkedHostCalibrationToolsProvider);

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

  /// Turn correction of `cameraId`'s lights during capture on, with the map
  /// stored for this sensor size and temperature and the given strategy, or
  /// off. The status reports the change and the sequencer applies it from the
  /// next exposure; enabling fails when no map is stored.
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
    return bridge.apiDefectMapSetCorrection(
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
  /// temperature bucket implied by the inputs. Correction with that map, if
  /// on, stops from the next exposure.
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
