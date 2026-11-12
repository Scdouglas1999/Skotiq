// Image-output format defaults surfaced in Settings → Imaging. Owns the
// three knobs that affect how a captured frame is encoded on disk.
//
// Owns:
//   * imageFormat (FITS or XISF) and the XISF compression and checksums
//   * fileNamingPattern (template like `$TARGET_$FILTER_$DATE_$SEQ`)
//   * bitDepth (currently 16-bit only)
//
// Does NOT own:
//   * Save-path defaults → see `file_paths.dart`.
//   * Camera connect-time defaults (gain / offset / cooling) → see
//     `equipment.dart`.
//   * Live Pass/Reject grading → see `image_grading.dart`.
part of '../settings_provider.dart';

extension ImagingSettingsSection on AppSettingsNotifier {
  Future<void> setImageFormat(String value) =>
      _set(AppSettingDefs.imageFormat, value);

  Future<void> setXisfCompression(String value) =>
      _set(AppSettingDefs.xisfCompression, value);

  Future<void> setXisfChecksums(bool value) =>
      _set(AppSettingDefs.xisfChecksums, value);

  Future<void> setFileNamingPattern(String value) =>
      _set(AppSettingDefs.fileNamingPattern, value);

  Future<void> setBitDepth(String value) => _set(AppSettingDefs.bitDepth, value);
}
