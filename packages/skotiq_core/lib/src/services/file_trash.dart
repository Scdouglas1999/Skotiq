import 'dart:io';

/// Removes files the user chose to delete: into the platform's trash where
/// it has one, so they can be restored from there, else for good.
abstract interface class FileTrash {
  /// Whether removed files can be restored from the platform's trash.
  bool get restorable;

  /// Removes every existing file of [paths]. Paths that do not exist on this
  /// computer are skipped. Returns the paths that exist but could not be
  /// removed.
  Future<List<String>> remove(List<String> paths);
}

/// The trash of the platform this runs on: the desktop trash on Linux
/// (through `gio`), the Recycle Bin on Windows, the Finder's Trash on macOS.
/// Elsewhere, or on a Linux without `gio`, files are deleted for good.
class PlatformFileTrash implements FileTrash {
  PlatformFileTrash._(this._command);

  static Future<PlatformFileTrash> detect() async {
    if (Platform.isWindows) return PlatformFileTrash._(_windows);
    if (Platform.isMacOS) return PlatformFileTrash._(_macos);
    if (Platform.isLinux) {
      try {
        final found = await Process.run('which', ['gio']);
        if (found.exitCode == 0) return PlatformFileTrash._(_linux);
      } on ProcessException {
        // No `which`: no way to find gio either.
      }
    }
    return PlatformFileTrash._(null);
  }

  final Future<bool> Function(List<String>)? _command;

  @override
  bool get restorable => _command != null;

  @override
  Future<List<String>> remove(List<String> paths) async {
    final present = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) present.add(path);
    }
    final failed = <String>[];
    final command = _command;
    // A long list is sent in batches: command lines have a length limit.
    for (var i = 0; i < present.length; i += 200) {
      final batch = present.sublist(i, (i + 200).clamp(0, present.length));
      if (command != null && await command(batch)) continue;
      for (final path in batch) {
        if (command == null) {
          try {
            await File(path).delete();
          } on FileSystemException {
            failed.add(path);
          }
        } else if (await File(path).exists()) {
          failed.add(path);
        }
      }
    }
    return failed;
  }

  static Future<bool> _linux(List<String> paths) async =>
      (await Process.run('gio', ['trash', '--', ...paths])).exitCode == 0;

  static Future<bool> _macos(List<String> paths) async {
    final list = paths
        .map(
          (p) =>
              'POSIX file "${p.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
        )
        .join(', ');
    final result = await Process.run('osascript', [
      '-e',
      'tell application "Finder" to delete {$list}',
    ]);
    return result.exitCode == 0;
  }

  static Future<bool> _windows(List<String> paths) async {
    final quoted = paths.map((p) => "'${p.replaceAll("'", "''")}'").join(',');
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Add-Type -AssemblyName Microsoft.VisualBasic; '
          'foreach (\$p in @($quoted)) { '
          '[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(\$p, '
          "'OnlyErrorDialogs', 'SendToRecycleBin') }",
    ]);
    return result.exitCode == 0;
  }
}
