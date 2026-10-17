// Log export scope, target-picker seam and default export directory.
part of '../log_viewer.dart';

/// What a log export covers.
enum LogExportScope {
  /// Only the entries the viewer is currently showing, after its filters.
  visible,

  /// Every retained on-disk log file plus the in-memory Dart entries.
  fullHistory,
}

/// Resolves where a log export is written. Injected so a widget test can drive
/// the real Export button without a native save dialog.
typedef LogExportTargetPicker = Future<ExportTarget?> Function(
  String suggestedName,
);

/// Exports go through a picker and default to `exports/`, the directory every
/// other in-app export uses, with a size warning: a log bundle is tens of
/// megabytes of concatenated rotated files.
final logExportTargetPickerProvider = Provider<LogExportTargetPicker>((ref) {
  return (suggestedName) async => chooseExportTarget(
        suggestedName: suggestedName,
        initialDirectory: await defaultLogExportDirectory(),
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Text files', extensions: ['txt']),
        ],
      );
});

/// The directory the app's other exports go to, created on demand.
///
/// Returns null when it cannot be resolved or created, which leaves the save
/// dialog at its own default rather than failing the export.
Future<String?> defaultLogExportDirectory() async {
  try {
    final documents = await resolveSkotiqDocumentsDirectory();
    final directory = Directory('${documents.path}/Skotiq/exports');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory.path;
  } catch (_) {
    return null;
  }
}
