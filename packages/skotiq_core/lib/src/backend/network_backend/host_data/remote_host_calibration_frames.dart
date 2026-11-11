import 'package:skotiq_core/skotiq_core.dart';

/// [HostCalibrationFrames] on a linked host.
final class RemoteHostCalibrationFrames implements HostCalibrationFrames {
  RemoteHostCalibrationFrames(this._host);

  final NetworkBackend _host;

  @override
  Future<List<RemoteDarkLibraryEntry>> listDarks({
    double? exposureSeconds,
    int? gain,
    double? temperatureCelsius,
    int? limit,
  }) => _host.listDarks(
    exposureSeconds: exposureSeconds,
    gain: gain,
    temperatureCelsius: temperatureCelsius,
    limit: limit,
  );

  @override
  Future<Map<String, dynamic>> getDarkLibrarySettings() =>
      _host.getDarkLibrarySettings();

  @override
  Future<Map<String, dynamic>> updateDarkLibrarySettings({
    bool? autoCalibrate,
    double? temperatureTolerance,
  }) => _host.updateDarkLibrarySettings(
    autoCalibrate: autoCalibrate,
    temperatureTolerance: temperatureTolerance,
  );

  @override
  Future<Map<String, dynamic>> createDarkLibraryMaster({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String outputPath,
    required String frameType,
  }) => _host.createDarkLibraryMaster(
    exposureTime: exposureTime,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    outputPath: outputPath,
    frameType: frameType,
  );

  @override
  Future<void> deleteDark(int id, {bool deleteFile = false}) =>
      _host.deleteDark(id, deleteFile: deleteFile);

  @override
  Future<int> deleteDarkLibraryGroup({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String frameType,
    bool deleteFiles = false,
  }) => _host.deleteDarkLibraryGroup(
    exposureTime: exposureTime,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    frameType: frameType,
    deleteFiles: deleteFiles,
  );

  @override
  Future<int> cleanDarkLibraryOrphans() => _host.cleanDarkLibraryOrphans();

  @override
  Future<int> clearDarkLibrary({bool deleteFiles = false}) =>
      _host.clearDarkLibrary(deleteFiles: deleteFiles);

  @override
  Future<List<RemoteFlatHistoryEntry>> listFlats({
    String? filter,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int? limit,
  }) => _host.listFlats(
    filter: filter,
    equipmentProfileId: equipmentProfileId,
    gain: gain,
    since: since,
    limit: limit,
  );

  @override
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
  }) => _host.recordFlat(
    filter: filter,
    exposureDuration: exposureDuration,
    adu: adu,
    histogramTarget: histogramTarget,
    gain: gain,
    binning: binning,
    panelBrightness: panelBrightness,
    skyAduRate: skyAduRate,
    twilightPhase: twilightPhase,
    equipmentProfileId: equipmentProfileId,
  );

  @override
  Future<Map<String, dynamic>> getDefectMapSettings() =>
      _host.getDefectMapSettings();

  @override
  Future<Map<String, dynamic>> updateDefectMapSettings(
    Map<String, dynamic> patch,
  ) => _host.updateDefectMapSettings(patch);
}
