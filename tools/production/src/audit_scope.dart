import 'dart:io';

const defaultScopePath = 'docs/production-readiness/audit-scope.yaml';

/// The scan scope shared by the production audit gates, loaded from
/// `docs/production-readiness/audit-scope.yaml`. All paths are relative to
/// the current directory (the repository root) with forward slashes.
class AuditScope {
  final String path;
  final List<String> runtimeInclude;
  final Set<String> runtimeExcludeDirs;
  final List<String> runtimeExcludeGlobs;
  final List<String> policyRoots;
  final Set<String> policyExcludeDirs;
  final List<String> policyExcludeGlobs;
  final List<String> outOfScope;

  AuditScope._({
    required this.path,
    required this.runtimeInclude,
    required this.runtimeExcludeDirs,
    required this.runtimeExcludeGlobs,
    required this.policyRoots,
    required this.policyExcludeDirs,
    required this.policyExcludeGlobs,
    required this.outOfScope,
  });

  /// Loads the scope named by `--scope`, or the default file. A missing or
  /// empty scope is a configuration error: the gates carry no built-in copy.
  static AuditScope fromArgs(List<String> args) =>
      load(argValue(args, '--scope') ?? defaultScopePath);

  static AuditScope load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('Audit scope file not found: $path');
      exit(2);
    }
    final doc = _parse(file.readAsLinesSync());
    List<String> list(String section, String key) =>
        doc[section]?[key] ?? const <String>[];
    final scope = AuditScope._(
      path: path,
      runtimeInclude: list('runtime', 'include'),
      runtimeExcludeDirs: list('runtime', 'exclude_dirs').toSet(),
      runtimeExcludeGlobs: list('runtime', 'exclude_globs'),
      policyRoots: list('policy', 'roots'),
      policyExcludeDirs: list('policy', 'exclude_dirs').toSet(),
      policyExcludeGlobs: list('policy', 'exclude_globs'),
      outOfScope: list('coverage', 'out_of_scope'),
    );
    if (scope.runtimeInclude.isEmpty || scope.policyRoots.isEmpty) {
      stderr.writeln(
        'Audit scope $path must define runtime.include and policy.roots.',
      );
      exit(2);
    }
    return scope;
  }

  /// Runtime files, sorted. [extensions] are lower-case with the dot.
  List<String> runtimeFiles({Set<String>? extensions}) {
    final include = runtimeInclude.map(globToRegExp).toList();
    final exclude = runtimeExcludeGlobs.map(globToRegExp).toList();
    final out = <String>[];
    for (final root in runtimeInclude.map(_literalPrefix).toSet()) {
      _walk(root, runtimeExcludeDirs, (path) {
        if (extensions != null && !extensions.contains(extensionOf(path))) {
          return;
        }
        if (!include.any((g) => g.hasMatch(path)) ||
            exclude.any((g) => g.hasMatch(path))) {
          return;
        }
        out.add(path);
      });
    }
    out.sort();
    return out;
  }

  /// Every file under the policy roots, sorted.
  List<String> policyFiles() {
    final exclude = policyExcludeGlobs.map(globToRegExp).toList();
    final out = <String>[];
    for (final root in policyRoots) {
      _walk(root, policyExcludeDirs, (path) {
        if (!exclude.any((g) => g.hasMatch(path))) {
          out.add(path);
        }
      });
    }
    out.sort();
    return out;
  }

  bool isRuntimePath(String path) {
    if (path.split('/').any(runtimeExcludeDirs.contains)) {
      return false;
    }
    return runtimeInclude.any((g) => globToRegExp(g).hasMatch(path)) &&
        !runtimeExcludeGlobs.any((g) => globToRegExp(g).hasMatch(path));
  }

  /// Packages and crates that contribute no file to [scanned] and are not
  /// listed under `coverage.out_of_scope`.
  List<String> uncoveredUnits(Iterable<String> scanned) {
    final covered = <String>{};
    for (final path in scanned) {
      final segments = path.split('/');
      for (var i = 1; i < segments.length; i++) {
        covered.add(segments.sublist(0, i).join('/'));
      }
    }
    final prune = {...runtimeExcludeDirs, 'node_modules'};
    final units = <String>[];
    void visit(String dir) {
      final List<FileSystemEntity> entries;
      try {
        entries = Directory(dir).listSync(followLinks: false);
      } on FileSystemException {
        return;
      }
      final names = {for (final e in entries) _basename(e.path): e};
      if (dir != '.') {
        final isDartPackage =
            names['pubspec.yaml'] is File && names['lib'] is Directory;
        final isRustCrate =
            names['Cargo.toml'] is File && names['src'] is Directory;
        if (isDartPackage || isRustCrate) {
          units.add(dir);
        }
      }
      for (final entry in names.entries) {
        if (entry.value is! Directory ||
            entry.key.startsWith('.') ||
            prune.contains(entry.key)) {
          continue;
        }
        visit(dir == '.' ? entry.key : '$dir/${entry.key}');
      }
    }

    visit('.');
    units.sort();
    return units
        .where(
          (unit) =>
              !covered.contains(unit) &&
              !outOfScope.any((o) => unit == o || unit.startsWith('$o/')),
        )
        .toList();
  }

  /// Fails the process when the scan lost a package or crate, or when an
  /// explicit `--min-files` floor is not met.
  void assertCoverage(String gate, List<String> scanned, List<String> args) {
    final minFiles =
        argValue(args, '--min-files') ??
        argValue(args, '--assert-at-least-files-scanned');
    if (minFiles != null) {
      final required = int.tryParse(minFiles);
      if (required == null) {
        stderr.writeln('Invalid --min-files value: $minFiles');
        exit(2);
      }
      if (scanned.length < required) {
        stderr.writeln(
          '$gate scanned ${scanned.length} files; required >= $required',
        );
        exit(1);
      }
    }
    final uncovered = uncoveredUnits(scanned);
    if (uncovered.isNotEmpty) {
      stderr.writeln(
        '$gate scans no file from these packages/crates. Add them to '
        'runtime.include or coverage.out_of_scope in $path:',
      );
      for (final unit in uncovered) {
        stderr.writeln('  $unit');
      }
      exit(1);
    }
  }

  static void _walk(
    String root,
    Set<String> excludeDirs,
    void Function(String path) onFile,
  ) {
    final dir = Directory(root);
    if (!dir.existsSync()) {
      return;
    }
    for (final entity in dir.listSync(followLinks: false)) {
      final name = _basename(entity.path);
      final path = '$root/$name';
      if (entity is Directory) {
        if (!excludeDirs.contains(name)) {
          _walk(path, excludeDirs, onFile);
        }
      } else if (entity is File) {
        onFile(path);
      }
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  /// The directory part of a glob before its first wildcard segment.
  static String _literalPrefix(String glob) {
    final literal = <String>[];
    for (final segment in glob.split('/')) {
      if (segment.contains('*') || segment.contains('?')) {
        break;
      }
      literal.add(segment);
    }
    return literal.isEmpty ? '.' : literal.join('/');
  }

  // Two-level YAML subset: `section:` / `  key:` / `    - value`.
  static Map<String, Map<String, List<String>>> _parse(List<String> lines) {
    final doc = <String, Map<String, List<String>>>{};
    String? section;
    String? key;
    for (final raw in lines) {
      final line = raw.replaceAll('\t', '  ');
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final indent = line.length - line.trimLeft().length;
      if (trimmed.startsWith('- ')) {
        if (section != null && key != null) {
          doc[section]![key]!.add(_scalar(trimmed.substring(2)));
        }
      } else if (trimmed.endsWith(':')) {
        final name = trimmed.substring(0, trimmed.length - 1).trim();
        if (indent == 0) {
          section = name;
          key = null;
          doc[name] = <String, List<String>>{};
        } else if (section != null) {
          key = name;
          doc[section]![name] = <String>[];
        }
      }
    }
    return doc;
  }

  static String _scalar(String value) {
    var v = value.trim();
    if (v.length >= 2 &&
        ((v.startsWith("'") && v.endsWith("'")) ||
            (v.startsWith('"') && v.endsWith('"')))) {
      return v.substring(1, v.length - 1);
    }
    final comment = v.indexOf(' #');
    if (comment >= 0) {
      v = v.substring(0, comment).trim();
    }
    return v;
  }
}

/// `**` matches across `/`, `*` within one segment, `?` one character.
RegExp globToRegExp(String glob) {
  final buf = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        buf.write('.*');
        i++;
      } else {
        buf.write('[^/]*');
      }
    } else if (c == '?') {
      buf.write('[^/]');
    } else if (r'.\+(){}|^$[]'.contains(c)) {
      buf.write('\\$c');
    } else {
      buf.write(c);
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}

String extensionOf(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

String? argValue(List<String> args, String key) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == key && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$key=')) {
      return arg.substring(key.length + 1);
    }
  }
  return null;
}
