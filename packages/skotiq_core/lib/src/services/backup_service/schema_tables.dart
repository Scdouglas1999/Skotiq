part of '../backup_service.dart';

/// The tables a backup leaves out, each with why. Every other table of the
/// schema is in the backup's `tables` section, so a table added later is in
/// the next backup without anyone listing it.
const Map<String, String> backupExcludedTables = {
  'sequence_checkpoints':
      "a run's crash-recovery point on this machine; restored, it would offer "
      'to resume a run that never ran here',
  'darkroom_jobs':
      'the Darkroom work queue; a queued or running job restored from a '
      'backup would start by itself',
  'delivery_journal':
      'the send log of darkroom_jobs rows, which a backup does not hold',
};

/// The tables a backup holds in a section of their own, restored by their
/// own rule rather than row by row.
const Map<String, String> backupOwnSectionTables = {
  'app_settings':
      '"settings": key and value; the backup wins, and the backup folder stays '
      "this machine's",
  'equipment_profiles':
      '"equipmentProfiles": matched by name, so a restore updates the profile '
      'of that name; rows that point at a profile follow it to its id here',
};

/// The table rows that have a rule of their own inside the `tables` section.
const Map<String, String> backupRowRules = {
  'weather_settings':
      'one configuration row the database always holds; the backup row is '
      'written into it',
};

/// What the live schema says about one table, read from SQLite itself.
class _TableShape {
  _TableShape({
    required this.columns,
    required this.notNull,
    required this.primaryKey,
    required this.foreignKeys,
  });

  final List<String> columns;
  final Set<String> notNull;

  /// The one column the primary key is, or null for a composite or rowid key.
  final String? primaryKey;
  final List<_ForeignKey> foreignKeys;
}

class _ForeignKey {
  const _ForeignKey(this.id, this.column, this.parent, this.parentColumn);

  final int id;
  final String column;
  final String parent;

  /// Null when the key names no column: it is the parent's primary key.
  final String? parentColumn;
}

extension _BackupSchemaTables on BackupService {
  Iterable<String> get _backedUpTableNames => database.allTables
      .map((table) => table.actualTableName)
      .where(
        (name) =>
            !backupExcludedTables.containsKey(name) &&
            !backupOwnSectionTables.containsKey(name),
      );

  /// Every backed-up table's rows as SQLite holds them, by table name.
  Future<Map<String, List<Map<String, Object?>>>> _exportTables() async => {
    for (final name in _backedUpTableNames) name: await _dumpRows(name),
  };

  /// Rows are read in [BackupService._dumpPageSize] pages ordered by `rowid`.
  /// The per-frame science tables run to hundreds of thousands of rows over a
  /// season; one unpaged `SELECT *` would hold the whole result set beside the
  /// whole JSON projection. The caller reads inside one transaction, so the
  /// pages are one snapshot.
  Future<List<Map<String, Object?>>> _dumpRows(String table) async {
    final out = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      final rows = await database
          .customSelect(
            'SELECT * FROM "$table" ORDER BY rowid '
            'LIMIT ${BackupService._dumpPageSize} OFFSET $offset',
          )
          .get();
      for (final row in rows) {
        out.add({
          for (final MapEntry(:key, :value) in row.data.entries)
            key: _encodeCell(value),
        });
      }
      if (rows.length < BackupService._dumpPageSize) return out;
      offset += rows.length;
    }
  }

  Future<_TableShape> _shapeOf(String table) async {
    final info = await database
        .customSelect('PRAGMA table_info("$table")')
        .get();
    final keys = [
      for (final c in info)
        if (c.read<int>('pk') > 0) c.read<String>('name'),
    ];
    final fks = await database
        .customSelect('PRAGMA foreign_key_list("$table")')
        .get();
    return _TableShape(
      columns: [for (final c in info) c.read<String>('name')],
      notNull: {
        for (final c in info)
          if (c.read<int>('notnull') == 1) c.read<String>('name'),
      },
      primaryKey: keys.length == 1 ? keys.single : null,
      foreignKeys: [
        for (final fk in fks)
          _ForeignKey(
            fk.read<int>('id'),
            fk.read<String>('from'),
            fk.read<String>('table'),
            fk.readNullable<String>('to'),
          ),
      ],
    );
  }

  /// Restore the `tables` section of a 3.x backup inside the caller's
  /// transaction.
  ///
  /// A merge keeps every live row: a backup row whose key is taken is left
  /// out, and when the live row there is a different one, the backup rows
  /// that point at it are left out too, rather than attached to the wrong
  /// parent. A replace lets the backup row win in place, without deleting
  /// anything. Rows pointing at a profile follow [profileIds] to its id
  /// here. Foreign keys are checked at commit; a restored row whose parent
  /// is in neither the backup nor the database loses that link, or is left
  /// out when it cannot exist without it. Returns the rows written per table.
  Future<Map<String, int>> _restoreTables(
    Map<String, dynamic> tables, {
    required bool replace,
    required Map<int, int> profileIds,
  }) async {
    await database.customStatement('PRAGMA defer_foreign_keys = ON');
    final violationsBefore = await _foreignKeyViolations();
    final live = database.allTables.map((t) => t.actualTableName).toSet();
    final shapes = <String, _TableShape>{
      for (final name in tables.keys)
        if (live.contains(name) && !backupExcludedTables.containsKey(name))
          name: await _shapeOf(name),
    };
    for (final name in tables.keys.where((n) => !shapes.containsKey(n))) {
      _logger.warning(
        'Backup table "$name" is not restored: '
        '${backupExcludedTables[name] ?? 'this version has no such table'}',
        source: 'BackupService',
      );
    }

    final counts = <String, int>{};
    final keptLive = <String, Set<Object>>{};
    var skipped = 0;
    for (final name in _parentsFirst(shapes)) {
      final rows = (tables[name] as List).cast<Map<String, dynamic>>();
      if (name == 'weather_settings') {
        if (rows.isNotEmpty) {
          counts[name] = await _importWeatherSettings(
            database.weatherSettings.map(_decodeRow(rows.first)),
          );
        }
        continue;
      }
      final shape = shapes[name]!;
      var written = 0;
      for (final raw in rows) {
        final row = _decodeRow(raw)
          ..removeWhere((column, _) => !shape.columns.contains(column));
        if (row.isEmpty) continue;
        var orphanOfKept = false;
        for (final fk in shape.foreignKeys) {
          final value = row[fk.column];
          if (value == null) continue;
          if (fk.parent == 'equipment_profiles' && value is int) {
            row[fk.column] = profileIds[value] ?? value;
          } else if ((fk.parentColumn == null ||
                  fk.parentColumn == shapes[fk.parent]?.primaryKey) &&
              (keptLive[fk.parent]?.contains(value) ?? false)) {
            orphanOfKept = true;
          }
        }
        if (orphanOfKept) {
          skipped++;
          continue;
        }
        if (await _writeRow(name, row, replace: replace) > 0) {
          written++;
        } else if (shape.primaryKey case final key?
            when row[key] != null && !await _liveRowEquals(name, key, row)) {
          (keptLive[name] ??= {}).add(row[key]!);
          skipped++;
        }
      }
      counts[name] = written;
    }
    if (skipped > 0) {
      _logger.warning(
        '$skipped backup rows not restored: the database already holds a '
        'different row under the same key, or one such row is their parent',
        source: 'BackupService',
      );
    }
    await _settleOrphans(violationsBefore, shapes);
    return counts;
  }

  /// Table names in an order that restores every parent before its children
  /// (a self-reference does not count; such rows come in `rowid` order).
  List<String> _parentsFirst(Map<String, _TableShape> shapes) {
    final ordered = <String>[];
    final placed = <String>{};
    void place(String name, Set<String> visiting) {
      if (placed.contains(name) || !visiting.add(name)) return;
      for (final fk in shapes[name]!.foreignKeys) {
        if (fk.parent != name && shapes.containsKey(fk.parent)) {
          place(fk.parent, visiting);
        }
      }
      placed.add(name);
      ordered.add(name);
    }

    for (final name in shapes.keys) {
      place(name, {});
    }
    return ordered;
  }

  Future<int> _writeRow(
    String table,
    Map<String, Object?> row, {
    required bool replace,
  }) {
    final columns = row.keys.toList();
    final names = columns.map((c) => '"$c"').join(', ');
    final marks = List.filled(columns.length, '?').join(', ');
    final sql = replace
        ? 'INSERT INTO "$table" ($names) VALUES ($marks) ON CONFLICT DO '
              'UPDATE SET ${columns.map((c) => '"$c" = excluded."$c"').join(', ')}'
        : 'INSERT OR IGNORE INTO "$table" ($names) VALUES ($marks)';
    return database.customUpdate(
      sql,
      variables: [for (final c in columns) _variable(row[c])],
      updateKind: UpdateKind.insert,
    );
  }

  Future<bool> _liveRowEquals(
    String table,
    String key,
    Map<String, Object?> row,
  ) async {
    final live = await database
        .customSelect(
          'SELECT * FROM "$table" WHERE "$key" = ?',
          variables: [_variable(row[key])],
        )
        .getSingleOrNull();
    if (live == null) return true;
    for (final MapEntry(key: column, :value) in row.entries) {
      final here = live.data[column];
      if (value is Uint8List && here is Uint8List) {
        if (!listEquals(value, here)) return false;
      } else if (value != here) {
        return false;
      }
    }
    return true;
  }

  Future<Set<(String, int)>> _foreignKeyViolations() async => {
    for (final v
        in await database.customSelect('PRAGMA foreign_key_check').get())
      if (v.readNullable<int>('rowid') case final rowid?)
        (v.read<String>('table'), rowid),
  };

  /// Settle the foreign keys the restore broke (not ones the database already
  /// had): a nullable link to a parent that is nowhere is cleared, a row that
  /// cannot exist without it is removed.
  Future<void> _settleOrphans(
    Set<(String, int)> before,
    Map<String, _TableShape> shapes,
  ) async {
    var cleared = 0;
    var removed = 0;
    final violations = await database
        .customSelect('PRAGMA foreign_key_check')
        .get();
    for (final v in violations) {
      final table = v.read<String>('table');
      final rowid = v.readNullable<int>('rowid');
      if (rowid == null || before.contains((table, rowid))) continue;
      final shape = shapes[table] ?? await _shapeOf(table);
      final fkId = v.read<int>('fkid');
      final columns = [
        for (final fk in shape.foreignKeys)
          if (fk.id == fkId) fk.column,
      ];
      if (columns.any(shape.notNull.contains)) {
        await database.customUpdate(
          'DELETE FROM "$table" WHERE rowid = ?',
          variables: [Variable.withInt(rowid)],
          updateKind: UpdateKind.delete,
        );
        removed++;
      } else {
        await database.customUpdate(
          'UPDATE "$table" SET ${columns.map((c) => '"$c" = NULL').join(', ')} '
          'WHERE rowid = ?',
          variables: [Variable.withInt(rowid)],
          updateKind: UpdateKind.update,
        );
        cleared++;
      }
    }
    if (cleared + removed > 0) {
      _logger.warning(
        'Restored rows pointing at records in neither the backup nor this '
        'database: $cleared links cleared, $removed rows left out',
        source: 'BackupService',
      );
    }
  }
}

/// A cell as the archive holds it. JSON has no bytes and no NaN or infinity,
/// so those travel as one-key objects.
Object? _encodeCell(Object? value) => switch (value) {
  final Uint8List bytes => {_blobKey: base64Encode(bytes)},
  final double d when !d.isFinite => {_doubleKey: d.toString()},
  _ => value,
};

Object? _decodeCell(Object? value) => switch (value) {
  {_blobKey: final String b64} => base64Decode(b64),
  {_doubleKey: final String d} => double.parse(d),
  bool b => b ? 1 : 0,
  _ => value,
};

const _blobKey = r'$blob';
const _doubleKey = r'$double';

Map<String, Object?> _decodeRow(Map<String, dynamic> row) => {
  for (final MapEntry(:key, :value) in row.entries) key: _decodeCell(value),
};

Variable<Object> _variable(Object? value) => switch (value) {
  null => const Variable<Object>(null),
  final int i => Variable.withInt(i),
  final double d => Variable.withReal(d),
  final String s => Variable.withString(s),
  final Uint8List b => Variable.withBlob(b),
  _ => throw FormatException('Backup cell $value is not a database value'),
};
