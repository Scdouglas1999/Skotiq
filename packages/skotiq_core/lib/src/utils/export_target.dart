import 'dart:io';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';
import './skotiq_data_directory.dart';

/// Forces [chooseExportTarget] down the touch or desktop branch in tests.
///
/// Without it the touch branch is only exercisable by running the suite ON a
/// phone, so CI (Linux) reports green for a platform it never covered. Null in
/// production, where the real platform decides.
@visibleForTesting
bool? debugIsTouchPlatformOverride;

/// Where an export is about to be written, and how the user will get at it.
class ExportTarget {
  /// Absolute path to write to.
  final String path;

  /// Whether the file still has to be handed to the system share sheet for the
  /// user to reach it.
  ///
  /// True on Android/iOS, where [path] is inside the app's private sandbox and
  /// a "saved to `path`" message names a file the user can never open. The
  /// caller must pass the written file to `revealExportedFile` (or
  /// `Share.shareXFiles`) once the write completes. False on desktop, where the
  /// user chose the location themselves and it is already reachable.
  final bool needsShareSheet;

  const ExportTarget({required this.path, required this.needsShareSheet});
}

/// Resolve the destination for an export, per platform.
///
/// **Desktop** shows the native save dialog, exactly as before.
///
/// **Android / iOS** deliberately do NOT show a dialog. `file_selector` has no
/// save-dialog implementation on either platform — `file_selector_android`
/// does not override `getSavePath`, so the platform interface's base method
/// throws `UnimplementedError: getSavePath() has not been implemented.` Every
/// call site that asked for a save location was therefore dead on a phone:
/// exporting a sequence, a diagnostics dump, a finder chart, an equipment
/// profile or a backup produced only that error text. Observed on an API 35
/// emulator: "Failed to export: UnimplementedError: getSavePath() has not been
/// implemented."
///
/// So on touch platforms this picks a path under the app documents directory
/// and reports [ExportTarget.needsShareSheet] so the caller finishes the job
/// with the share sheet — the same route the working exports already take.
///
/// Returns null only when the user cancels the desktop dialog; the touch path
/// never cancels.
Future<ExportTarget?> chooseExportTarget({
  required String suggestedName,
  List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
  String? initialDirectory,
  String? confirmButtonText,
}) async {
  final isTouch =
      debugIsTouchPlatformOverride ?? (Platform.isAndroid || Platform.isIOS);
  if (isTouch) {
    final documents = await resolveSkotiqDocumentsDirectory();
    final directory = Directory('${documents.path}/Skotiq/exports');
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return ExportTarget(
      path: '${directory.path}/${sanitizeExportFileName(suggestedName)}',
      needsShareSheet: true,
    );
  }

  final location = await file_selector.getSaveLocation(
    initialDirectory: initialDirectory,
    suggestedName: suggestedName,
    acceptedTypeGroups: acceptedTypeGroups,
    confirmButtonText: confirmButtonText,
  );
  if (location == null) return null;
  return ExportTarget(path: location.path, needsShareSheet: false);
}

/// Strip characters that are not safe in a file name.
///
/// Suggested names are frequently user-authored — a sequence called
/// `M31 / Ha (v2)` would otherwise be read as a directory path and the write
/// would fail with a confusing "no such file or directory".
String sanitizeExportFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'export' : cleaned;
}
