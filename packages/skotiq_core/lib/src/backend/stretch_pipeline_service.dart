import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

/// Renders an on-disk linear FITS into a viewable, auto-stretched PNG.
///
/// This is the FITS -> auto-stretch -> RGBA -> PNG pipeline the Session Review
/// workbench uses to produce a preview for the finishing-artifact FITS files
/// (background-extraction / deconvolution / star-reduction passes write a
/// linear FITS only — no preview). It lives behind [ImagingBackend] so UI code
/// reaches it through the backend role rather than calling the native bridge
/// directly.
///
/// Every step is a native bridge call:
///   1. [bridge.apiReadFitsLinearData] — read the linear FITS for its
///      dimensions (the width/height the PNG must be written at).
///   2. [bridge.apiCalculateAutoStretch] — compute the MAD/STF auto-stretch
///      parameters (the same screen-transfer-function the integration preview
///      uses).
///   3. [bridge.apiApplyStretch] — apply those parameters to produce the 8-bit
///      RGBA display buffer.
///   4. [bridge.apiSaveRgbaPngFile] — write the sibling preview PNG.
///
/// All four calls run on the host that owns the FITS file, so this is a
/// host-local operation; remote (network) backends cannot run it and surface
/// that explicitly rather than guessing.
class StretchPipelineService {
  const StretchPipelineService();

  /// Read the linear FITS at [inputFits], auto-stretch it, and write the
  /// resulting display image as a PNG at [outputPng].
  Future<void> renderFinishingPreview({
    required String inputFits,
    required String outputPng,
  }) async {
    final dims = await bridge.apiReadFitsLinearData(filePath: inputFits);
    final params = await bridge.apiCalculateAutoStretch(filePath: inputFits);
    final rgba = await bridge.apiApplyStretch(
      filePath: inputFits,
      params: params,
    );
    await bridge.apiSaveRgbaPngFile(
      filePath: outputPng,
      width: dims.width,
      height: dims.height,
      rgba: rgba,
    );
  }
}
