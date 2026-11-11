import 'package:skotiq_core/skotiq_core.dart';

/// The dark library, flat records and defect-map settings of a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostCalibrationFrames {
  Future<List<RemoteDarkLibraryEntry>> listDarks({
    double? exposureSeconds,
    int? gain,
    double? temperatureCelsius,
    int? limit,
  });

  Future<Map<String, dynamic>> getDarkLibrarySettings();

  Future<Map<String, dynamic>> updateDarkLibrarySettings({
    bool? autoCalibrate,
    double? temperatureTolerance,
  });

  Future<Map<String, dynamic>> createDarkLibraryMaster({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String outputPath,
    required String frameType,
  });

  Future<void> deleteDark(int id, {bool deleteFile = false});

  Future<int> deleteDarkLibraryGroup({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String frameType,
    bool deleteFiles = false,
  });

  Future<int> cleanDarkLibraryOrphans();

  Future<int> clearDarkLibrary({bool deleteFiles = false});

  Future<List<RemoteFlatHistoryEntry>> listFlats({
    String? filter,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int? limit,
  });

  Future<RemoteFlatHistoryEntry> recordFlat({
    required String filter,
    required double exposureDuration,
    required int adu,
    double histogramTarget = 50.0,
    int gain = 0,
    int binning = 1,
    int? panelBrightness,
    double? skyAduRate,
    String? twilightPhase,
    int? equipmentProfileId,
  });

  Future<Map<String, dynamic>> getDefectMapSettings();

  Future<Map<String, dynamic>> updateDefectMapSettings(
    Map<String, dynamic> patch,
  );
}
