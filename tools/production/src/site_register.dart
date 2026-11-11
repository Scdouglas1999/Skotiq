import 'dart:io';

/// Reviewed audit sites keyed by what the code says, not where it sits.
///
/// A site is identified by `rule + enclosing declaration + normalized line
/// text`. The file path is kept only as a hint: it breaks ties between
/// identical sites and tells a reader where to look, and a row whose hint is
/// out of date still matches. Moving a file, splitting it, or shifting lines
/// therefore needs no register edit.

class Finding {
  final String rule;
  final String scope;
  final String text;
  final String path;
  final int line;

  const Finding({
    required this.rule,
    required this.scope,
    required this.text,
    required this.path,
    required this.line,
  });

  String get key => '$rule\t$scope\t$text';

  String get display => '$path:$line:$rule [$scope] $text';
}

class SiteRow {
  final String rule;
  final String scope;
  final String text;
  final String verdict;
  final String path;
  int count;

  SiteRow({
    required this.rule,
    required this.scope,
    required this.text,
    required this.verdict,
    required this.path,
    this.count = 1,
  });

  String get key => '$rule\t$scope\t$text';
}

String normalizeText(String line) =>
    line.trim().replaceAll(RegExp(r'\s+'), ' ');

class SiteMatch {
  /// Finding -> the row whose verdict covers it.
  final Map<Finding, SiteRow> assigned = <Finding, SiteRow>{};
  final List<Finding> unregistered = <Finding>[];

  /// Row -> capacity no finding used (the code it described is gone).
  final Map<SiteRow, int> stale = <SiteRow, int>{};

  /// Findings matched to a row recorded under a different path.
  int moved = 0;

  int get staleCount => stale.values.fold(0, (a, b) => a + b);
}

/// Pairs findings with rows that share a key. Rows recorded for the same
/// path are used first; what is left is paired regardless of path. [rank]
/// orders rows for that second pass (lower first) so a caller can make sure
/// open verdicts are never hidden behind closed ones.
SiteMatch matchSites(
  List<Finding> findings,
  List<SiteRow> rows, {
  int Function(SiteRow row)? rank,
}) {
  final result = SiteMatch();
  final rowsByKey = <String, List<SiteRow>>{};
  for (final row in rows) {
    rowsByKey.putIfAbsent(row.key, () => <SiteRow>[]).add(row);
  }
  final findingsByKey = <String, List<Finding>>{};
  for (final finding in findings) {
    findingsByKey.putIfAbsent(finding.key, () => <Finding>[]).add(finding);
  }

  final remaining = <SiteRow, int>{for (final row in rows) row: row.count};
  for (final entry in findingsByKey.entries) {
    final candidates = rowsByKey[entry.key] ?? const <SiteRow>[];
    final pending = <Finding>[];
    // Line order against row order pairs identical lines in one file the
    // way they were recorded.
    for (final finding in entry.value..sort(_byLocation)) {
      final samePath = candidates.where(
        (row) => row.path == finding.path && remaining[row]! > 0,
      );
      if (samePath.isEmpty) {
        pending.add(finding);
        continue;
      }
      final row = samePath.first;
      remaining[row] = remaining[row]! - 1;
      result.assigned[finding] = row;
    }
    final ordered = candidates.toList()
      ..sort((a, b) {
        final byRank = (rank?.call(a) ?? 0).compareTo(rank?.call(b) ?? 0);
        return byRank != 0 ? byRank : a.path.compareTo(b.path);
      });
    pending.sort(_byLocation);
    for (final finding in pending) {
      SiteRow? row;
      for (final candidate in ordered) {
        if (remaining[candidate]! > 0) {
          row = candidate;
          break;
        }
      }
      if (row == null) {
        result.unregistered.add(finding);
        continue;
      }
      remaining[row] = remaining[row]! - 1;
      result.assigned[finding] = row;
      result.moved++;
    }
  }
  for (final entry in remaining.entries) {
    if (entry.value > 0) {
      result.stale[entry.key] = entry.value;
    }
  }
  result.unregistered.sort(_byLocation);
  return result;
}

class Carried {
  final Finding finding;
  final SiteRow from;
  const Carried(this.finding, this.from);
}

class SiteSync {
  final List<SiteRow> rows;

  /// Verdicts re-attached to the same line text under a new declaration.
  final List<Carried> carriedByText;

  /// Verdicts re-attached to an edited line in the same declaration.
  final List<Carried> carriedEdited;
  final List<Finding> unregistered;

  /// Rows no finding matched, with the capacity left over. Dropped from
  /// [rows] only when nothing is left unregistered: while a finding still
  /// waits for a verdict, the row it may have come from is kept.
  final List<SiteRow> unmatched;

  bool get keptUnmatched => unregistered.isNotEmpty && unmatched.isNotEmpty;

  int get unmatchedCount => unmatched.fold(0, (a, row) => a + row.count);

  const SiteSync({
    required this.rows,
    required this.carriedByText,
    required this.carriedEdited,
    required this.unregistered,
    required this.unmatched,
  });
}

/// Rebuilds the rows from what the code says now: path hints refreshed, rows
/// with no finding dropped, and verdicts carried to code that changed its
/// enclosing declaration (same rule and text). With [carryEdited], a verdict
/// also follows a line edited in place when exactly one row and one finding
/// are left for that rule, path and declaration.
SiteSync syncSites(
  List<Finding> findings,
  List<SiteRow> rows, {
  bool carryEdited = false,
  int Function(SiteRow row)? rank,
}) {
  final match = matchSites(findings, rows, rank: rank);
  final out = <SiteRow>[];
  void emit(Finding finding, String verdict) {
    out.add(
      SiteRow(
        rule: finding.rule,
        scope: finding.scope,
        text: finding.text,
        verdict: verdict,
        path: finding.path,
      ),
    );
  }

  for (final entry in match.assigned.entries) {
    emit(entry.key, entry.value.verdict);
  }

  final stale = Map<SiteRow, int>.of(match.stale);
  SiteRow? take(Iterable<SiteRow> candidates, Finding finding) {
    final live = candidates.where((row) => (stale[row] ?? 0) > 0).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (live.isEmpty) {
      return null;
    }
    final samePath = live.where((row) => row.path == finding.path);
    final verdicts = live.map((row) => row.verdict).toSet();
    final row = samePath.isNotEmpty
        ? samePath.first
        : (verdicts.length == 1 ? live.first : null);
    if (row != null) {
      stale[row] = stale[row]! - 1;
    }
    return row;
  }

  final carriedByText = <Carried>[];
  final carriedEdited = <Carried>[];
  var pending = match.unregistered;

  String textKey(String rule, String text) => '$rule\t$text';
  final staleByText = <String, List<SiteRow>>{};
  for (final row in stale.keys) {
    staleByText.putIfAbsent(textKey(row.rule, row.text), () => []).add(row);
  }
  var next = <Finding>[];
  for (final finding in pending) {
    final row = take(
      staleByText[textKey(finding.rule, finding.text)] ?? const [],
      finding,
    );
    if (row == null) {
      next.add(finding);
    } else {
      emit(finding, row.verdict);
      carriedByText.add(Carried(finding, row));
    }
  }
  pending = next;

  if (carryEdited) {
    String placeKey(String rule, String path, String scope) =>
        '$rule\t$path\t$scope';
    final staleByPlace = <String, List<SiteRow>>{};
    for (final entry in stale.entries) {
      if (entry.value > 0) {
        final row = entry.key;
        staleByPlace
            .putIfAbsent(placeKey(row.rule, row.path, row.scope), () => [])
            .add(row);
      }
    }
    final pendingByPlace = <String, List<Finding>>{};
    for (final finding in pending) {
      pendingByPlace
          .putIfAbsent(
            placeKey(finding.rule, finding.path, finding.scope),
            () => [],
          )
          .add(finding);
    }
    next = <Finding>[];
    for (final entry in pendingByPlace.entries) {
      final candidates = staleByPlace[entry.key] ?? const <SiteRow>[];
      final capacity = candidates.fold(0, (a, row) => a + stale[row]!);
      if (entry.value.length == 1 && capacity == 1) {
        final row = candidates.firstWhere((row) => stale[row]! > 0);
        stale[row] = 0;
        emit(entry.value.single, row.verdict);
        carriedEdited.add(Carried(entry.value.single, row));
      } else {
        next.addAll(entry.value);
      }
    }
    pending = next..sort(_byLocation);
  }

  final unmatched = [
    for (final entry in stale.entries)
      if (entry.value > 0)
        SiteRow(
          rule: entry.key.rule,
          scope: entry.key.scope,
          text: entry.key.text,
          verdict: entry.key.verdict,
          path: entry.key.path,
          count: entry.value,
        ),
  ];
  return SiteSync(
    rows: mergeRows(pending.isEmpty ? out : [...out, ...unmatched]),
    carriedByText: carriedByText,
    carriedEdited: carriedEdited,
    unregistered: pending,
    unmatched: unmatched,
  );
}

/// Sorts rows by path and key and collapses neighbors that agree into one
/// row with a count. Rows for the same path and key keep their relative
/// order: when identical lines in one declaration carry different verdicts,
/// that order is what tells them apart.
List<SiteRow> mergeRows(Iterable<SiteRow> rows) {
  final indexed = rows.indexed.toList()
    ..sort((a, b) {
      final byPath = a.$2.path.compareTo(b.$2.path);
      if (byPath != 0) {
        return byPath;
      }
      final byKey = a.$2.key.compareTo(b.$2.key);
      return byKey != 0 ? byKey : a.$1.compareTo(b.$1);
    });
  final merged = <SiteRow>[];
  for (final (_, row) in indexed) {
    final last = merged.isEmpty ? null : merged.last;
    if (last != null &&
        last.path == row.path &&
        last.key == row.key &&
        last.verdict == row.verdict) {
      last.count += row.count;
    } else {
      merged.add(
        SiteRow(
          rule: row.rule,
          scope: row.scope,
          text: row.text,
          verdict: row.verdict,
          path: row.path,
          count: row.count,
        ),
      );
    }
  }
  return merged;
}

const _columns = 'path\tscope\trule\tcount\tverdict\ttext';

/// Reads a sites file: tab-separated, `#` comment lines, one header line.
List<SiteRow> readSites(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return <SiteRow>[];
  }
  final rows = <SiteRow>[];
  final lines = file.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty || line.startsWith('#') || line == _columns) {
      continue;
    }
    final cols = line.split('\t');
    final count = cols.length == 6 ? int.tryParse(cols[3]) : null;
    if (count == null || count < 1) {
      stderr.writeln('Malformed sites row at $path:${i + 1}: $line');
      exit(2);
    }
    rows.add(
      SiteRow(
        path: cols[0],
        scope: cols[1],
        rule: cols[2],
        count: count,
        verdict: cols[4],
        text: cols[5],
      ),
    );
  }
  return rows;
}

void writeSites(String path, List<SiteRow> rows, {required String header}) {
  final buf = StringBuffer();
  for (final line in header.trim().split('\n')) {
    buf.writeln('# $line'.trimRight());
  }
  buf.writeln(_columns);
  for (final row in mergeRows(rows)) {
    buf.writeln(
      [
        row.path,
        row.scope,
        row.rule,
        row.count,
        row.verdict,
        row.text,
      ].join('\t'),
    );
  }
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(buf.toString());
}

int _byLocation(Finding a, Finding b) {
  final byPath = a.path.compareTo(b.path);
  return byPath != 0 ? byPath : a.line.compareTo(b.line);
}

// ---------------------------------------------------------------------------
// Enclosing declaration
//
// Both languages are machine-formatted, so indentation gives the nesting.
// Walking up from a line through ever-smaller indents visits each enclosing
// block header; the first that declares a function names the scope, falling
// back to the innermost type. The name only has to be stable for the same
// code, so a rare misread costs a re-point, never a wrong verdict.
// ---------------------------------------------------------------------------

const noScope = '-';

String enclosingScope(List<String> lines, int index, String ext) {
  final isRust = ext == '.rs';
  String? container;
  var indent = _indentOf(lines[index]);
  final own = isRust
      ? _rustDecl(lines[index])
      : _dartDecl(lines[index], indent);
  if (own != null && own.isFunction) {
    return own.name;
  }
  for (var i = index - 1; i >= 0 && indent > 0; i--) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty || _isCommentOrAttribute(trimmed)) {
      continue;
    }
    final lineIndent = _indentOf(line);
    if (lineIndent >= indent) {
      continue;
    }
    indent = lineIndent;
    var header = line;
    if (_startsWithCloser(trimmed)) {
      // `) async {` or `} else {`: the statement began on an earlier line at
      // this same indent.
      for (var j = i - 1; j >= 0; j--) {
        final candidate = lines[j];
        final candidateTrimmed = candidate.trimLeft();
        if (candidateTrimmed.isEmpty) {
          continue;
        }
        final candidateIndent = _indentOf(candidate);
        if (candidateIndent < lineIndent) {
          break;
        }
        if (candidateIndent == lineIndent &&
            !_startsWithCloser(candidateTrimmed) &&
            !_isCommentOrAttribute(candidateTrimmed)) {
          header = candidate;
          i = j;
          break;
        }
      }
    }
    final decl = isRust ? _rustDecl(header) : _dartDecl(header, lineIndent);
    if (decl == null) {
      continue;
    }
    if (decl.isFunction) {
      return decl.name;
    }
    container ??= decl.name;
  }
  return container ?? noScope;
}

class _Decl {
  final String name;
  final bool isFunction;
  const _Decl(this.name, {required this.isFunction});
}

int _indentOf(String line) {
  var indent = 0;
  for (var i = 0; i < line.length; i++) {
    final c = line.codeUnitAt(i);
    if (c == 0x20) {
      indent++;
    } else if (c == 0x09) {
      indent += 4;
    } else {
      break;
    }
  }
  return indent;
}

bool _startsWithCloser(String trimmed) =>
    trimmed.startsWith(')') ||
    trimmed.startsWith('}') ||
    trimmed.startsWith(']') ||
    trimmed.startsWith('>');

bool _isCommentOrAttribute(String trimmed) =>
    trimmed.startsWith('//') ||
    trimmed.startsWith('/*') ||
    trimmed.startsWith('*') ||
    trimmed.startsWith('#[') ||
    trimmed.startsWith('#![') ||
    (trimmed.startsWith('@') && !trimmed.contains('('));

final _rustFn = RegExp(r'\bfn\s+([A-Za-z_]\w*)');
final _rustMacro = RegExp(r'^macro_rules!\s*([A-Za-z_]\w*)');
final _rustImpl = RegExp(r'^(?:unsafe\s+)?impl\b(.*)$');
final _rustType = RegExp(
  r'^(?:pub(?:\([^)]*\))?\s+)?(?:unsafe\s+)?(?:mod|trait|struct|enum|union)\s+([A-Za-z_]\w*)',
);

_Decl? _rustDecl(String line) {
  final trimmed = line.trim();
  if (trimmed.startsWith('//')) {
    return null;
  }
  final fn = _rustFn.firstMatch(trimmed);
  if (fn != null) {
    return _Decl(fn.group(1)!, isFunction: true);
  }
  final macro = _rustMacro.firstMatch(trimmed);
  if (macro != null) {
    return _Decl(macro.group(1)!, isFunction: true);
  }
  final impl = _rustImpl.firstMatch(trimmed);
  if (impl != null) {
    var target = impl.group(1)!;
    final forAt = target.lastIndexOf(' for ');
    if (forAt >= 0) {
      target = target.substring(forAt + 5);
    } else {
      // Drop the generic parameter list of `impl<T> Type<T>`.
      target = target.replaceFirst(RegExp(r'^\s*<[^>]*>'), '');
    }
    final name = RegExp(
      r'([A-Za-z_]\w*)\s*(?:<|\{|where\b|$)',
    ).firstMatch(target.trim());
    if (name != null) {
      return _Decl(name.group(1)!, isFunction: false);
    }
    return null;
  }
  final type = _rustType.firstMatch(trimmed);
  if (type != null) {
    return _Decl(type.group(1)!, isFunction: false);
  }
  return null;
}

final _dartType = RegExp(
  r'^(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*'
  r'(?:class|mixin|enum|extension\s+type|extension|typedef)\s+([A-Za-z_$][\w$]*)',
);
final _dartGetter = RegExp(
  r'^(?:(?:static|external)\s+)*(?:[\w$<>?,.\[\] ]+?\s+)?get\s+([A-Za-z_$][\w$]*)\s*(?:=>|\{|async\b|sync\b|$)',
);
final _dartFunction = RegExp(
  r'^(?:(?:static|external|abstract|covariant|factory|const)\s+)*'
  r'(?:([\w$<>?,.\[\] ]+?)\s+)?'
  r'(operator\s*[^\s(]+|[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)?)'
  r'\s*(?:<[^()]*>)?\s*\(',
);
const _dartNotAName = <String>{
  'if',
  'for',
  'while',
  'switch',
  'catch',
  'return',
  'await',
  'throw',
  'assert',
  'super',
  'this',
  'do',
  'else',
  'try',
  'new',
  'yield',
  'in',
  'is',
  'as',
  'on',
  'case',
  'default',
  'final',
  'var',
  'late',
  'const',
};

_Decl? _dartDecl(String line, int indent) {
  var trimmed = line.trim();
  if (trimmed.startsWith('//')) {
    return null;
  }
  trimmed = trimmed.replaceFirst(RegExp(r'^(?:@\w+(?:\([^)]*\))?\s+)+'), '');
  final type = _dartType.firstMatch(trimmed);
  if (type != null) {
    final name = type.group(1)!;
    if (name == 'on') {
      final target = RegExp(r'\bon\s+([A-Za-z_$][\w$]*)').firstMatch(trimmed);
      return target == null ? null : _Decl(target.group(1)!, isFunction: false);
    }
    return _Decl(name, isFunction: false);
  }
  final fn = _dartFunction.firstMatch(trimmed);
  if (fn != null) {
    final returnType = fn.group(1);
    final name = fn.group(2)!;
    final returnWords = (returnType ?? '').split(RegExp(r'[\s<>,?.\[\]]+'));
    if (_dartNotAName.contains(name) ||
        returnWords.any(_dartNotAName.contains)) {
      return null;
    }
    final isConstructor = RegExp(r'^_?[A-Z]').hasMatch(name);
    // A bare `name(` with no return type is a call unless it sits where only
    // declarations can: file level, or a constructor at class-member level.
    if (returnType != null || indent == 0 || (isConstructor && indent <= 2)) {
      return _Decl(name, isFunction: true);
    }
    return null;
  }
  final getter = _dartGetter.firstMatch(trimmed);
  if (getter != null) {
    return _Decl(getter.group(1)!, isFunction: true);
  }
  return null;
}
