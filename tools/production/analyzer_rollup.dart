import 'dart:convert';
import 'dart:io';

const _defaultPolicyPath = 'docs/production-readiness/analyzer-policy.yaml';
const _defaultCriticalCodesPath =
    'docs/production-readiness/critical-warning-codes.txt';
const _defaultReportPath = 'docs/production-readiness/analyzer-rollup.json';

class _AnalyzerPolicy {
  final List<String> include;
  final List<String> exclude;
  final int errorThreshold;
  final int warningThreshold;
  final int infoThreshold;

  const _AnalyzerPolicy({
    required this.include,
    required this.exclude,
    required this.errorThreshold,
    required this.warningThreshold,
    required this.infoThreshold,
  });

  static const defaults = _AnalyzerPolicy(
    include: <String>['apps/**', 'packages/**', 'native/skotiq_native/**'],
    exclude: <String>[
      '**/.dart_tool/**',
      '**/.git/**',
      '**/build/**',
      '**/coverage/**',
      '**/test/**',
      '**/tests/**',
      '**/*.g.dart',
      '**/frb_generated*.dart',
    ],
    errorThreshold: 0,
    warningThreshold: 0,
    infoThreshold: 999999,
  );
}

class _Issue {
  final String severity;
  final String type;
  final String code;
  final String file;
  final int line;
  final int column;
  final int length;
  final String message;

  const _Issue({
    required this.severity,
    required this.type,
    required this.code,
    required this.file,
    required this.line,
    required this.column,
    required this.length,
    required this.message,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'severity': severity,
    'type': type,
    'code': code,
    'file': file,
    'line': line,
    'column': column,
    'length': length,
    'message': message,
  };
}

class _Counts {
  int errors = 0;
  int warnings = 0;
  int infos = 0;

  Map<String, int> toJson() => <String, int>{
    'errors': errors,
    'warnings': warnings,
    'infos': infos,
  };
}

void main(List<String> args) async {
  final policyPath = _argValue(args, '--policy') ?? _defaultPolicyPath;
  final criticalCodesPath =
      _argValue(args, '--critical-codes') ?? _defaultCriticalCodesPath;
  final reportPath = _argValue(args, '--report') ?? _defaultReportPath;

  final policy = _loadPolicy(policyPath);
  final criticalCodes = _loadCriticalCodes(criticalCodesPath);

  final process = await Process.start('dart', <String>[
    'analyze',
    'packages',
    'apps',
    '--format',
    'machine',
  ], runInShell: true);

  final stdoutLines = <String>[];
  final stderrLines = <String>[];

  final stdoutFuture = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stdoutLines.add);
  final stderrFuture = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stderrLines.add);

  final exitCode = await process.exitCode;
  await Future.wait(<Future<void>>[stdoutFuture, stderrFuture]);

  final workspaceRoot = _normalize(
    Directory.current.absolute.path,
  ).toLowerCase();
  final allIssues = <_Issue>[];
  final productionIssues = <_Issue>[];
  final criticalWarningIssues = <_Issue>[];

  final allCounts = _Counts();
  final productionCounts = _Counts();

  for (final line in stdoutLines) {
    final issue = _parseMachineLine(line);
    if (issue == null) {
      continue;
    }

    _incrementCounts(allCounts, issue.severity);
    allIssues.add(issue);

    final relativePath = _toWorkspaceRelative(issue.file, workspaceRoot);
    if (!_isProductionPath(relativePath, policy)) {
      continue;
    }

    productionIssues.add(issue);
    _incrementCounts(productionCounts, issue.severity);

    if (issue.severity == 'WARNING' &&
        criticalCodes.contains(issue.code.toUpperCase())) {
      criticalWarningIssues.add(issue);
    }
  }

  final failed =
      productionCounts.errors > policy.errorThreshold ||
      productionCounts.warnings > policy.warningThreshold ||
      productionCounts.infos > policy.infoThreshold ||
      criticalWarningIssues.isNotEmpty;

  final report = <String, Object?>{
    'generatedAtUtc': DateTime.now().toUtc().toIso8601String(),
    'analyzerExitCode': exitCode,
    'policyPath': policyPath,
    'policy': <String, Object?>{
      'include': policy.include,
      'exclude': policy.exclude,
      'thresholds': <String, int>{
        'errors': policy.errorThreshold,
        'warnings': policy.warningThreshold,
        'infos': policy.infoThreshold,
      },
    },
    'summary': <String, Object?>{
      'all': allCounts.toJson(),
      'production': productionCounts.toJson(),
      'criticalWarnings': criticalWarningIssues.length,
      'failed': failed,
    },
    'criticalCodes': criticalCodes.toList()..sort(),
    'criticalWarningIssues': criticalWarningIssues
        .map((issue) => issue.toJson())
        .toList(),
    'productionIssues': productionIssues
        .map((issue) => issue.toJson())
        .toList(),
    'stderr': stderrLines,
  };

  final reportFile = File(reportPath);
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(report),
  );

  stdout.writeln('Analyzer rollup complete.');
  stdout.writeln(
    'All: errors=${allCounts.errors}, warnings=${allCounts.warnings}, infos=${allCounts.infos}',
  );
  stdout.writeln(
    'Production: errors=${productionCounts.errors}, warnings=${productionCounts.warnings}, infos=${productionCounts.infos}',
  );
  stdout.writeln('Critical warnings: ${criticalWarningIssues.length}');
  stdout.writeln('Report: $reportPath');

  if (failed) {
    stderr.writeln('Analyzer gate failed for production policy: $policyPath');
    exit(1);
  }
}

void _incrementCounts(_Counts counts, String severity) {
  switch (severity) {
    case 'ERROR':
      counts.errors++;
      break;
    case 'WARNING':
      counts.warnings++;
      break;
    case 'INFO':
      counts.infos++;
      break;
  }
}

bool _isProductionPath(String relativePath, _AnalyzerPolicy policy) {
  final normalized = _normalize(relativePath).toLowerCase();
  final included =
      policy.include.isEmpty || _matchesAny(normalized, policy.include);
  if (!included) {
    return false;
  }
  return !_matchesAny(normalized, policy.exclude);
}

bool _matchesAny(String path, List<String> globs) {
  for (final glob in globs) {
    final regex = _globToRegex(_normalize(glob).toLowerCase());
    if (regex.hasMatch(path)) {
      return true;
    }
  }
  return false;
}

RegExp _globToRegex(String glob) {
  final buffer = StringBuffer('^');
  for (var i = 0; i < glob.length; i++) {
    final char = glob[i];
    if (char == '*') {
      final isDouble = i + 1 < glob.length && glob[i + 1] == '*';
      if (isDouble) {
        buffer.write('.*');
        i++;
      } else {
        buffer.write('[^/]*');
      }
      continue;
    }
    if (char == '?') {
      buffer.write('[^/]');
      continue;
    }
    if (r'\.[]{}()+-^$|'.contains(char)) {
      buffer.write('\\$char');
    } else {
      buffer.write(char);
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}

String _toWorkspaceRelative(String filePath, String workspaceRoot) {
  final normalized = _normalize(filePath).toLowerCase();
  if (normalized.startsWith(workspaceRoot)) {
    final start = workspaceRoot.endsWith('/')
        ? workspaceRoot.length
        : workspaceRoot.length + 1;
    if (normalized.length >= start) {
      return normalized.substring(start);
    }
  }
  return normalized;
}

String? _argValue(List<String> args, String key) {
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

Set<String> _loadCriticalCodes(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return <String>{};
  }
  return file
      .readAsLinesSync()
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .map((line) => line.toUpperCase())
      .toSet();
}

_AnalyzerPolicy _loadPolicy(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return _AnalyzerPolicy.defaults;
  }

  var currentRoot = '';
  var currentProductionList = '';
  final include = <String>[];
  final exclude = <String>[];
  var errors = _AnalyzerPolicy.defaults.errorThreshold;
  var warnings = _AnalyzerPolicy.defaults.warningThreshold;
  var infos = _AnalyzerPolicy.defaults.infoThreshold;

  for (final rawLine in file.readAsLinesSync()) {
    final line = rawLine.replaceAll('\t', '  ');
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }

    final indent = line.length - line.trimLeft().length;

    if (indent == 0 && trimmed.endsWith(':')) {
      currentRoot = trimmed.substring(0, trimmed.length - 1).trim();
      currentProductionList = '';
      continue;
    }

    if (currentRoot == 'production' && indent == 2 && trimmed.endsWith(':')) {
      currentProductionList = trimmed.substring(0, trimmed.length - 1).trim();
      continue;
    }

    if (currentRoot == 'production' &&
        indent >= 4 &&
        trimmed.startsWith('- ')) {
      final value = _stripQuotes(trimmed.substring(2).trim());
      if (value.isEmpty) {
        continue;
      }
      if (currentProductionList == 'include') {
        include.add(value);
      } else if (currentProductionList == 'exclude') {
        exclude.add(value);
      }
      continue;
    }

    if (currentRoot == 'thresholds' && indent == 2 && trimmed.contains(':')) {
      final colon = trimmed.indexOf(':');
      final key = trimmed.substring(0, colon).trim();
      final value = int.tryParse(trimmed.substring(colon + 1).trim()) ?? 0;
      if (key == 'errors') {
        errors = value;
      } else if (key == 'warnings') {
        warnings = value;
      } else if (key == 'infos') {
        infos = value;
      }
    }
  }

  return _AnalyzerPolicy(
    include: include.isEmpty ? _AnalyzerPolicy.defaults.include : include,
    exclude: exclude.isEmpty ? _AnalyzerPolicy.defaults.exclude : exclude,
    errorThreshold: errors,
    warningThreshold: warnings,
    infoThreshold: infos,
  );
}

String _stripQuotes(String value) {
  if (value.length < 2) {
    return value;
  }
  if ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

_Issue? _parseMachineLine(String line) {
  final parts = line.split('|');
  if (parts.length < 8) {
    return null;
  }

  final severity = parts[0].trim();
  if (severity != 'ERROR' && severity != 'WARNING' && severity != 'INFO') {
    return null;
  }

  return _Issue(
    severity: severity,
    type: parts[1].trim(),
    code: parts[2].trim(),
    file: parts[3].trim(),
    line: int.tryParse(parts[4].trim()) ?? 0,
    column: int.tryParse(parts[5].trim()) ?? 0,
    length: int.tryParse(parts[6].trim()) ?? 0,
    message: parts.sublist(7).join('|').trim(),
  );
}

String _normalize(String path) =>
    path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
