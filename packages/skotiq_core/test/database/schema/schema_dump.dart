// Structural dump of a SQLite schema, read with the sqlite3 package straight
// from the file so no application code takes part in describing it.
import 'package:sqlite3/sqlite3.dart';

String _squash(String sql) => sql
    .replaceAll(RegExp(r'--[^\n]*'), ' ')
    .replaceAll(RegExp(r'''["`\[\]]'''), '')
    .replaceAll(RegExp(r'\s+'), '')
    .toLowerCase()
    .replaceAll('ifnotexists', '');

/// Every `CHECK (...)` clause of a `CREATE TABLE`, squashed and sorted.
List<String> _checkClauses(String sql) {
  final out = <String>[];
  final pattern = RegExp(r'\bCHECK\s*\(', caseSensitive: false);
  for (final match in pattern.allMatches(sql)) {
    var depth = 1;
    var i = match.end;
    while (i < sql.length && depth > 0) {
      final c = sql[i];
      if (c == '(') depth++;
      if (c == ')') depth--;
      i++;
    }
    out.add(_squash(sql.substring(match.end, i - 1)));
  }
  out.sort();
  return out;
}

String? _squashDefault(Object? value) {
  if (value == null) return null;
  var text = _squash(value.toString());
  while (text.startsWith('(') && text.endsWith(')')) {
    text = text.substring(1, text.length - 1);
  }
  return text;
}

/// Tables, their columns, constraints and indexes, plus triggers and views.
///
/// Column order, declared type, nullability, default, primary-key position,
/// foreign keys with their actions, `CHECK` clauses, `AUTOINCREMENT`,
/// `WITHOUT ROWID`, `STRICT` and every index (unique, partial, the columns
/// with their sort order and collation) are all in the result, so two schemas
/// that dump equal accept and reject the same rows.
Map<String, Object?> dumpSchema(Database db) {
  final tables = <String, Object?>{};
  final master = db.select(
    "SELECT type, name, tbl_name, sql FROM sqlite_master "
    "WHERE name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  final other = <String, Object?>{};
  for (final row in master) {
    final type = row['type'] as String;
    final name = row['name'] as String;
    final sql = (row['sql'] as String?) ?? '';
    if (type == 'trigger' || type == 'view') {
      other['$type:$name'] = _squash(sql);
      continue;
    }
    if (type != 'table') continue;
    final columns = [
      for (final c in db.select('PRAGMA table_xinfo("$name")'))
        {
          'name': c['name'],
          'type': (c['type'] as String).toUpperCase(),
          'notnull': c['notnull'],
          'default': _squashDefault(c['dflt_value']),
          'pk': c['pk'],
          'hidden': c['hidden'],
        },
    ];
    final foreignKeys = [
      for (final f in db.select('PRAGMA foreign_key_list("$name")'))
        '${f['from']}->${f['table']}(${f['to']}) '
            'update=${f['on_update']} delete=${f['on_delete']} '
            'match=${f['match']}',
    ]..sort();
    final indexes = <String, Object?>{};
    for (final i in db.select('PRAGMA index_list("$name")')) {
      final indexName = i['name'] as String;
      final indexSql = db.select(
        'SELECT sql FROM sqlite_master WHERE type = ? AND name = ?',
        ['index', indexName],
      );
      indexes[indexName] = {
        'unique': i['unique'],
        'origin': i['origin'],
        'partial': i['partial'],
        'columns': [
          for (final x in db.select('PRAGMA index_xinfo("$indexName")'))
            if (x['key'] == 1)
              '${x['name']} desc=${x['desc']} coll=${x['coll']}',
        ],
        'sql': indexSql.isEmpty || indexSql.first['sql'] == null
            ? null
            : _squash(indexSql.first['sql'] as String),
      };
    }
    final upper = sql.toUpperCase();
    final tail = upper.substring(upper.lastIndexOf(')') + 1);
    tables[name] = {
      'columns': columns,
      'foreignKeys': foreignKeys,
      'checks': _checkClauses(sql),
      'autoincrement': upper.contains('AUTOINCREMENT'),
      'withoutRowid': tail.contains('WITHOUT ROWID'),
      'strict': tail.contains('STRICT'),
      'indexes': indexes,
    };
  }
  return {'tables': tables, 'other': other};
}

/// The verbatim `sqlite_master` rows, for asserting an open changed nothing.
Map<String, String?> dumpMasterSql(Database db) => {
  for (final row in db.select(
    "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
  ))
    '${row['type']}:${row['name']}': row['sql'] as String?,
};

/// Row count per table.
Map<String, int> dumpRowCounts(Database db) => {
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ))
    row['name'] as String:
        db.select('SELECT COUNT(*) AS n FROM "${row['name']}"').first['n']
            as int,
};
