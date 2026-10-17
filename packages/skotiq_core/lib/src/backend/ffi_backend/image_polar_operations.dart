part of '../ffi_backend.dart';

mixin _FfiImagePolarOperations on _FfiBackendBase {
  // Image processing

  @override
  Future<List<StarCrop>> getStarCropsFromLastImage(
    String deviceId, {
    int maxCrops = 5,
  }) async {
    final bridgeCrops = await bridge_api.apiGetStarCropsFromLastImage(
      deviceId: deviceId,
      maxCrops: maxCrops,
    );
    return bridgeCrops
        .map(
          (crop) => StarCrop(
            pixelsBase64: crop.pixelsBase64,
            width: crop.width.toInt(),
            height: crop.height.toInt(),
            hfr: crop.hfr,
            snr: crop.snr,
          ),
        )
        .toList();
  }

  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    await bridge_api.apiCalibrateImageFile(
      lightPath: lightPath,
      darkPath: darkPath,
      flatPath: flatPath,
      biasPath: biasPath,
      outputPath: outputPath,
    );
  }

  @override
  Future<bridge.FitsReadResult> readFitsFile({required String filePath}) {
    return bridge_api.apiReadFitsFile(filePath: filePath);
  }

  @override
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  }) {
    return bridge_api.apiAutoStretchImage(
      width: width,
      height: height,
      data: data,
    );
  }

  @override
  Future<void> renderFinishingPreview({
    required String inputFits,
    required String outputPng,
  }) {
    return const StretchPipelineService().renderFinishingPreview(
      inputFits: inputFits,
      outputPng: outputPng,
    );
  }

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents =>
      _polarAlignController.stream;

  @override
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  }) async {
    await bridge_api.apiStartPolarAlignment(
      exposureTime: exposureTime,
      stepSize: stepSize,
      binning: binning,
      isNorth: isNorth,
      manualRotation: manualRotation,
      rotateEast: rotateEast,
      gain: gain,
      offset: offset,
      solveTimeout: solveTimeout,
      startFromCurrent: startFromCurrent,
      autoCompleteThreshold: autoCompleteThreshold,
    );
  }

  @override
  Future<void> stopPolarAlignment() async {
    await bridge_api.apiStopPolarAlignment();
  }

  @override
  Future<void> startAllSkyPolarAlignment({
    required double exposureTime,
    required double solveTimeout,
    required int binning,
    required bool isNorth,
    required double acceptanceThresholdArcsec,
    required double iterationCadenceSecs,
    int? gain,
    int? offset,
  }) async {
    // Rust implementation lives in
    // `native/.../bridge/src/api/polar_alignment.rs::api_start_all_sky_polar_alignment`.
    // FRB bindings are regenerated under `apiStartAllSkyPolarAlignment` and
    // re-exported via `api_barrel.dart` — wire them directly. Errors from
    // Rust (missing solver / no devices / no observer location) surface as
    // a `SkotiqError` and propagate up; we do not swallow them.
    await bridge_api.apiStartAllSkyPolarAlignment(
      exposureTime: exposureTime,
      solveTimeout: solveTimeout,
      binning: binning,
      isNorth: isNorth,
      acceptanceThresholdArcsec: acceptanceThresholdArcsec,
      iterationCadenceSecs: iterationCadenceSecs,
      gain: gain,
      offset: offset,
    );
  }
}
