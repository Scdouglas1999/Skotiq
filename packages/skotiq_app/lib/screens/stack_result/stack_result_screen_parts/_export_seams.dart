// Save-picker, share and stretch-engine seams plus their providers.
part of '../stack_result_screen.dart';

/// Signature of the save-file picker used by the Stack Result viewer to choose
/// an export destination.
///
/// Defaults to [_defaultSavePicker]; injected via
/// [stackResultSavePickerProvider] so widget tests can stub the picker without
/// invoking platform channels.
typedef StackResultSavePicker = Future<String?> Function({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
});

/// Resolve the export destination for [fileName].
///
/// Goes through [chooseExportTarget] rather than `FilePicker.saveFile`: on
/// Android/iOS `file_picker` throws `ArgumentError('Bytes are required on
/// Android & iOS when saving a file.')` when called without `bytes:`, which
/// dead-ended all four actions in the phone-only overflow menu (the exported
/// bytes don't exist yet at picker time — the service renders them into the
/// chosen path). Desktop still gets the native save dialog; on touch the path
/// is inside the app sandbox and the caller finishes with the share sheet.
Future<String?> _defaultSavePicker({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
}) async {
  final target = await chooseExportTarget(
    suggestedName: fileName,
    acceptedTypeGroups: [
      XTypeGroup(
        label: allowedExtensions.map((e) => e.toUpperCase()).join(' / '),
        extensions: allowedExtensions,
      ),
    ],
    confirmButtonText: dialogTitle,
  );
  return target?.path;
}

/// Signature of the OS share-sheet call used after an export completes.
///
/// Defaults to [Share.shareXFiles]; injected via [stackResultShareProvider] so
/// widget tests can assert the share without invoking the platform plugin.
typedef StackResultShare = Future<void> Function(
  String filePath, {
  required String text,
});

Future<void> _defaultShare(String filePath, {required String text}) async {
  await Share.shareXFiles([XFile(filePath)], text: text);
}

/// Override point for the save-file picker (tests stub this).
final stackResultSavePickerProvider =
    Provider<StackResultSavePicker>((ref) => _defaultSavePicker);

/// Override point for the OS share-sheet call (tests stub this).
final stackResultShareProvider =
    Provider<StackResultShare>((ref) => _defaultShare);

/// The stacking-engine seam that auto-stretches the in-memory integrated buffer
/// for display.
///
/// Production uses [BridgeStackingEngineSeam]: a 1-channel (mono) buffer goes
/// through the native STF (`apiAutoStretchImage`), while a 3-channel
/// interleaved-RGB16 buffer goes through the seam's per-channel colour STF.
/// Exposed as a provider so widget tests can stub the auto-stretch without
/// loading the native dynamic library.
final stackResultStretchEngineProvider =
    Provider<StackingEngineSeam>((ref) => const BridgeStackingEngineSeam());

/// The display stretch applied to the integrated buffer in the viewer.
///
/// The viewer offers the two renderings it can produce *honestly* from the
/// retained u16 buffer: a MAD-based PixInsight Screen-Transfer-Function (STF)
/// auto-stretch, and a linear (unstretched) min/max mapping. Both honour the
/// buffer's channel layout — a mono plane renders to grayscale, an interleaved
/// RGB16 (OSC) integration renders in colour with a per-channel stretch.
/// Stretch methods the in-memory engine cannot apply are NOT offered: a control
/// that silently produced identical output would claim a rendering the viewer
/// never made.
enum StackViewerStretch {
  /// STF auto-stretch: the native single-channel STF
  /// ([ImagingBackend.autoStretchImage]) for a mono buffer, or the
  /// stacking-engine seam's per-channel colour STF for an interleaved-RGB16
  /// buffer.
  autoStf,

  /// Linear min/max normalisation: grayscale for a mono buffer, per-channel
  /// colour for an interleaved-RGB16 buffer.
  linear,
}
