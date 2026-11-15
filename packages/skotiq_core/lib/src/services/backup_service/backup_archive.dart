/// The backup file: written from a database file and read into one, a row at
/// a time, on an isolate of its own. Neither direction holds a table in
/// memory, and neither runs on the isolate that paints.
///
/// Format 3.1 is one JSON document laid out in lines: a head line, one line
/// per small section, and one line per table row (an array in the order of
/// the table's `columns`). Earlier formats are one JSON value in any layout
/// and are decoded whole.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

/// The format this build writes.
const String backupArchiveVersion = '3.1';

const String _linesLayout = 'lines';
const String _blobKey = r'$blob';
const String _doubleKey = r'$double';

/// Raised for a backup file that cannot be restored; the message is for the
/// operator.
class BackupArchiveException implements Exception {
  const BackupArchiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A cell as the archive holds it. JSON has no bytes and no NaN or infinity,
/// so those travel as one-key objects.
Object? encodeBackupCell(Object? value) => switch (value) {
  final Uint8List bytes => {_blobKey: base64Encode(bytes)},
  final double d when !d.isFinite => {_doubleKey: d.toString()},
  _ => value,
};

/// The database value of an archive cell.
Object? decodeBackupCell(Object? value, String where) => switch (value) {
  null || int() || double() || String() => value,
  final bool b => b ? 1 : 0,
  {_blobKey: final String b64} => base64Decode(b64),
  {_doubleKey: final String d} => double.parse(d),
  _ => throw BackupArchiveException(
    'Invalid backup file: $where is not a database value',
  ),
};

/// Refuses a backup written by a newer format than [backupArchiveVersion].
void checkBackupVersion(Object? version) {
  if (version is! String || version.isEmpty) {
    throw const BackupArchiveException('Invalid backup file: missing version');
  }
  final match = RegExp(r'^(\d+)\.(\d+)$').firstMatch(version);
  if (match == null) {
    throw BackupArchiveException(
      'Invalid backup file: unsupported version format "$version"',
    );
  }
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  final current = backupArchiveVersion.split('.').map(int.parse).toList();
  if (major > current[0] || (major == current[0] && minor > current[1])) {
    throw BackupArchiveException(
      'Backup version $version is newer than supported version '
      '$backupArchiveVersion. Update Skotiq before restoring it.',
    );
  }
}

/// Runs [body] on a new isolate; every value it passes to its `report`
/// argument reaches [onProgress] here.
Future<T> runWithProgress<T>(
  FutureOr<T> Function(void Function(double fraction) report) body,
  void Function(double fraction)? onProgress,
) async {
  final port = ReceivePort();
  final subscription = port.listen((message) {
    if (message is double) onProgress?.call(message);
  });
  try {
    return await Isolate.run(_onIsolate(body, port.sendPort));
  } finally {
    await subscription.cancel();
    port.close();
  }
}

/// The isolate's entry, built where it closes over nothing but its two
/// arguments.
FutureOr<T> Function() _onIsolate<T>(
  FutureOr<T> Function(void Function(double fraction) report) body,
  SendPort port,
) =>
    () => body(port.send);

/// Writes the settings (but for [omitSettings]) and the rows of [tables] in
/// the database file at [databasePath] to [outputPath] as a 3.1 archive, and
/// returns the rows written per table. [head] holds the head line's fields.
Map<String, int> writeBackupArchive({
  required String databasePath,
  required String outputPath,
  required Map<String, Object?> head,
  required List<String> tables,
  required Set<String> omitSettings,
  required void Function(double fraction) report,
}) {
  final db = sqlite3.open(databasePath, mode: OpenMode.readOnly);
  final out = File(outputPath).openSync(mode: FileMode.write);
  try {
    int rowsOf(String table) =>
        db.select('SELECT count(*) AS n FROM "$table"').first['n'] as int;
    final counts = <String, int>{
      for (final table in tables) table: rowsOf(table),
    };
    final total = counts.values.fold<int>(0, (sum, n) => sum + n);
    final settings = <String, Object?>{
      for (final row in db.select('SELECT key, value FROM app_settings'))
        if (!omitSettings.contains(row['key']))
          row['key'] as String: row['value'],
    };
    final pending = BytesBuilder(copy: false);
    void write(String text) {
      pending.add(utf8.encode(text));
      if (pending.length >= 1 << 20) out.writeFromSync(pending.takeBytes());
    }

    final headLine = jsonEncode({
      'version': backupArchiveVersion,
      'layout': _linesLayout,
      ...head,
      'metadata': {
        'settingsCount': settings.length,
        'profilesCount': rowsOf('equipment_profiles'),
        'sequencesCount': rowsOf('sequences'),
        'targetsCount': rowsOf('targets'),
        // Rows per table, so a partial backup (a table with 0 rows where
        // there should be some) shows before a restore is committed to.
        'tableCounts': counts,
      },
    });
    write('${headLine.substring(0, headLine.length - 1)},\n');
    write('"settings":${jsonEncode(settings)},\n');
    write('"tables":{\n');
    var written = 0;
    for (var t = 0; t < tables.length; t++) {
      final table = tables[t];
      final statement = db.prepare('SELECT * FROM "$table" ORDER BY rowid');
      try {
        final cursor = statement.selectCursor();
        var first = true;
        while (cursor.moveNext()) {
          if (first) {
            write(
              '${jsonEncode(table)}:{"columns":'
              '${jsonEncode(cursor.columnNames)},"rows":[\n',
            );
          }
          write(first ? '' : ',\n');
          first = false;
          write(
            jsonEncode([
              for (final cell in cursor.current.values) encodeBackupCell(cell),
            ]),
          );
          if (++written % 20000 == 0) report(written / total);
        }
        if (first) {
          write(
            '${jsonEncode(table)}:{"columns":'
            '${jsonEncode(cursor.columnNames)},"rows":[',
          );
        }
        write('\n]}${t == tables.length - 1 ? '' : ','}\n');
      } finally {
        statement.close();
      }
    }
    write('}}\n');
    out.writeFromSync(pending.takeBytes());
    out.flushSync();
    return counts;
  } finally {
    out.closeSync();
    db.close();
  }
}

/// What [readBackupArchive] found beside the table rows it loaded.
class BackupArchiveContents {
  BackupArchiveContents({
    required this.version,
    required this.sections,
    required this.rowsLoaded,
    required this.tablesSkipped,
    required this.columnsCarried,
  });

  final String version;

  /// Every top-level value of the archive except `tables` and `settings`.
  final Map<String, dynamic> sections;

  /// Rows written into the database file, by table.
  final Map<String, int> rowsLoaded;

  /// Tables of the archive this schema has no place for, or never restores.
  final List<String> tablesSkipped;

  /// The columns the archive holds for each table it has rows of. A column
  /// the schema gained after the backup was written is not among them: the
  /// backup says nothing about it.
  final Map<String, Set<String>> columnsCarried;
}

/// Reads the archive at [archivePath] and writes the rows of its `tables`
/// section and its settings (but for [omitSettings]) into the database file
/// at [databasePath], which holds the schema and no rows in those tables.
/// Tables in [never] and tables or columns the schema does not have are left
/// out. One transaction: a file that cannot be read to its end leaves the
/// database file as it was.
Future<BackupArchiveContents> readBackupArchive({
  required String archivePath,
  required String databasePath,
  required Set<String> never,
  required Set<String> omitSettings,
  required void Function(double fraction) report,
}) async {
  final file = File(archivePath);
  final size = file.lengthSync();
  final db = sqlite3.open(databasePath);
  try {
    // Rows go in as the backup holds them; what they point at is checked by
    // the caller once they are all there.
    db.execute('PRAGMA foreign_keys = OFF');
    db.execute('BEGIN');
    final loader = _TableLoader(db, never);
    final sections = <String, dynamic>{};
    final head = file.openSync();
    final String firstBytes;
    try {
      firstBytes = utf8.decode(
        head.readSync(size < 256 ? size : 256),
        allowMalformed: true,
      );
    } finally {
      head.closeSync();
    }
    if (_isLinesLayout(firstBytes)) {
      await _readLines(file, size, sections, loader, report);
    } else {
      final Object? decoded;
      try {
        decoded = jsonDecode(file.readAsStringSync());
      } on FormatException catch (e) {
        throw BackupArchiveException(
          'Invalid backup file: not valid JSON (${e.message})',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const BackupArchiveException(
          'Invalid backup file: root is not a JSON object',
        );
      }
      checkBackupVersion(decoded['version']);
      report(0.5);
      final tables = decoded.remove('tables');
      sections.addAll(decoded);
      if (tables != null) loader.loadDecoded(tables);
    }
    checkBackupVersion(sections['version']);
    if (sections.remove('settings') case final settings?) {
      if (settings is! Map<String, dynamic>) {
        throw const BackupArchiveException(
          'Invalid backup file: "settings" is not an object',
        );
      }
      final write = db.prepare(
        'INSERT INTO app_settings (key, value) VALUES (?, ?) '
        'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
      );
      try {
        for (final MapEntry(:key, :value) in settings.entries) {
          if (omitSettings.contains(key) || value == null) continue;
          write.execute([key, '$value']);
        }
      } finally {
        write.close();
      }
    }
    db.execute('COMMIT');
    report(1);
    return BackupArchiveContents(
      version: sections['version'] as String,
      sections: sections,
      rowsLoaded: loader.loaded,
      tablesSkipped: loader.skipped,
      columnsCarried: loader.carried,
    );
  } finally {
    if (!db.autocommit) db.execute('ROLLBACK');
    db.close();
  }
}

bool _isLinesLayout(String firstBytes) =>
    firstBytes.startsWith('{"version":') &&
    firstBytes.contains('"layout":"$_linesLayout"');

Future<void> _readLines(
  File file,
  int size,
  Map<String, dynamic> sections,
  _TableLoader loader,
  void Function(double fraction) report,
) async {
  var bytesRead = 0;
  var lastReported = 0;
  final lines = file
      .openRead()
      .map((chunk) {
        bytesRead += chunk.length;
        if (bytesRead - lastReported >= 4 << 20) {
          lastReported = bytesRead;
          report(bytesRead / size);
        }
        return chunk;
      })
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  var number = 0;
  var inTables = false;
  var ended = false;
  Never bad(String what) =>
      throw BackupArchiveException('Invalid backup file: line $number $what');
  Object? decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      bad('is not valid JSON');
    }
  }

  String withoutComma(String line) =>
      line.endsWith(',') ? line.substring(0, line.length - 1) : line;

  await for (final line in lines) {
    number++;
    if (line.isEmpty) continue;
    if (ended) bad('follows the end of the backup');
    if (number == 1) {
      sections.addAll(decode('${withoutComma(line)}}') as Map<String, dynamic>);
      checkBackupVersion(sections['version']);
    } else if (line == '}}') {
      if (!inTables) bad('ends a section that never began');
      ended = true;
    } else if (!inTables) {
      if (line == '"tables":{') {
        inTables = true;
      } else {
        final section = decode('{${withoutComma(line)}}');
        if (section is! Map<String, dynamic>) bad('is not a section');
        sections.addAll(section);
      }
    } else if (line.startsWith('[')) {
      final row = decode(withoutComma(line));
      if (row is! List) bad('is not a row');
      loader.addRow(row, 'line $number');
    } else if (line.startsWith(']')) {
      loader.endTable();
    } else {
      final start = decode('{$line]}}');
      if (start is! Map<String, dynamic> ||
          start.length != 1 ||
          start.values.single is! Map) {
        bad('does not begin a table');
      }
      final columns = (start.values.single as Map)['columns'];
      if (columns is! List || columns.any((c) => c is! String)) {
        bad('does not name the columns of "${start.keys.single}"');
      }
      loader.beginTable(start.keys.single, columns.cast<String>());
    }
  }
  if (!ended) {
    throw const BackupArchiveException(
      'Invalid backup file: it ends before the backup does',
    );
  }
}

/// Writes one table's rows after another into the database file.
class _TableLoader {
  _TableLoader(this._db, this._never);

  final Database _db;
  final Set<String> _never;
  final Map<String, int> loaded = {};
  final List<String> skipped = [];
  final Map<String, Set<String>> carried = {};

  String? _table;
  PreparedStatement? _insert;
  List<int> _kept = const [];
  int _width = 0;

  void beginTable(String table, List<String> columns) {
    endTable();
    _table = table;
    _width = columns.length;
    final known = _never.contains(table)
        ? const <String>{}
        : {
            for (final c in _db.select('PRAGMA table_info("$table")'))
              c['name'] as String,
          };
    _kept = [
      for (var i = 0; i < columns.length; i++)
        if (known.contains(columns[i])) i,
    ];
    if (_kept.isEmpty) {
      skipped.add(table);
      return;
    }
    loaded[table] ??= 0;
    (carried[table] ??= {}).addAll([for (final i in _kept) columns[i]]);
    _insert = _db.prepare(
      'INSERT INTO "$table" (${_kept.map((i) => '"${columns[i]}"').join(', ')}) '
      'VALUES (${List.filled(_kept.length, '?').join(', ')})',
    );
  }

  void addRow(List<dynamic> row, String where) {
    final table = _table;
    if (table == null) {
      throw BackupArchiveException(
        'Invalid backup file: $where is a row outside a table',
      );
    }
    if (row.length != _width) {
      throw BackupArchiveException(
        'Invalid backup file: $where of "$table" has ${row.length} cells for '
        '$_width columns',
      );
    }
    final insert = _insert;
    if (insert == null) return;
    try {
      insert.execute([
        for (final i in _kept) decodeBackupCell(row[i], '$where of "$table"'),
      ]);
    } on SqliteException catch (e) {
      throw BackupArchiveException(
        'Invalid backup file: $where of "$table" cannot be a row of this '
        'database (${e.message})',
      );
    }
    loaded[table] = loaded[table]! + 1;
  }

  void endTable() {
    _insert?.close();
    _insert = null;
    _table = null;
  }

  /// The `tables` section of a format decoded whole: table name to a list of
  /// row objects (3.0), or to `columns` and `rows` (3.1).
  void loadDecoded(Object? tables) {
    if (tables is! Map<String, dynamic>) {
      throw const BackupArchiveException(
        'Invalid backup file: "tables" is not an object',
      );
    }
    for (final MapEntry(key: table, :value) in tables.entries) {
      if (value case {'columns': final List columns, 'rows': final List rows}) {
        beginTable(table, columns.cast<String>());
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          if (row is! List) {
            throw BackupArchiveException(
              'Invalid backup file: $table[$i] is not a row',
            );
          }
          addRow(row, 'row $i');
        }
      } else if (value is List) {
        // Rows of one table may differ in the columns they name.
        List<String>? columns;
        for (var i = 0; i < value.length; i++) {
          final row = value[i];
          if (row is! Map<String, dynamic>) {
            throw BackupArchiveException(
              'Invalid backup file: $table[$i] is not an object',
            );
          }
          final names = row.keys.toList();
          if (columns == null || !_sameNames(columns, names)) {
            columns = names;
            beginTable(table, names);
          }
          addRow(row.values.toList(), 'row $i');
        }
        if (value.isEmpty) beginTable(table, const []);
      } else {
        throw BackupArchiveException(
          'Invalid backup file: table "$table" is not a list',
        );
      }
      endTable();
    }
  }

  static bool _sameNames(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The head of the archive at [path] (`version`, `createdAt`, `appVersion`,
/// `platform`, `metadata`) without reading its rows, or null when the file
/// is not a backup.
Future<Map<String, dynamic>?> readBackupArchiveHead(String path) async {
  final file = File(path);
  final handle = await file.open();
  final String prefix;
  try {
    final size = await handle.length();
    prefix = utf8.decode(
      await handle.read(size < 1 << 18 ? size : 1 << 18),
      allowMalformed: true,
    );
  } finally {
    await handle.close();
  }
  try {
    if (_isLinesLayout(prefix)) {
      final line = prefix.substring(0, prefix.indexOf('\n'));
      return jsonDecode('${line.substring(0, line.length - 1)}}')
          as Map<String, dynamic>;
    }
    final head = _headBeforeSections(prefix);
    final decoded = jsonDecode(head ?? await file.readAsString());
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

/// The top-level keys of [prefix] that come before its first large section,
/// closed into an object of their own; null when no such section starts in
/// [prefix].
String? _headBeforeSections(String prefix) {
  const sections = {'settings', 'equipmentProfiles', 'sequences', 'tables'};
  var depth = 0;
  var inString = false;
  var keyStart = -1;
  for (var i = 0; i < prefix.length; i++) {
    final c = prefix.codeUnitAt(i);
    if (inString) {
      if (c == 0x5C) {
        i++;
      } else if (c == 0x22) {
        inString = false;
        if (depth == 1 &&
            keyStart >= 0 &&
            sections.contains(prefix.substring(keyStart + 1, i))) {
          final before = prefix.substring(0, keyStart).trimRight();
          if (!before.endsWith(',')) return null;
          return '${before.substring(0, before.length - 1)}}';
        }
      }
    } else if (c == 0x22) {
      inString = true;
      keyStart = i;
    } else if (c == 0x7B || c == 0x5B) {
      depth++;
    } else if (c == 0x7D || c == 0x5D) {
      depth--;
    }
  }
  return null;
}
