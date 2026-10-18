// Generates the Settings search index from the settings widgets themselves.
//
// WHY THIS EXISTS
// ---------------
// A search box that matches only the hand-maintained `SettingsSectionDef.
// keywords` cannot find most rows by their own visible title. Measured on the
// live app, 243 of 496 rendered setting rows (49%) were unreachable that way:
// "Safety fail mode", "Park on unsafe weather", "Default watermark template"
// and "Default broadcast port" all returned "No settings match your search",
// and it misdirected as well as missed — "thumbnail" returned only Captured
// Images even though the Sequencer page has a "Default thumbnail size" row.
//
// A hand-maintained index drifts by construction: nothing forces the author of a
// new setting row to also add a keyword. So the index is derived from the row
// titles instead, and `--check` fails CI when it goes stale.
//
// USAGE
//   dart run tools/production/settings_search_index_gen.dart          # write
//   dart run tools/production/settings_search_index_gen.dart --check  # verify
//
// The hand-written `keywords` lists are deliberately KEPT. They carry synonyms a
// title cannot ("dark mode" for Appearance, "gain" for a page that says
// "Sensor"), which is exactly the value a derived index cannot supply.
import 'dart:convert';
import 'dart:io';

const _generatedPath =
    'packages/skotiq_app/lib/screens/settings/settings_search_index.g.dart';
const _catalogPath =
    'packages/skotiq_app/lib/screens/settings/settings_catalog.dart';
const _translationsPath =
    'packages/skotiq_app/lib/localization/skotiq_localizations/translations.dart';
const _libRoot = 'packages/skotiq_app/lib';

Future<void> main(List<String> args) async {
  final checkOnly = args.contains('--check');
  final repoRoot = _findRepoRoot();
  if (repoRoot == null) {
    stderr.writeln('error: could not locate repo root (no melos.yaml found)');
    exit(2);
  }

  final raw = _generate(repoRoot);
  final generated = await _formatted(repoRoot, raw);
  final target = File('$repoRoot/$_generatedPath');

  if (!checkOnly) {
    target.writeAsStringSync(generated);
    // Counted in the unformatted source, where every term of the first map
    // sits on its own line.
    final terms = RegExp(r"^\s{4}'", multiLine: true)
        .allMatches(raw.substring(0, raw.indexOf('kSettingsSearchRowTitles')))
        .length;
    stdout.writeln('wrote $_generatedPath ($terms search terms)');
    return;
  }

  final existing = target.existsSync() ? target.readAsStringSync() : '';
  if (existing == generated) {
    stdout.writeln('settings search index is up to date');
    return;
  }
  stderr.writeln(
    'error: $_generatedPath is stale.\n'
    'A setting row title was added, removed, or reworded without regenerating '
    'the search index, so the Settings search box can no longer find it.\n'
    'Fix: dart run tools/production/settings_search_index_gen.dart',
  );
  exit(1);
}

/// [source] as `dart format` writes it for the generated file's own package,
/// so the package's format gate passes over the generated file too.
Future<String> _formatted(String repoRoot, String source) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'format',
    '--stdin-name',
    _generatedPath,
  ], workingDirectory: repoRoot);
  process.stdin.write(source);
  await process.stdin.close();
  final out = await process.stdout.transform(utf8.decoder).join();
  final err = await process.stderr.transform(utf8.decoder).join();
  if (await process.exitCode != 0) {
    stderr.writeln('error: dart format rejected the generated index:\n$err');
    exit(2);
  }
  return out;
}

String? _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/melos.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// `key` -> widget class that renders that section's detail pane.
Map<String, String> _sectionWidgets(String catalogSource) {
  final result = <String, String>{};
  // Each SettingsSectionDef literal spans from `SettingsSectionDef(` to the
  // `build:` line that names its widget, which is always the last field.
  final defs = RegExp(
    r'SettingsSectionDef\((.*?)build:\s*\(isMobile\)\s*=>\s*(?:const\s+)?([A-Za-z0-9_]+)',
    dotAll: true,
  );
  for (final m in defs.allMatches(catalogSource)) {
    final key = RegExp(r"key:\s*'([^']+)'").firstMatch(m.group(1)!);
    if (key == null) continue;
    result[key.group(1)!] = m.group(2)!;
  }
  return result;
}

/// A Dart library: one non-part file plus every `part` it stitches in.
///
/// The library, not the file, is the unit a settings page is written in.
/// Equipment Profiles renders all of its rows from six `part` files hanging off
/// `equipment_profiles_screen.dart` (and from an `extension` inside one of
/// them), which is why its index used to hold nothing but two error strings —
/// "Could not load profiles" and "Select a profile" — while every heading a
/// user can actually see on that page was unsearchable.
class _Library {
  _Library(this.path, this.source);

  final String path;

  /// Concatenated source of the library's own file and all of its parts.
  final String source;
}

class _Libraries {
  _Libraries(this.byPath, this.declaredIn);

  final Map<String, _Library> byPath;

  /// Class name -> library that declares it.
  final Map<String, String> declaredIn;

  _Library? forClass(String name) {
    final path = declaredIn[name];
    return path == null ? null : byPath[path];
  }
}

/// Indexes every library under the app's lib/, [exclude]ing the body of any
/// class named in it that belongs to a DIFFERENT settings section.
///
/// The exclusion is what stops sibling pages bleeding into each other:
/// `merged_sections.dart` declares BOTH `FilesAndStorageSettings` and
/// `AutofocusMergedSettings`, so scanning that file whole gave Files & Storage
/// the entire Autofocus page — "Backlash IN", "Steps out from center for
/// V-curve", "Stop autoguider while focusing" — and the search box ranked a
/// page with no backlash control above the page that owns it.
_Libraries _libraryIndex(String repoRoot, {required Set<String> exclude}) {
  final byPath = <String, _Library>{};
  final declaredIn = <String, String>{};
  final partOf = RegExp(r"^part of '([^']+)'", multiLine: true);
  final partDecl = RegExp(r"^part '([^']+)'", multiLine: true);
  final classDecl = RegExp(
    r'^(?:class|mixin|extension|enum) ([A-Za-z0-9_]+)',
    multiLine: true,
  );

  final sources = <String, String>{};
  for (final entity in Directory(
    '$repoRoot/$_libRoot',
  ).listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    sources[entity.path] = entity.readAsStringSync();
  }

  // Widgets that report a runtime STATE rather than render settings rows, so
  // their titles never become search terms. Same rule as the interpolation
  // check in [_clean] ("renders differently per state, so it is not a term"),
  // applied where the alternatives are separate literals instead of one
  // `$`-string: the solver card has five mutually exclusive headlines and at
  // most one is ever on screen. Indexing them let a search for "catalog" offer
  // "ASTAP detected — catalog missing" as a Plate Solving row on a machine
  // whose Plate Solving page said "ASTAP not installed — Skotiq cannot
  // plate-solve": two Settings surfaces disagreeing about one fact.
  final stateReporters = _markedIgnored(sources.values);
  exclude = {...exclude, ...stateReporters};

  String resolvePart(String from, String relative) {
    final dir = File(from).parent.path;
    final joined = '$dir/$relative';
    // Collapse `..` segments so the key matches the listSync path.
    final parts = <String>[];
    for (final segment in joined.split('/')) {
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (segment != '.') {
        parts.add(segment);
      }
    }
    return parts.join('/');
  }

  for (final entry in sources.entries) {
    if (partOf.hasMatch(entry.value)) continue; // handled with its parent
    final buffer = StringBuffer(entry.value);
    for (final m in partDecl.allMatches(entry.value)) {
      final partPath = resolvePart(entry.key, m.group(1)!);
      final partSource = sources[partPath];
      if (partSource != null) buffer.writeln(partSource);
    }
    final library = _Library(
      entry.key,
      _blankBodies(buffer.toString(), exclude),
    );
    byPath[entry.key] = library;
    for (final m in classDecl.allMatches(library.source)) {
      declaredIn.putIfAbsent(m.group(1)!, () => entry.key);
    }
  }
  return _Libraries(byPath, declaredIn);
}

/// The marker a widget carries to keep its strings out of the search index.
///
/// Put it on the line immediately above the class declaration:
///
/// ```dart
/// // settings-search: ignore — reports which solver was DETECTED.
/// class SolverDetectionCard extends StatelessWidget {
/// ```
const _ignoreMarker = 'settings-search: ignore';

/// Class names marked with [_ignoreMarker] anywhere under the app's lib/.
Set<String> _markedIgnored(Iterable<String> sources) {
  final marked = <String>{};
  final pattern = RegExp(
    '//[^\n]*$_ignoreMarker[^\n]*\n'
    r'(?:\s*//[^\n]*\n)*'
    r'(?:class|mixin|extension) ([A-Za-z0-9_]+)',
  );
  for (final source in sources) {
    for (final m in pattern.allMatches(source)) {
      marked.add(m.group(1)!);
    }
  }
  return marked;
}

/// Blanks out the body of every class in [names] while preserving offsets, so
/// a page that shares a file with another section's page cannot inherit it.
String _blankBodies(String source, Set<String> names) {
  final decl = RegExp(
    r'^(?:class|mixin|extension|enum) ([A-Za-z0-9_]+)',
    multiLine: true,
  );
  final matches = decl.allMatches(source).toList();
  final buffer = StringBuffer();
  var cursor = 0;
  for (var i = 0; i < matches.length; i++) {
    if (!names.contains(matches[i].group(1))) continue;
    final start = matches[i].start;
    final end = i + 1 < matches.length ? matches[i + 1].start : source.length;
    buffer.write(source.substring(cursor, start));
    // Keep the newlines so line-anchored patterns behave the same.
    buffer.write('\n' * '\n'.allMatches(source.substring(start, end)).length);
    cursor = end;
  }
  buffer.write(source.substring(cursor));
  return buffer.toString();
}

/// The English translation table, so `l10n.text('k')` titles resolve to the
/// string a user actually reads.
Map<String, String> _englishStrings(String translationsSource) {
  final start = translationsSource.indexOf("'en':");
  if (start < 0) return const {};
  // The 'es' block follows; stop there so Spanish strings do not leak into the
  // index and make an English query match a Spanish-only term.
  var end = translationsSource.indexOf("'es':", start);
  if (end < 0) end = translationsSource.length;
  final block = translationsSource.substring(start, end);
  final entry = RegExp(r"'([A-Za-z0-9_]+)'\s*:\s*'((?:[^'\\]|\\.)*)'");
  final result = <String, String>{};
  for (final m in entry.allMatches(block)) {
    result.putIfAbsent(m.group(1)!, () => m.group(2)!);
  }
  return result;
}

/// Constructors whose `label:`/`labelText:` names a SETTING rather than an
/// action. A button's label is a verb ("Delete", "Cancel") and indexing it would
/// make "delete" match half the app; an input's label is the setting's name.
final _inputWidget = RegExp(r'(Field|Input|Number|Slider|Dropdown|Picker)$');

/// Constructors whose `title:` is NOT a settings row: a confirmation dialog,
/// an alert, a snackbar or an error/empty state. Indexing those made the search
/// look like it worked while matching text the user can never see on the page —
/// typing "Delete Deep-Star Tiles" (a destructive dialog's title) returned
/// Catalogs, while "GLADE" (a heading rendered on that same page) returned
/// nothing.
final _nonRowTitle = RegExp(
  r'(Dialog|Alert|Snack|Toast|Banner|EmptyState|ErrorState|Tooltip)',
);

/// Every human-readable setting name in [source], with `l10n` keys resolved.
///
/// A row's `subtitle:` is matched too, because `subtitle:` ends in `title:`,
/// and that is kept on purpose: a description is how an operator who does not
/// know a setting's name still finds it. Each subtitle is also recorded in
/// [rowOf] against its own row's title, so a consumer that lists results can
/// show the row once instead of once for its name and again for its
/// description.
List<String> _titles(
  String source,
  Map<String, String> english, {
  Map<String, String>? rowOf,
}) {
  final found = <String>[];

  void addLiteral(RegExp pattern, {bool inputsOnly = false}) {
    for (final m in pattern.allMatches(source)) {
      if (inputsOnly && !_enclosedByInput(source, m.start)) continue;
      found.add(m.group(1)!);
    }
  }

  void addKey(RegExp pattern, {bool inputsOnly = false}) {
    for (final m in pattern.allMatches(source)) {
      if (inputsOnly && !_enclosedByInput(source, m.start)) continue;
      final resolved = english[m.group(1)!];
      if (resolved != null) found.add(resolved);
    }
  }

  void addRowTitle(
    RegExp pattern, {
    bool resolveKey = false,
    bool headingsOnly = false,
  }) {
    for (final m in pattern.allMatches(source)) {
      final owner = _enclosingConstructor(source, m.start);
      if (owner != null && _nonRowTitle.hasMatch(owner)) continue;
      // A heading is styled text, and modal headings are styled identically to
      // page headings — but a settings row is never phrased as a question,
      // while a confirmation ("Clear logs?", "Reset Tutorial Progress?")
      // always is. Cheap, and it does not depend on guessing an ancestor
      // chain through unparsed source.
      if (headingsOnly && m.group(1)!.trimRight().endsWith('?')) continue;
      if (resolveKey) {
        final resolved = english[m.group(1)!];
        if (resolved != null) found.add(resolved);
      } else {
        found.add(m.group(1)!);
        if (rowOf != null && _isSubtitle(source, m.start)) {
          final title = _siblingTitle(source, m.start, english);
          if (title != null) rowOf[m.group(1)!] = title;
        }
      }
    }
  }

  addRowTitle(RegExp(r"title:\s*'((?:[^'\\]|\\.)*)'"));
  addRowTitle(
    RegExp(r"title:\s*(?:context\.)?l10n\.text\(\s*'([A-Za-z0-9_]+)'"),
    resolveKey: true,
  );
  // Headings a page renders as styled text rather than as a row title. The
  // Catalogs page heads each card with `Text('GLADE+ Galaxy Catalog', style:
  // SkotiqTypography.sectionTitle)`, which no `title:` rule can see — so
  // the visible name of an installable catalogue was unsearchable.
  //
  // The Observatory scale renamed these: h1..h6 became pageTitle /
  // sectionTitle / bodyStrong / eyebrow / display. Matching only the old names
  // silently SHRANK this index as each screen migrated — the Catalogs page lost
  // GLADE+, Download Catalogs and Minor Planets the moment its headings were
  // renamed, and the search stopped finding text that was still on screen.
  addRowTitle(
    RegExp(
      r"Text\(\s*'((?:[^'\\]|\\.)*)'\s*,\s*(?:\w+:\s*[^,]*,\s*)*"
      r"style:\s*SkotiqTypography\."
      r"(?:h[1-6]|pageTitle|sectionTitle|bodyStrong|display|eyebrow)",
    ),
    headingsOnly: true,
  );
  // Some pages label their controls directly instead of wrapping each one in a
  // SettingRow — the whole Adaptive Exposure page is built that way, and it had
  // no searchable content at all until these were included.
  addLiteral(
    RegExp(r"label(?:Text)?:\s*'((?:[^'\\]|\\.)*)'"),
    inputsOnly: true,
  );
  addKey(
    RegExp(r"label(?:Text)?:\s*(?:context\.)?l10n\.text\(\s*'([A-Za-z0-9_]+)'"),
    inputsOnly: true,
  );
  return found;
}

/// Setting names rendered by [widget] AND by any settings page it embeds.
///
/// Two catalog entries are pure composers: Files & Storage and Autofocus render
/// nothing themselves, they stack other settings pages inside a shared shell. Not
/// following the composition left both of them with an empty index, so none of
/// their settings could be found by name.
///
/// Composition is followed from the CLASS body, so a sibling class that happens
/// to live in the same file contributes nothing unless this page actually
/// builds it.
List<String> _collect(
  _Library? library,
  _Libraries libraries,
  Map<String, String> english, {
  int depth = 0,
  Set<String>? visited,
  Map<String, String>? rowOf,
}) {
  visited ??= <String>{};
  if (library == null || !visited.add(library.path) || depth > 3) {
    return const [];
  }
  final found = _titles(library.source, english, rowOf: rowOf);
  // Follow constructor calls that resolve to another page under settings/,
  // excluding the shared row/section components — those are generic chrome and
  // their internal strings are not this page's content.
  for (final m in RegExp(
    r'\b([A-Z][A-Za-z0-9_]{3,})\(',
  ).allMatches(library.source)) {
    final target = libraries.forClass(m.group(1)!);
    if (target == null) continue;
    if (!target.path.contains('/screens/settings/')) continue;
    if (target.path.contains('/widgets/settings_widgets/')) continue;
    found.addAll(
      _collect(
        target,
        libraries,
        english,
        depth: depth + 1,
        visited: visited,
        rowOf: rowOf,
      ),
    );
  }
  return found;
}

/// Whether the `title:` match at [offset] is really the tail of `subtitle:`.
bool _isSubtitle(String source, int offset) =>
    offset >= 3 && source.substring(offset - 3, offset) == 'sub';

/// The `title:` given to the same constructor call as the subtitle at
/// [offset], resolved through the translations when it is an `l10n` key.
String? _siblingTitle(String source, int offset, Map<String, String> english) {
  final open = _enclosingCall(source, offset).open;
  if (open == null) return null;
  final args = source.substring(open, offset);
  final literal = RegExp(r"\btitle:\s*'((?:[^'\\]|\\.)*)'").firstMatch(args);
  if (literal != null) return literal.group(1);
  final key = RegExp(
    r"\btitle:\s*(?:context\.)?l10n\.text\(\s*'([A-Za-z0-9_]+)'",
  ).firstMatch(args);
  return key == null ? null : english[key.group(1)!];
}

/// Whether the argument at [offset] belongs to an input-like constructor.
bool _enclosedByInput(String source, int offset) {
  final name = _enclosingConstructor(source, offset);
  return name != null && _inputWidget.hasMatch(name);
}

/// The constructor whose argument list encloses [offset].
///
/// Must count parens rather than take the nearest preceding `(`: earlier
/// arguments routinely open and close their own calls, e.g.
/// `_LabeledNumberField(fieldKey: const ValueKey('x'), label: 'Reference')`,
/// where the naive answer is `ValueKey` and the real one is
/// `_LabeledNumberField`. Getting this wrong silently dropped an entire settings
/// page out of the index.
String? _enclosingConstructor(String source, int offset) =>
    _enclosingCall(source, offset).name;

({String? name, int? open}) _enclosingCall(String source, int offset) {
  final from = offset < 2000 ? 0 : offset - 2000;
  // Blank out string literals so parentheses inside labels ("Exposure (s)") do
  // not unbalance the count. Blanked to the same length, so an index into the
  // window is still an index into [source].
  final window = source
      .substring(from, offset)
      .replaceAllMapped(
        RegExp(r"'(?:[^'\\\n]|\\.)*'"),
        (m) => "'${' ' * (m.group(0)!.length - 2)}'",
      );
  var depth = 0;
  for (var i = window.length - 1; i >= 0; i--) {
    final c = window[i];
    if (c == ')') {
      depth++;
    } else if (c == '(') {
      if (depth == 0) {
        // Dotted, so named constructors and static helpers are visible to the
        // callers that classify them: `ConfirmDialog.show` and
        // `EmptyState.compact` are dialogs, `show`/`compact` alone are not
        // recognisable as anything.
        final head = RegExp(
          r'([A-Za-z_][A-Za-z0-9_.]*)$',
        ).firstMatch(window.substring(0, i));
        return (name: head?.group(1), open: from + i);
      }
      depth--;
    }
  }
  return (name: null, open: null);
}

/// [raw] as a search term, or null when it is not a useful, stable one.
String? _cleanTerm(String raw) {
  // Dart interpolation renders differently per state, so it is not a term.
  if (raw.contains(r'$')) return null;
  final text = raw
      .replaceAll(r'\n', ' ')
      .replaceAll(r"\'", "'")
      .replaceAll(RegExp(r'\\u[0-9A-Fa-f]{4}'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.length < 3) return null;
  // A title needs at least one word; bare punctuation or units are noise.
  if (!RegExp(r'[A-Za-z]{3}').hasMatch(text)) return null;
  return text;
}

/// Keeps only titles that are useful, stable search terms.
List<String> _clean(Iterable<String> titles) {
  final seen = <String, String>{};
  for (final raw in titles) {
    final text = _cleanTerm(raw);
    if (text == null) continue;
    seen.putIfAbsent(text.toLowerCase(), () => text);
  }
  final result = seen.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return result;
}

String _generate(String repoRoot) {
  final catalog = File('$repoRoot/$_catalogPath').readAsStringSync();
  final english = _englishStrings(
    File('$repoRoot/$_translationsPath').readAsStringSync(),
  );
  final widgets = _sectionWidgets(catalog);
  final roots = widgets.values.toSet();

  final missing = <String>[];
  final entries = <String, List<String>>{};
  final rowOf = <String, Map<String, String>>{};
  for (final key in widgets.keys.toList()..sort()) {
    final widget = widgets[key]!;
    // Index this page against a source in which every OTHER section's root
    // widget has been blanked out, so co-located pages stay separate.
    final libraries = _libraryIndex(
      repoRoot,
      exclude: roots.difference({widget}),
    );
    final library = libraries.forClass(widget);
    if (library == null) {
      missing.add('$key -> $widget');
      continue;
    }
    final rawRowOf = <String, String>{};
    final titles = _clean(
      _collect(library, libraries, english, rowOf: rawRowOf),
    );
    if (titles.isNotEmpty) entries[key] = titles;
    final sectionRowOf = <String, String>{};
    for (final pair in rawRowOf.entries) {
      final description = _cleanTerm(pair.key);
      final title = _cleanTerm(pair.value);
      if (description == null || title == null) continue;
      if (description.toLowerCase() == title.toLowerCase()) continue;
      if (!titles.contains(description) || !titles.contains(title)) continue;
      sectionRowOf[description] = title;
    }
    if (sectionRowOf.isNotEmpty) {
      rowOf[key] = Map.fromEntries(
        sectionRowOf.entries.toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase())),
      );
    }
  }
  if (missing.isNotEmpty) {
    stderr.writeln(
      'error: could not resolve the widget for these settings sections, so '
      'their rows would silently become unsearchable:\n  '
      '${missing.join('\n  ')}',
    );
    exit(2);
  }

  final out = StringBuffer()
    ..writeln('// GENERATED FILE - DO NOT EDIT BY HAND.')
    ..writeln('//')
    ..writeln('// Regenerate with:')
    ..writeln('//   dart run tools/production/settings_search_index_gen.dart')
    ..writeln('//')
    ..writeln(
      '// Source of truth is the `title:` of every row each settings section',
    )
    ..writeln(
      '// actually renders, so typing a setting\'s visible name finds it. See',
    )
    ..writeln('// tools/production/settings_search_index_gen.dart for why.')
    ..writeln()
    ..writeln(
      '/// Settings section key -> the row titles that section renders.',
    )
    ..writeln('const Map<String, List<String>> kSettingsSearchTerms = {');
  for (final key in entries.keys) {
    out.writeln("  '$key': [");
    for (final term in entries[key]!) {
      out.writeln(
        "    '${term.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}',",
      );
    }
    out.writeln('  ],');
  }
  out
    ..writeln('};')
    ..writeln()
    ..writeln(
      '/// Settings section key -> a term that is a row\'s description -> that',
    )
    ..writeln(
      '/// row\'s title. Lets a result list show a row once, under its name,',
    )
    ..writeln('/// whichever of the two the query matched.')
    ..writeln(
      'const Map<String, Map<String, String>> kSettingsSearchRowTitles = {',
    );
  String quote(String term) =>
      "'${term.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";
  for (final key in rowOf.keys) {
    out.writeln("  '$key': {");
    for (final pair in rowOf[key]!.entries) {
      out.writeln('    ${quote(pair.key)}:');
      out.writeln('        ${quote(pair.value)},');
    }
    out.writeln('  },');
  }
  out.writeln('};');
  return out.toString();
}
