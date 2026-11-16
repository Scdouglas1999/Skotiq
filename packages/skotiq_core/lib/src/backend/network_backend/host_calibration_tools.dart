part of '../network_backend.dart';

/// Frame calibration, its settings and the defect maps of a linked imaging
/// host, which holds the calibration masters and the frames they apply to.
mixin HostCalibrationTools on NetworkBackendTransport {
  /// Ask the host to find the best-matching dark in its library for the given
  /// light-frame capture parameters and return that dark's on-host file path.
  ///
  /// A remote client can't run the matcher itself — the dark library and its
  /// FITS files live on the host — so this delegates to
  /// `POST /api/calibration/match-dark`. The returned path is a host-side path
  /// and is meant to be handed straight to [calibrateImageFile], which reads
  /// it host-side. Returns `null` when no library dark matches.
  Future<String?> matchDarkFromLibrary({
    required double exposureTime,
    required int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? temperature,
  }) async {
    final response = await _post(
      CalibrationApi.matchDark,
      body: {
        'exposureTime': exposureTime,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
        'binX': binX,
        'binY': binY,
        if (temperature != null) 'temperature': temperature,
      },
    );
    return response['matched'] as String?;
  }

  /// Turn the host's correction of a camera's lights with the map stored for
  /// this size and temperature on (with this strategy) or off.
  Future<void> applyDefectMapToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
    required DefectMapMethod method,
    required DefectMapKernelSize kernel,
    required bool saveOriginal,
  }) async {
    await _post(
      CalibrationApi.applyDefectMapToSequencer,
      body: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
        'enabled': enabled,
        'method': method.wireValue,
        'kernelDiameter': kernel.diameter,
        'saveOriginal': saveOriginal,
      },
    );
  }

  /// Build a defect map host-side from dark frames.
  ///
  /// A remote client has no local picker over the host filesystem, so it
  /// passes either explicit on-host [darkFramePaths] or a single host
  /// [darkFramesDirectory] for the host to enumerate. Delegates to
  /// `POST /api/calibration/defect-maps/build`; the host runs the same
  /// `DefectMapService.build` the local FFI path uses and returns the
  /// resulting status.
  Future<DefectMapStatus> buildDefectMap({
    required String cameraId,
    required double sensorTemperatureCelsius,
    List<String>? darkFramePaths,
    String? darkFramesDirectory,
  }) async {
    final response = await _post(
      CalibrationApi.buildDefectMap,
      body: {
        'cameraId': cameraId,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
        if (darkFramePaths != null) 'darkFramePaths': darkFramePaths,
        if (darkFramesDirectory != null)
          'darkFramesDirectory': darkFramesDirectory,
      },
    );
    final status = response['status'] as Map<String, dynamic>;
    return _defectMapStatusFromJson(status);
  }

  /// Clear one exact host defect-map bucket and disable its apply flag.
  Future<void> clearDefectMap({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    await _post(
      CalibrationApi.clearDefectMap,
      body: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
      },
    );
  }

  /// Query the defect map owned by the imaging host for one exact
  /// camera/sensor/temperature bucket. Null means no map exists.
  Future<DefectMapStatus?> getDefectMapStatus({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final response = await _get(
      CalibrationApi.getDefectMapStatus,
      query: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
      },
    );
    final status = response['status'];
    if (status == null) return null;
    if (status is! Map<String, dynamic>) {
      throw const FormatException('Malformed remote defect-map status');
    }
    return _defectMapStatusFromJson(status);
  }

  /// Read the complete automatic-calibration configuration owned by the
  /// imaging host. This is intentionally separate from the app-settings wire
  /// model because the master-frame paths are host filesystem resources.
  Future<Map<String, dynamic>> getCalibrationSettings() {
    return _get(CalibrationApi.getCalibrationSettings);
  }

  /// Apply a partial automatic-calibration configuration on the imaging host.
  /// A null path explicitly clears that master-frame selection.
  Future<Map<String, dynamic>> updateCalibrationSettings(
    Map<String, dynamic> patch,
  ) {
    return _post(CalibrationApi.updateCalibrationSettings, body: patch);
  }

  /// Remote-only: schedule the run loaded on the host to start at tonight's
  /// astronomical dark. The host starts it itself, so it does not depend on
  /// this client staying awake or connected. Returns when it will start.
  Future<DateTime?> armHostStartAtDark() async {
    final response = await _post(
      SequencerApi.armScheduledStart,
      body: const {},
      maxAttempts: 1,
    );
    return parseHostScheduledStart(response['at']);
  }

  Future<List<CatalogStarMatch>> matchPhotometricCalibrationStars(
    int imageId,
  ) async {
    final response = await _post(
      ScienceApi.matchPhotometricCalibrationStars,
      path: {'imageId': imageId},
      body: const {},
    );
    return _rowsFromJson<CatalogStarMatch>(
      response['starMatches'],
      CatalogStarMatch.fromJson,
    );
  }
}
