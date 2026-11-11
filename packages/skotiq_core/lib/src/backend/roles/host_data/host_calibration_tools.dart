import 'package:skotiq_core/skotiq_core.dart';

/// Frame calibration, its settings and the defect maps of a linked imaging
/// host, which holds the calibration masters and the frames they apply to.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostCalibrationTools {
  /// The host's events, for the settings-changed notice.
  Stream<SkotiqEvent> get eventStream;

  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  });

  Future<Map<String, dynamic>> getCalibrationSettings();

  Future<String?> matchDarkFromLibrary({
    required double exposureTime,
    required int gain,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    double? temperature,
  });

  Future<Map<String, dynamic>> updateCalibrationSettings(
    Map<String, dynamic> patch,
  );

  Future<void> applyDefectMap({
    required String cameraId,
    required bool applyDuringCapture,
  });

  Future<void> applyDefectMapToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
    required DefectMapMethod method,
    required DefectMapKernelSize kernel,
    required bool saveOriginal,
  });

  Future<DefectMapStatus> buildDefectMap({
    required String cameraId,
    required double sensorTemperatureCelsius,
    List<String>? darkFramePaths,
    String? darkFramesDirectory,
  });

  Future<void> clearDefectMap({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  });

  Future<DefectMapStatus?> getDefectMapStatus({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  });
}
