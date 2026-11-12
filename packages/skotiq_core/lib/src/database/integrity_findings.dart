/// What `PRAGMA integrity_check` reported, sorted by what can repair it.
///
/// An index holds a copy of its table's columns, so an index that no longer
/// matches its table is rebuilt from the table by `REINDEX` with nothing
/// lost. Every other report (a damaged page, a malformed record, a row that
/// breaks a NOT NULL or CHECK constraint) is a problem with the data itself.
class IntegrityFindings {
  IntegrityFindings._(this.messages, this.indexes, this.indexOnly);

  /// Every problem reported, one line each, in the order SQLite gave them.
  final List<String> messages;

  /// The indexes the index problems name.
  final Set<String> indexes;

  /// True when every problem is an index that does not match its table.
  final bool indexOnly;

  bool get healthy => messages.isEmpty;
}

/// The index problems `PRAGMA integrity_check` reports, each with the index
/// it names. Taken from SQLite 3.53 `src/pragma.c`, the version the app
/// bundles; `wrong # of entries` is also reported by `quick_check`.
final List<RegExp> _indexProblems = [
  RegExp(r'^wrong # of entries in index (.+)$'),
  RegExp(r'^row .+ missing from index (.+)$'),
  RegExp(r'^rowid not at end-of-record for row .+ of index (.+)$'),
  RegExp(r'^row .+ values differ from index (.+)$'),
  RegExp(r'^non-unique entry in index (.+)$'),
  RegExp(r'^index (.+) stores an imprecise floating-point value for row .+$'),
];

/// The b-tree checks report as one row: a `*** in database main ***` line
/// and then one line per damaged page.
final RegExp _databaseHeader = RegExp(r'^\*\*\* in database .+ \*\*\*$');

/// Sorts the rows of `PRAGMA integrity_check` (or `quick_check`). A single
/// `ok` row is a healthy database.
IntegrityFindings classifyIntegrityCheck(Iterable<String> rows) {
  final messages = <String>[];
  for (final row in rows) {
    for (final line in row.split('\n')) {
      final text = line.trim();
      if (text.isEmpty || _databaseHeader.hasMatch(text)) continue;
      messages.add(text);
    }
  }
  if (messages.length == 1 && messages.single == 'ok') {
    return IntegrityFindings._(const [], const {}, false);
  }

  final indexes = <String>{};
  var indexOnly = messages.isNotEmpty;
  for (final message in messages) {
    String? index;
    for (final pattern in _indexProblems) {
      final match = pattern.firstMatch(message);
      if (match != null) {
        index = match.group(1);
        break;
      }
    }
    if (index == null) {
      indexOnly = false;
    } else {
      indexes.add(index);
    }
  }
  return IntegrityFindings._(
    List.unmodifiable(messages),
    Set.unmodifiable(indexes),
    indexOnly,
  );
}
