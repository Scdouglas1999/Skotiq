part of '../flat_wizard_provider.dart';

/// Creates an output directory only when this process owns the filesystem.
/// A remote controller sends the path to the imaging host, which creates the
/// parent tree immediately before writing the FITS file.
@visibleForTesting
Future<void> prepareFlatOutputDirectory(
  String path, {
  required bool createLocally,
}) async {
  if (!createLocally) return;
  await Directory(path).create(recursive: true);
}

/// Validates a controller-supplied output directory against the host's
/// allow-listed, writable roots and returns the normalized host path.
@visibleForTesting
Future<String> validateRemoteFlatOutputDirectory(
  NetworkBackend backend,
  String path,
) async {
  final validation = await backend.validateRemoteDirectory(
    path,
    mustExist: true,
    mustBeWritable: true,
  );
  if (validation['valid'] != true) {
    final detail =
        validation['error'] ??
        (validation['exists'] == false
            ? 'the directory does not exist on the host'
            : 'the directory is not writable on the host');
    throw StateError('Invalid host flat-frame folder: $detail');
  }
  final normalized = validation['normalizedPath'];
  return normalized is String && normalized.isNotEmpty ? normalized : path;
}

/// Provider for sky brightness tracker (sky flats mode)
final skyBrightnessTrackerProvider = Provider<SkyBrightnessTracker>((ref) {
  return SkyBrightnessTracker();
});

/// Strip path separators and characters illegal on common filesystems from a
/// filename/subfolder component built from user/hardware-supplied filter
/// names (which can contain `/`, `:`, etc.). Never returns empty.
String _sanitizeComponent(String raw) {
  var s = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Trim leading/trailing dots and spaces (Windows rejects trailing dots).
  s = s.replaceAll(RegExp(r'^[.\s]+'), '').replaceAll(RegExp(r'[.\s]+$'), '');
  return s.isEmpty ? 'unnamed' : s;
}

String _two(int v) => v.toString().padLeft(2, '0');

String _fmtDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

String _fmtStamp(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}'
    '_${_two(d.hour)}${_two(d.minute)}${_two(d.second)}';
