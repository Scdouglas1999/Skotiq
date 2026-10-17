import 'dart:convert';
import 'dart:io';

const _defaultBundlePath = 'apps/desktop/build/windows/x64/runner/Release';
const _jsonOutputPath = 'docs/production-readiness/windows-bundle-audit.json';
const _markdownOutputPath = 'docs/production-readiness/windows-bundle-audit.md';

const _requiredFiles = <String>[
  'skotiq_desktop.exe',
  'skotiq_bridge.dll',
  'flutter_windows.dll',
  'sqlite3.dll',
  'libraw.dll',
  'libwebrtc.dll',
  'data/app.so',
  'data/icudtl.dat',
  // `AssetManifest.bin`, not `.json`: Flutter replaced the JSON asset manifest
  // with a binary one, so requiring the old name failed against every modern
  // build. `FontManifest.json` below is still JSON — the two genuinely differ.
  'data/flutter_assets/AssetManifest.bin',
  'data/flutter_assets/FontManifest.json',
  'data/flutter_assets/NativeAssetsManifest.json',
  'data/flutter_assets/web_dashboard/index.html',
  'data/flutter_assets/web_dashboard/css/dashboard.css',
  'data/flutter_assets/web_dashboard/js/api.js',
  'data/flutter_assets/web_dashboard/js/app.js',
];

/// Filename prefixes that must be present in the bundle.
///
/// Deliberately EMPTY. This required `FF`, which matches the Fujifilm camera
/// SDK's per-model modules (`FF0000API.dll` … `FF0020API.dll`, copied only by
/// `scripts/copy_fujifilm_sdk.ps1` on a developer machine). `release.yml` never
/// copies them, and it must not: the documented policy in
/// `docs/known-limitations.md` is that official archives do not redistribute
/// vendor SDK libraries, and native device paths are capability-gated on the
/// user installing them.
///
/// So the audit was requiring a file the release is forbidden to ship, and
/// could never pass for a public bundle — it only passed on a developer machine
/// that had run the vendor-SDK copy script. Auditing the shipped archive is the
/// point, so the requirement is gone.
const _requiredGlobPrefixes = <String>[];

const _disallowedFileNames = <String>{'.gitkeep', '.DS_Store', 'Thumbs.db'};

const _disallowedExtensions = <String>{'.ilk', '.pdb', '.tmp', '.log'};

const _disallowedSegments = <String>{
  '.git',
  '.dart_tool',
  'coverage',
  'test',
  'tests',
};

void main(List<String> args) {
  final bundlePath = args.isEmpty ? _defaultBundlePath : args.first;
  final bundleDir = Directory(bundlePath);
  if (!bundleDir.existsSync()) {
    final missing = <String>[
      ..._requiredFiles,
      for (final prefix in _requiredGlobPrefixes) '$prefix*.dll',
    ];
    final report = {
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'bundlePath': bundleDir.path,
      'bundleExists': false,
      'fileCount': 0,
      'requiredFileCount': missing.length,
      'missingRequiredFileCount': missing.length,
      'disallowedFileCount': 0,
      'passed': false,
      'missingRequiredFiles': missing,
      'disallowedFiles': const <String>[],
    };
    Directory('docs/production-readiness').createSync(recursive: true);
    File(
      _jsonOutputPath,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    File(_markdownOutputPath).writeAsStringSync(
      _renderMarkdown(
        bundlePath: bundleDir.path,
        fileCount: 0,
        missing: missing,
        disallowed: const <String>[],
      ),
    );
    stderr.writeln('Windows bundle not found: $bundlePath');
    exit(2);
  }

  final files = bundleDir
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
  final relativeFiles =
      files.map((file) => _relativePath(bundleDir, file)).toList()..sort();
  final relativeSet = relativeFiles.toSet();

  final missing = <String>[];
  for (final required in _requiredFiles) {
    final file = File('${bundleDir.path}${Platform.pathSeparator}$required');
    if (!relativeSet.contains(required) || !file.existsSync()) {
      missing.add(required);
      continue;
    }
    if (file.lengthSync() <= 0) {
      missing.add('$required (empty)');
    }
  }

  for (final prefix in _requiredGlobPrefixes) {
    final hasMatch = relativeFiles.any(
      (path) => path.startsWith(prefix) && path.toLowerCase().endsWith('.dll'),
    );
    if (!hasMatch) {
      missing.add('$prefix*.dll');
    }
  }

  final disallowed = relativeFiles.where(_isDisallowed).toList();

  stdout.writeln('Windows bundle audit complete.');
  stdout.writeln('Bundle: ${bundleDir.path}');
  stdout.writeln('Files scanned: ${relativeFiles.length}');
  stdout.writeln('Required files missing: ${missing.length}');
  stdout.writeln('Disallowed files: ${disallowed.length}');

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'bundlePath': bundleDir.path,
    'bundleExists': true,
    'fileCount': relativeFiles.length,
    'requiredFileCount': _requiredFiles.length + _requiredGlobPrefixes.length,
    'missingRequiredFileCount': missing.length,
    'disallowedFileCount': disallowed.length,
    'passed': missing.isEmpty && disallowed.isEmpty,
    'missingRequiredFiles': missing,
    'disallowedFiles': disallowed,
  };
  Directory('docs/production-readiness').createSync(recursive: true);
  File(
    _jsonOutputPath,
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  File(_markdownOutputPath).writeAsStringSync(
    _renderMarkdown(
      bundlePath: bundleDir.path,
      fileCount: relativeFiles.length,
      missing: missing,
      disallowed: disallowed,
    ),
  );
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (missing.isNotEmpty) {
    stderr.writeln('Missing required Windows bundle files:');
    for (final path in missing) {
      stderr.writeln('- $path');
    }
  }

  if (disallowed.isNotEmpty) {
    stderr.writeln('Disallowed Windows bundle files:');
    for (final path in disallowed) {
      stderr.writeln('- $path');
    }
  }

  if (missing.isNotEmpty || disallowed.isNotEmpty) {
    exit(1);
  }
}

bool _isDisallowed(String relativePath) {
  final parts = relativePath.split('/');
  if (parts.any(_disallowedSegments.contains)) {
    return true;
  }

  final fileName = parts.isEmpty ? relativePath : parts.last;
  if (_disallowedFileNames.contains(fileName)) {
    return true;
  }

  final lower = fileName.toLowerCase();
  return _disallowedExtensions.any(lower.endsWith);
}

String _relativePath(Directory root, File file) {
  var rootPath = root.absolute.path;
  final filePath = file.absolute.path;
  if (!rootPath.endsWith(Platform.pathSeparator)) {
    rootPath += Platform.pathSeparator;
  }
  return filePath.substring(rootPath.length).replaceAll('\\', '/');
}

String _renderMarkdown({
  required String bundlePath,
  required int fileCount,
  required List<String> missing,
  required List<String> disallowed,
}) {
  final buffer = StringBuffer()
    ..writeln('# Windows Bundle Audit')
    ..writeln()
    ..writeln('- Bundle: `$bundlePath`')
    ..writeln('- Files scanned: `$fileCount`')
    ..writeln('- Required files missing: `${missing.length}`')
    ..writeln('- Disallowed files: `${disallowed.length}`')
    ..writeln();

  if (missing.isEmpty && disallowed.isEmpty) {
    buffer.writeln('Windows bundle audit passed.');
    return buffer.toString();
  }

  if (missing.isNotEmpty) {
    buffer
      ..writeln('## Missing Required Files')
      ..writeln();
    for (final path in missing) {
      buffer.writeln('- `$path`');
    }
  }

  if (disallowed.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Disallowed Files')
      ..writeln();
    for (final path in disallowed) {
      buffer.writeln('- `$path`');
    }
  }

  return buffer.toString();
}
