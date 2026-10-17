import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as path;

class UnsafeArchiveEntryException implements Exception {
  UnsafeArchiveEntryException(this.entryName, this.reason);

  final String entryName;
  final String reason;

  @override
  String toString() => 'Unsafe archive entry "$entryName": $reason';
}

/// Stream-extract `zipFile` into `destination`.
///
/// A release ZIP reaches ~256 MiB, so `zipFile.readAsBytes()` would load the
/// whole archive into the Dart heap and OOM a low-RAM imaging laptop. The
/// central directory is read off disk via [InputFileStream] and each entry is
/// written through [OutputFileStream], so neither input nor output ever fully
/// materialises in memory.
Future<void> extractZipSafely(File zipFile, Directory destination) async {
  final input = InputFileStream(zipFile.path);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    await extractArchiveSafely(archive, destination);
  } finally {
    await input.close();
  }
}

Future<void> extractArchiveSafely(
  Archive archive,
  Directory destination,
) async {
  await destination.create(recursive: true);
  final destinationRoot = await destination.resolveSymbolicLinks();

  // Paths to mark executable, grouped by the mode to give them.
  final executables = <int, List<String>>{};

  for (final entry in archive) {
    final relativePath = _safeArchiveEntryPath(entry.name);
    final outputPath = path.joinAll([
      destinationRoot,
      ...relativePath.split('/'),
    ]);

    if (entry.isFile) {
      final outputFile = File(outputPath);
      await outputFile.parent.create(recursive: true);
      await _assertInsideDestination(destinationRoot, outputFile.parent);
      if (await outputFile.exists()) {
        await _assertInsideDestination(destinationRoot, outputFile);
      }
      // Stream entry content directly to disk via OutputFileStream so a
      // multi-hundred-megabyte file never lands in the Dart heap.
      final output = OutputFileStream(outputPath);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      final mode = _executableMode(entry.mode);
      if (mode != null) {
        (executables[mode] ??= <String>[]).add(outputPath);
      }
    } else {
      final outputDirectory = Directory(outputPath);
      await outputDirectory.create(recursive: true);
      await _assertInsideDestination(destinationRoot, outputDirectory);
    }
  }

  for (final entry in executables.entries) {
    await _chmod(entry.key, entry.value);
  }
}

/// The permission bits to restore on an extracted file, or null to leave the
/// default the file was created with.
///
/// Only executables are restored. The updater copies each staged file into
/// the install directory with the mode it has in staging, so a binary that
/// lost its executable bit here is a binary that no longer runs after the
/// update: the application, its launcher and the updater itself. Other files
/// keep the process default, and group/other write is never granted from an
/// archive. Windows has no such bits, and an archive written there records
/// none.
int? _executableMode(int archiveMode) {
  if (Platform.isWindows) return null;
  final permissions = archiveMode & 0x1FF;
  if (permissions & 0x49 == 0) return null;
  return permissions & 0x1ED;
}

Future<void> _chmod(int mode, List<String> paths) async {
  // dart:io cannot set a file mode, so this goes through chmod(1), once per
  // distinct mode rather than once per file.
  const batch = 200;
  for (var i = 0; i < paths.length; i += batch) {
    final chunk = paths.sublist(
      i,
      i + batch > paths.length ? paths.length : i + batch,
    );
    final result = await Process.run('chmod', [
      mode.toRadixString(8),
      ...chunk,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restore executable permissions (chmod exited '
        '${result.exitCode}: ${result.stderr})',
        chunk.first,
      );
    }
  }
}

String _safeArchiveEntryPath(String entryName) {
  final portableName = entryName.replaceAll('\\', '/');
  if (portableName.isEmpty) {
    throw UnsafeArchiveEntryException(entryName, 'empty path');
  }
  if (path.posix.isAbsolute(portableName) ||
      RegExp(r'^[a-zA-Z]:/').hasMatch(portableName) ||
      portableName.startsWith('//')) {
    throw UnsafeArchiveEntryException(entryName, 'absolute path');
  }

  final normalized = path.posix.normalize(portableName);
  if (normalized == '.' ||
      normalized == '..' ||
      normalized.startsWith('../') ||
      normalized.contains('/../')) {
    throw UnsafeArchiveEntryException(entryName, 'path traversal');
  }
  if (normalized.split('/').any((part) => part.isEmpty || part == '.')) {
    throw UnsafeArchiveEntryException(entryName, 'invalid path component');
  }

  return normalized;
}

Future<void> _assertInsideDestination(
  String destinationRoot,
  FileSystemEntity entity,
) async {
  final resolvedPath = await entity.resolveSymbolicLinks();
  if (!_isWithinDirectory(destinationRoot, resolvedPath)) {
    throw UnsafeArchiveEntryException(
      entity.path,
      'resolved outside extraction directory',
    );
  }
}

bool _isWithinDirectory(String root, String candidate) {
  final normalizedRoot = _normalizeForComparison(path.normalize(root));
  final normalizedCandidate = _normalizeForComparison(
    path.normalize(candidate),
  );
  if (normalizedCandidate == normalizedRoot) {
    return true;
  }

  final rootWithSeparator = normalizedRoot.endsWith(path.separator)
      ? normalizedRoot
      : '$normalizedRoot${path.separator}';
  return normalizedCandidate.startsWith(rootWithSeparator);
}

String _normalizeForComparison(String value) {
  return Platform.isWindows ? value.toLowerCase() : value;
}
