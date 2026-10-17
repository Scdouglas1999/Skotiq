part of '../post_session_integration_service.dart';

/// Replace the path's extension (`master.fits` → `master.png`). If there is no
/// `.` in the file segment, the new extension is appended.
String _swapExtension(String path, String newExt) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash) return '$path$newExt';
  return '${path.substring(0, dot)}$newExt';
}

/// Insert [suffix] before the extension (`master.fits` →
/// `master_rejmap.fits`).
String _suffixBeforeExtension(String path, String suffix) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash) return '$path$suffix';
  return '${path.substring(0, dot)}$suffix${path.substring(dot)}';
}
