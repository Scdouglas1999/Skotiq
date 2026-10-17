import 'dart:io';

/// Folds the last hardcoded corner radii in the screen layer onto the
/// Observatory radius scale.
///
/// There are four radii in the design language and no others — 4 for chips, 6
/// for controls, 8 for panels, 12 for the floating layer
/// (`docs/design/overhaul/03-tokens.md` §3.2). Nine hundred and seventy-nine
/// call sites already reach the scale through `SkotiqTokens.radius*` and
/// took the new values without an edit; what is left is 110
/// `BorderRadius.circular(<n>)` and 29 bare `Radius.circular(<n>)` literals
/// that were never migrated, and each of those is a number a reviewer cannot
/// tell from any other number.
///
/// Each literal is rounded to the NEAREST scale value, per the table in §3.2:
///
///   2, 3, 4        -> radiusXs (4)
///   5, 6, 7        -> radiusSm (6)
///   8, 9, 10       -> radiusLg (8)
///   11 and above   -> radiusXl (12)
///   999            -> radiusFull (left alone; it means "a pill", not a radius)
///
/// The substitution is `BorderRadius.circular(SkotiqTokens.radiusLg)`
/// rather than the `SkotiqTokens.borderRadiusLg` object the spec names,
/// because the convenience objects are `static final` and would break every
/// `const` call site. The `radius*` doubles are `const`, carry the identical
/// value, and match how the existing 979 sites are already written.
///
/// Usage:
///   dart run tools/production/migrate_radius_literals.dart --dry-run
///   dart run tools/production/migrate_radius_literals.dart
///   dart run tools/production/migrate_radius_literals.dart --root=<dir>
///
/// Exit codes: 0 on success, 2 on a bad argument or a missing root.
void main(List<String> args) {
  var root = 'packages/skotiq_app/lib';
  var dryRun = false;
  final skipped = <String>[
    // Wave 1 owns the shell and wave 2 owns the shared components; both are in
    // flight on their own branches and will fold their own literals. Editing
    // them here would only hand those agents a conflict.
    'packages/skotiq_app/lib/screens/shell/',
    'packages/skotiq_ui/lib/src/components/',
  ];

  for (final arg in args) {
    if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg.startsWith('--root=')) {
      root = arg.substring('--root='.length);
    } else if (arg.startsWith('--skip=')) {
      skipped.add(arg.substring('--skip='.length));
    } else {
      stderr.writeln('migrate-radius-literals: unknown argument: $arg');
      exit(2);
    }
  }

  final rootDir = Directory(root);
  if (!rootDir.existsSync()) {
    stderr.writeln('migrate-radius-literals: root not found: $root');
    exit(2);
  }

  /// The literal value -> the token that replaces it.
  String tokenFor(double value) {
    if (value <= 4.5) return 'radiusXs';
    if (value <= 7.5) return 'radiusSm';
    if (value <= 10.5) return 'radiusLg';
    return 'radiusXl';
  }

  // `(?<!Border)` keeps the bare `Radius.circular(n)` arm from also matching
  // the tail of `BorderRadius.circular(n)`, which the first arm owns.
  final pattern = RegExp(
    r'\b(?<!Border)(BorderRadius|Radius)\.circular\(\s*(\d+(?:\.\d+)?)\s*\)',
  );

  final files =
      rootDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('.g.dart'))
          .where((f) => !f.path.endsWith('.freezed.dart'))
          .where(
            (f) =>
                !skipped.any((s) => f.path.replaceAll('\\', '/').contains(s)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var totalEdits = 0;
  var filesTouched = 0;
  var importsAdded = 0;
  final byValue = <String, int>{};
  final needsImport = <String>[];
  final partsNeedingParentImport = <String>[];

  for (final file in files) {
    final original = file.readAsStringSync();
    var replaced = 0;

    final updated = original.replaceAllMapped(pattern, (m) {
      // 999 is `radiusFull` and does not mean "a corner": it means "make this
      // a pill". Rounding it to 12 would square off every avatar in the app.
      final value = double.parse(m[2]!);
      if (value >= 100) return m[0]!;
      replaced++;
      byValue['${m[2]}'] = (byValue['${m[2]}'] ?? 0) + 1;
      return '${m[1]}.circular(SkotiqTokens.${tokenFor(value)})';
    });

    if (replaced == 0) continue;

    var withImport = updated;
    if (!_importsSkotiqUi(updated)) {
      if (_isPart(updated)) {
        // A part cannot carry its own imports — it sees the library's. Adding
        // one here does not just fail to help, it makes the file unparseable.
        // The parent gets the import instead, resolved below.
        partsNeedingParentImport.add(file.path);
      } else {
        withImport = _addSkotiqUiImport(updated);
        importsAdded++;
        needsImport.add(file.path);
      }
    }

    totalEdits += replaced;
    filesTouched++;
    if (!dryRun) file.writeAsStringSync(withImport);
  }

  // A part that needs the token gets it from its library. Resolve the `part
  // of` target, walk up until a real library file is reached (parts nest), and
  // add the import there once.
  final parentsFixed = <String>{};
  for (final partPath in partsNeedingParentImport) {
    final library = _resolveLibraryOf(File(partPath));
    if (library == null) {
      stderr.writeln(
        'migrate-radius-literals: could not resolve the library of $partPath; '
        'add the skotiq_ui import by hand',
      );
      continue;
    }
    final source = library.readAsStringSync();
    if (_importsSkotiqUi(source)) continue;
    if (!parentsFixed.add(library.path)) continue;
    importsAdded++;
    needsImport.add('${library.path}  (for its part)');
    if (!dryRun) library.writeAsStringSync(_addSkotiqUiImport(source));
  }

  stdout.writeln('migrate-radius-literals${dryRun ? " (dry run)" : ""}');
  stdout.writeln('  root         : $root');
  stdout.writeln('  skipped      : ${skipped.join(", ")}');
  stdout.writeln('  files scanned: ${files.length}');
  stdout.writeln('  files changed: $filesTouched');
  stdout.writeln('  literals     : $totalEdits');
  stdout.writeln('  imports added: $importsAdded');
  final ranked = byValue.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in ranked) {
    stdout.writeln(
      '    ${e.value.toString().padLeft(4)}  '
      'circular(${e.key}) -> ${tokenFor(double.parse(e.key))}',
    );
  }
  for (final path in needsImport) {
    stdout.writeln('  + import skotiq_ui: $path');
  }
}

bool _importsSkotiqUi(String source) =>
    source.contains("package:skotiq_ui/skotiq_ui.dart");

final _partOf = RegExp(r"^part of '([^']+)';", multiLine: true);

bool _isPart(String source) => _partOf.hasMatch(source);

/// Walks `part of` links up to the library that owns [file].
File? _resolveLibraryOf(File file) {
  var current = file;
  for (var hop = 0; hop < 8; hop++) {
    final match = _partOf.firstMatch(current.readAsStringSync());
    if (match == null) return current;
    final target = File(
      Uri.file(
        current.parent.path + Platform.pathSeparator + match[1]!,
      ).toFilePath(),
    );
    final normalized = File(target.uri.normalizePath().toFilePath());
    if (!normalized.existsSync()) return null;
    current = normalized;
  }
  return null;
}

/// Adds the `skotiq_ui` import after the last `package:` import, which is
/// where `dart format` and the repo's import ordering already put it.
String _addSkotiqUiImport(String source) {
  const line = "import 'package:skotiq_ui/skotiq_ui.dart';";
  final imports = RegExp(
    r"^import '[^']+';$",
    multiLine: true,
  ).allMatches(source).toList();
  if (imports.isEmpty) return '$line\n$source';
  final last = imports.last;
  return source.substring(0, last.end) + '\n$line' + source.substring(last.end);
}
