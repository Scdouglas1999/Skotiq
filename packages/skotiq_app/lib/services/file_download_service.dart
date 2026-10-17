import 'dart:developer' as developer;
import 'dart:io';

import 'package:skotiq_core/skotiq_core.dart'
    show ExportTarget, chooseExportTarget;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Result of a "download this remote file to the device" flow.
///
/// Generic sibling of the image download in `image_download_service.dart`
/// (which delegates here): the host exposes several byte-streaming download
/// endpoints (full-res images, log files, calibration darks) and the
/// destination handling is identical for all of them — stream to a private
/// temp file, then share sheet on mobile / save picker on desktop.
enum FileDownloadStatus { saved, shared, cancelled, failed }

class FileDownloadOutcome {
  final FileDownloadStatus status;

  /// On-disk destination for [FileDownloadStatus.saved]; null otherwise.
  final String? savedPath;

  /// Human-readable failure reason for [FileDownloadStatus.failed].
  final String? error;

  const FileDownloadOutcome._(this.status, {this.savedPath, this.error});

  const FileDownloadOutcome.saved(String path)
      : this._(FileDownloadStatus.saved, savedPath: path);
  const FileDownloadOutcome.shared() : this._(FileDownloadStatus.shared);
  const FileDownloadOutcome.cancelled() : this._(FileDownloadStatus.cancelled);
  const FileDownloadOutcome.failed(String reason)
      : this._(FileDownloadStatus.failed, error: reason);

  bool get succeeded =>
      status == FileDownloadStatus.saved || status == FileDownloadStatus.shared;
}

/// Injection seam so widget tests can drive the destination step without a
/// native picker / share sheet. Production wiring is the platform default.
typedef DesktopSaveLocationPicker = Future<ExportTarget?> Function(
    String suggestedName);
typedef MobileFileShare = Future<ShareResult> Function(
    String filePath, String subject);

/// Fetch a remote file via [fetch] (which must stream the bytes to the path
/// it is given) and then hand it to the user:
///
///   * Desktop (Linux/macOS/Windows): a native "Save as…" picker; the temp
///     file is moved to the chosen location.
///   * Mobile (Android/iOS): the system share sheet (`share_plus`) so the
///     operator can drop it into Photos, Files, Drive, etc.
///
/// [fileName] names the delivered file and the share subject. [tempKey]
/// uniquifies the temp path so two concurrent downloads of same-named files
/// cannot collide.
Future<FileDownloadOutcome> downloadFileToDevice({
  required String fileName,
  required Future<void> Function(
    String localPath,
    void Function(double)? onProgress,
  ) fetch,
  String tempKey = 'file',
  void Function(double progress)? onProgress,
  // Test seams — default to the real platform behaviour.
  DesktopSaveLocationPicker? desktopSavePicker,
  MobileFileShare? mobileShare,
  Future<Directory> Function()? temporaryDirectory,
}) async {
  final safeName = fileName.trim();
  if (safeName.isEmpty) {
    return const FileDownloadOutcome.failed('File name is not valid.');
  }

  // Stream to a private temp file first. Downloading to temp (not straight to
  // the user's chosen path) keeps a half-written file out of their gallery if
  // the transfer aborts, and lets the mobile share sheet hand off a stable
  // file it fully owns.
  final Directory tmpDir;
  try {
    tmpDir = await (temporaryDirectory ?? getTemporaryDirectory)();
  } catch (e) {
    return FileDownloadOutcome.failed('Could not open a temp directory: $e');
  }
  final tempPath = p.join(
    tmpDir.path,
    'skotiq-dl',
    '$tempKey-${p.basename(safeName)}',
  );

  try {
    await fetch(tempPath, onProgress);
  } catch (e) {
    await _deleteQuietly(tempPath);
    return FileDownloadOutcome.failed(downloadErrorMessage(e));
  }

  final isMobile = Platform.isAndroid || Platform.isIOS;
  try {
    if (isMobile) {
      final share = mobileShare ??
          (path, subject) => Share.shareXFiles([XFile(path)], subject: subject);
      final result = await share(tempPath, safeName);
      // The temp file stays until the OS reclaims it; share targets may still
      // be reading it as this returns, so we deliberately do NOT delete here.
      if (result.status == ShareResultStatus.dismissed) {
        return const FileDownloadOutcome.cancelled();
      }
      return const FileDownloadOutcome.shared();
    }

    // [chooseExportTarget] rather than `getSaveLocation` directly: the latter
    // throws UnimplementedError on Android/iOS, so this branch must never be
    // the one a phone reaches. The mobile share path above already returned,
    // but going through the shared helper keeps that true if the branch is
    // ever restructured.
    final picker = desktopSavePicker ??
        (suggested) => chooseExportTarget(suggestedName: suggested);
    final target = await picker(safeName);
    if (target == null) {
      await _deleteQuietly(tempPath);
      return const FileDownloadOutcome.cancelled();
    }
    await File(tempPath).copy(target.path);
    await _deleteQuietly(tempPath);
    return FileDownloadOutcome.saved(target.path);
  } catch (e) {
    await _deleteQuietly(tempPath);
    return FileDownloadOutcome.failed('Could not save the file: $e');
  }
}

/// Extract the friendliest available message from a download failure.
String downloadErrorMessage(Object e) {
  // SkotiqException / IoException (thrown by the resumable downloader)
  // carry a user-facing `userMessage`, but the type isn't exported from the
  // core barrel — read it duck-typed rather than widening the export surface.
  try {
    final message = (e as dynamic).userMessage;
    if (message is String && message.trim().isNotEmpty) return message;
  } catch (_) {
    // Not one of our typed exceptions; fall through to a generic message.
  }
  return 'Download failed: $e';
}

Future<void> _deleteQuietly(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (e) {
    // The download outcome reported to the caller is unaffected, but these
    // temps are full-size images and logs — one we cannot remove is disk the
    // operator will never account for, so it must not vanish silently.
    developer.log(
      'Could not remove the temporary download file $path: $e',
      name: 'FileDownload',
      level: 900,
    );
  }
}
