part of '../backup_service.dart';

/// How a merge tells whether a backup row is a record this database already
/// has, and what the row hangs on.
///
/// A row id says nothing across two databases: each numbers its own rows. A
/// backup row is the record a live row is when the two agree on one of
/// [keys], after every link in the backup row is read as the live row its
/// parent turned out to be.
class BackupMergeRule {
  const BackupMergeRule({
    this.keys = const [],
    this.partOf = const [],
    this.links = const {},
    this.typedLinks = const {},
    this.listLinks = const {},
    this.plainIds = const [],
    this.group,
  });

  /// The column sets that identify a record, tried in order. Empty means the
  /// primary key when that is not a row id, else every column but the row id:
  /// a row is the record with the same content.
  final List<List<String>> keys;

  /// Link columns to the record this row is a part of: the first of them
  /// that is set names it. A part is restored with its record; nothing is
  /// added inside a record that is already here.
  final List<String> partOf;

  /// Columns that hold another table's row id without a foreign key, to the
  /// table they point into.
  final Map<String, String> links;

  /// Columns whose table is named by another column of the row.
  final Map<String, BackupTypedLink> typedLinks;

  /// Columns that hold a JSON list of another table's row ids.
  final Map<String, String> listLinks;

  /// Integer `_id` columns that are not row ids of this database.
  final List<String> plainIds;

  /// Tables that are one body of data, built up from this database's own
  /// sessions: restored only where none of them holds a row.
  final String? group;
}

/// A link whose parent table depends on [typeColumn].
class BackupTypedLink {
  const BackupTypedLink(this.typeColumn, this.tables);

  final String typeColumn;

  /// Value of [typeColumn] to the table the link points into.
  final Map<String, String> tables;
}

/// The tables a merge leaves as they are: this install's own configuration.
const Map<String, String> backupMergeKeepsYours = {
  'app_settings': 'your settings stay; a replace takes the backup\'s',
  'weather_settings': 'the weather safety limits are settings',
};

const _frameData = BackupMergeRule(partOf: ['captured_image_id', 'session_id']);
const _skyAtlas = 'sky atlas';

/// The rule of every table a merge reads. A table without one cannot be
/// merged, so a new table is given its rule when it is added.
const Map<String, BackupMergeRule> backupMergeRules = {
  'astrometry_residual_vectors': _frameData,
  'calibration_tags': BackupMergeRule(
    keys: [
      ['master_type', 'master_id'],
    ],
    typedLinks: {
      'master_id': BackupTypedLink('master_type', {
        'dark': 'dark_library',
        'bias': 'dark_library',
        'flat': 'flat_library',
        'defectMap': 'defect_maps',
      }),
    },
  ),
  'campaigns': BackupMergeRule(
    keys: [
      ['target_id', 'filter'],
    ],
    partOf: ['target_id'],
  ),
  'captured_images': BackupMergeRule(
    keys: [
      ['id', 'captured_at'],
      ['file_path', 'captured_at'],
    ],
  ),
  'co_imaging_sessions': BackupMergeRule(
    keys: [
      ['hub_key', 'session_id'],
    ],
  ),
  'constellation_contributions': BackupMergeRule(
    keys: [
      ['hub_key', 'tile_id', 'healpix_order'],
    ],
    plainIds: ['tile_id'],
  ),
  'conversational_builds': BackupMergeRule(),
  'dark_library': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
      ['file_path', 'created_at'],
    ],
  ),
  'darkroom_state': BackupMergeRule(),
  'defect_maps': BackupMergeRule(
    keys: [
      ['camera_id', 'width', 'height', 'temperature_bucket_decicelsius'],
    ],
  ),
  'delivery_targets': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'equipment_profiles': BackupMergeRule(
    keys: [
      ['name'],
    ],
  ),
  'flat_history': BackupMergeRule(),
  'flat_library': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
      ['file_path', 'created_at'],
    ],
  ),
  'focus_models': BackupMergeRule(
    keys: [
      ['uuid'],
    ],
  ),
  'frame_forensics': BackupMergeRule(
    partOf: ['captured_image_id'],
    links: {'sequence_run_id': 'sequence_runs'},
  ),
  'frame_photometric_calibration': _frameData,
  'guide_rms_history': BackupMergeRule(links: {'target_id': 'targets'}),
  'horizon_profiles': BackupMergeRule(
    keys: [
      ['name'],
    ],
  ),
  'image_metadata': BackupMergeRule(
    keys: [
      ['image_id', 'key'],
    ],
    partOf: ['image_id'],
  ),
  'imaging_sessions': BackupMergeRule(
    keys: [
      ['id', 'start_time'],
    ],
  ),
  'integrated_master_frames': BackupMergeRule(
    keys: [
      ['master_id', 'image_id'],
    ],
    partOf: ['master_id'],
  ),
  'integrated_masters': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'integration_goals': BackupMergeRule(
    keys: [
      ['target_id', 'filter', 'exposure_seconds'],
    ],
    partOf: ['target_id'],
  ),
  'line_ratio_products': BackupMergeRule(partOf: ['session_id']),
  'living_sky_retention': BackupMergeRule(
    keys: [
      ['scope'],
    ],
    plainIds: ['last_pruned_id'],
  ),
  'mosaic_panels': BackupMergeRule(
    keys: [
      ['project_id', 'panel_index'],
    ],
    partOf: ['project_id'],
    links: {'uploaded_master_id': 'integrated_masters'},
  ),
  'mosaic_projects': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'moving_object_candidates': _frameData,
  'narrator_events': BackupMergeRule(partOf: ['session_id']),
  'narrowband_composites': BackupMergeRule(
    listLinks: {'component_master_ids': 'integrated_masters'},
  ),
  'night_reports': BackupMergeRule(partOf: ['session_id']),
  'notes_journal': BackupMergeRule(links: {'sequence_run_id': 'sequence_runs'}),
  'observation_logs': BackupMergeRule(),
  'observing_list_items': BackupMergeRule(
    keys: [
      ['list_id', 'catalog_id', 'object_name'],
    ],
    partOf: ['list_id'],
  ),
  'observing_lists': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'photometric_transforms': BackupMergeRule(),
  'photometry_measurements': _frameData,
  'polar_alignment_history': BackupMergeRule(),
  'project_targets': BackupMergeRule(
    keys: [
      ['project_id', 'target_id'],
    ],
    partOf: ['project_id'],
  ),
  'projects': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'psf_field_tiles': _frameData,
  'recipes': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
  ),
  'scheduler_removed_targets': BackupMergeRule(partOf: ['target_id']),
  'science_frame_quality_metrics': _frameData,
  'science_session_config': BackupMergeRule(
    keys: [
      ['session_id'],
    ],
    partOf: ['session_id'],
  ),
  'science_tile_metrics': _frameData,
  'sequence_decisions': BackupMergeRule(
    partOf: ['sequence_run_id'],
    links: {'sequence_run_id': 'sequence_runs'},
  ),
  'sequence_nodes': BackupMergeRule(
    keys: [
      ['sequence_id', 'node_id'],
    ],
    partOf: ['sequence_id'],
  ),
  'sequence_runs': BackupMergeRule(
    keys: [
      ['id', 'started_at'],
    ],
  ),
  'sequence_versions': BackupMergeRule(partOf: ['sequence_id']),
  'sequences': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
      ['name', 'created_at'],
    ],
  ),
  'session_diagnostics': BackupMergeRule(partOf: ['session_id']),
  'sky_atlas_folds': BackupMergeRule(group: _skyAtlas, plainIds: ['tile_id']),
  'sky_atlas_regions': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
    ],
    group: _skyAtlas,
  ),
  'sky_tiles': BackupMergeRule(
    keys: [
      ['tile_id', 'healpix_order'],
    ],
    group: _skyAtlas,
    plainIds: ['tile_id'],
  ),
  'stacked_results': BackupMergeRule(
    links: {'session_id': 'imaging_sessions', 'target_id': 'targets'},
  ),
  'target_constraints': BackupMergeRule(partOf: ['target_id']),
  'targets': BackupMergeRule(
    keys: [
      ['id', 'created_at'],
      ['name', 'catalog_id', 'ra', 'dec'],
    ],
  ),
  'transient_detections': BackupMergeRule(
    partOf: ['session_id'],
    plainIds: ['tile_id'],
  ),
  'transparency_samples': _frameData,
  'tutorial_progress': BackupMergeRule(
    keys: [
      ['category'],
    ],
  ),
};

/// What became of a backup row, as the merge records it.
abstract final class _Fate {
  static const added = 1;
  static const same = 2;

  static const leftOut = <int, RestoreLeftOut>{
    3: RestoreLeftOut.yoursKept,
    10: RestoreLeftOut.ownerLeftOut,
    11: RestoreLeftOut.ownerNotInBackup,
    12: RestoreLeftOut.insideYours,
    13: RestoreLeftOut.conflict,
    14: RestoreLeftOut.yoursOnly,
  };
  static const yoursKept = 3;
  static const ownerLeftOut = 10;
  static const ownerNotInBackup = 11;
  static const insideYours = 12;
  static const conflict = 13;
  static const yoursOnly = 14;
}

/// A column of a merged table that names a row of another table.
class _MergeLink {
  const _MergeLink.to(String this.parent) : typed = null, list = false;
  const _MergeLink.typed(BackupTypedLink this.typed)
    : parent = null,
      list = false;
  const _MergeLink.list(String this.parent) : typed = null, list = true;

  final String? parent;
  final BackupTypedLink? typed;
  final bool list;

  Iterable<String> get parents => typed?.tables.values ?? [parent!];
}

class _MergeTable {
  _MergeTable({
    required this.name,
    required this.columns,
    required this.types,
    required this.primaryKey,
    required this.rowId,
    required this.links,
    required this.rule,
  });

  final String name;
  final List<String> columns;

  /// The declared type of each column.
  final Map<String, String> types;
  final List<String> primaryKey;

  /// The integer primary key this database hands out, or null when the key
  /// is text, composite, or a link to the row's owner.
  final String? rowId;
  final Map<String, _MergeLink> links;
  final BackupMergeRule rule;

  String? get selfLink {
    for (final MapEntry(key: column, value: link) in links.entries) {
      if (link.parent == name) return column;
    }
    return null;
  }

  /// Every column that makes up the record: all but the row id.
  List<String> get content => [
    for (final c in columns)
      if (c != rowId) c,
  ];

  List<List<String>> get keys => rule.keys.isNotEmpty
      ? rule.keys
      : [rowId == null && primaryKey.isNotEmpty ? primaryKey : content];
}

String _q(String name) => '"$name"';
const _bk = 'skbk';
String _x(String table) => '$_bk."x\$$table"';
String _m(String table) => '$_bk."m\$$table"';
const _rid = r'"$rid"';
const _out = r'"$out"';
const _own = r'"$own"';
const _round = r'"$round"';

class _MergeOutcome {
  final added = <String, int>{};
  final notRestored = <String, int>{};
  final leftOut = <RestoreLeftOut, int>{};
  var alreadyHere = 0;
}

extension _BackupMerge on BackupService {
  /// The merged tables with what the live schema says of them, parents
  /// before the tables that link to them.
  Future<List<_MergeTable>> _mergePlan() async {
    final tables = <String, _MergeTable>{};
    for (final info in database.allTables) {
      final name = info.actualTableName;
      if (backupExcludedTables.containsKey(name) ||
          backupMergeKeepsYours.containsKey(name)) {
        continue;
      }
      final rule = backupMergeRules[name];
      if (rule == null) {
        throw StateError('Table "$name" has no backup merge rule');
      }
      final columns = await database
          .customSelect('PRAGMA main.table_info("$name")')
          .get();
      final links = <String, _MergeLink>{
        for (final fk
            in await database
                .customSelect('PRAGMA main.foreign_key_list("$name")')
                .get())
          fk.read<String>('from'): _MergeLink.to(fk.read<String>('table')),
        for (final MapEntry(:key, :value) in rule.links.entries)
          key: _MergeLink.to(value),
        for (final MapEntry(:key, :value) in rule.typedLinks.entries)
          key: _MergeLink.typed(value),
        for (final MapEntry(:key, :value) in rule.listLinks.entries)
          key: _MergeLink.list(value),
      };
      final key = [
        for (final c in columns)
          if (c.read<int>('pk') > 0) c,
      ]..sort((a, b) => a.read<int>('pk').compareTo(b.read<int>('pk')));
      final single = key.length == 1 ? key.single : null;
      tables[name] = _MergeTable(
        name: name,
        columns: [for (final c in columns) c.read<String>('name')],
        types: {
          for (final c in columns)
            c.read<String>('name'): c.read<String>('type'),
        },
        primaryKey: [for (final c in key) c.read<String>('name')],
        rowId:
            single != null &&
                single.read<String>('type').toUpperCase() == 'INTEGER' &&
                !links.containsKey(single.read<String>('name'))
            ? single.read<String>('name')
            : null,
        links: links,
        rule: rule,
      );
    }
    for (final table in tables.values) {
      for (final parent in table.links.values.expand((l) => l.parents)) {
        if (tables[parent]?.rowId == null) {
          throw StateError(
            '"${table.name}" links to "$parent", which a merge cannot follow',
          );
        }
      }
    }
    final ordered = <_MergeTable>[];
    final placed = <String>{};
    void place(_MergeTable table, Set<String> visiting) {
      if (placed.contains(table.name) || !visiting.add(table.name)) return;
      for (final parent in table.links.values.expand((l) => l.parents)) {
        if (parent != table.name) place(tables[parent]!, visiting);
      }
      placed.add(table.name);
      ordered.add(table);
    }

    for (final table in tables.values) {
      place(table, {});
    }
    return ordered;
  }

  /// Add to this database the records of the database file [staged] that it
  /// does not have, in one transaction.
  ///
  /// Each backup row gets one fate. It is the same record as a live row (by
  /// its table's [BackupMergeRule]): the live row stays as it is and the
  /// backup rows that link to it link to the live row. Or it is added, under
  /// its own id when that is free and a new one otherwise, and the rows that
  /// link to it follow it there. Or it is left out, with the reason, and so
  /// is every row that links to it. No row is written with a link it did not
  /// have, and none with a link taken away.
  ///
  /// [carried] names the columns the backup holds for each table. A column it
  /// does not hold (the schema gained it after the backup was written) is not
  /// compared: the backup says nothing about it, so a live row that differs
  /// only there is the same record, and an added row takes the column's
  /// default.
  Future<_MergeOutcome> _mergeFrom(
    File staged,
    Map<String, Set<String>> carried,
    void Function(String step, double fraction) progress,
  ) async {
    await database.customStatement('ATTACH DATABASE ? AS $_bk', [staged.path]);
    try {
      // The attached file is scratch: it is deleted after the merge.
      await database.customSelect('PRAGMA $_bk.journal_mode = MEMORY').get();
      await database.customStatement('PRAGMA $_bk.synchronous = OFF');
      final outcome = await database.transaction(() async {
        await database.customStatement('PRAGMA defer_foreign_keys = ON');
        final plan = await _mergePlan();
        final rows = <String, int>{
          for (final table in plan)
            table.name: await _count('$_bk.${_q(table.name)}'),
        };
        final total = rows.values.fold<int>(0, (sum, n) => sum + n);
        final liveRows = <String, int>{
          for (final table in plan)
            table.name: await _count('main.${_q(table.name)}'),
        };
        final groupsInUse = {
          for (final table in plan)
            if (table.rule.group != null && liveRows[table.name]! > 0)
              table.rule.group!,
        };
        for (final table in plan) {
          await database.customStatement(
            'CREATE TABLE ${_m(table.name)} '
            '(bk INTEGER PRIMARY KEY, live INTEGER, fate INTEGER NOT NULL)',
          );
        }
        final outcome = _MergeOutcome();
        var done = 0;
        for (final table in plan) {
          final name = table.name;
          final step = name.replaceAll('_', ' ');
          final size = rows[name]!;
          progress(step, total == 0 ? 1 : done / total);
          if (size == 0) continue;
          final watch = Stopwatch()..start();
          // Counted only for a table that is about to gain rows.
          int? brokenBefore;
          await _mergeTable(
            table,
            liveIsEmpty: liveRows[name] == 0,
            yoursOnly: groupsInUse.contains(table.rule.group),
            // Which profile is in use is this install's choice.
            overrides: name == 'equipment_profiles' && liveRows[name]! > 0
                ? const {'is_active': '0', 'is_default': '0'}
                : const {},
            carried: carried[name],
            tick: (part) => progress(step, (done + size * part) / total),
            beforeAdding: () async =>
                brokenBefore ??= await _brokenLinks(table),
          );
          done += size;
          final fates = await database
              .customSelect(
                'SELECT fate, count(*) AS n FROM ${_m(name)} GROUP BY fate',
              )
              .get();
          for (final row in fates) {
            final fate = row.read<int>('fate');
            final n = row.read<int>('n');
            if (fate == _Fate.added) {
              outcome.added[name] = n;
            } else if (fate == _Fate.same) {
              outcome.alreadyHere += n;
            } else {
              outcome.notRestored.update(name, (v) => v + n, ifAbsent: () => n);
              outcome.leftOut.update(
                _Fate.leftOut[fate]!,
                (v) => v + n,
                ifAbsent: () => n,
              );
            }
          }
          // Every link of an added row was read as a row that is here, so
          // none can be broken; a merge that broke one is not kept.
          if (brokenBefore case final before?) {
            final broken = await _brokenLinks(table) - before;
            if (broken > 0) {
              throw StateError(
                'The merge would leave $broken rows of "$name" pointing at '
                'records that are not there',
              );
            }
          }
          _logger.debug(
            'Merged $name: $size backup rows in ${watch.elapsedMilliseconds} '
            'ms',
            source: 'BackupService',
          );
        }
        return outcome;
      });
      database.markTablesUpdated(database.allTables);
      return outcome;
    } finally {
      await database.customStatement('DETACH DATABASE $_bk');
    }
  }

  Future<int> _count(String table) async =>
      (await database
              .customSelect('SELECT count(*) AS n FROM $table')
              .getSingle())
          .read<int>('n');

  /// How many rows of the live [table] point at a record that is not there.
  /// A table with no link has none; the check reads the whole table, so it
  /// is not asked for one.
  Future<int> _brokenLinks(_MergeTable table) async {
    final foreign = await database
        .customSelect('PRAGMA main.foreign_key_list("${table.name}")')
        .get();
    if (foreign.isEmpty) return 0;
    return (await database
            .customSelect('PRAGMA main.foreign_key_check("${table.name}")')
            .get())
        .length;
  }

  Future<void> _mergeTable(
    _MergeTable t, {
    required bool liveIsEmpty,
    required bool yoursOnly,
    required Map<String, String> overrides,
    required Set<String>? carried,
    required void Function(double part) tick,
    required Future<void> Function() beforeAdding,
  }) async {
    // `1` where the backup holds none of the columns: nothing to differ in.
    String equal(Iterable<String> columns, String a, String b) {
      final terms = [
        for (final c in columns)
          if (carried == null || carried.contains(c))
            '$a.${_q(c)} IS $b.${_q(c)}',
      ];
      return terms.isEmpty ? '1' : terms.join(' AND ');
    }

    final x = _x(t.name);
    final m = _m(t.name);
    final live = 'main.${_q(t.name)}';
    final self = t.selfLink;

    // The backup rows with every link read as the live row it now names.
    final select = <String>['b.rowid'];
    final joins = <String>[];
    final ownerLeftOut = <String>[];
    final ownerAbsent = <String>[];
    final owner = <String, String>{};
    var alias = 0;
    for (final column in t.columns) {
      final link = t.links[column];
      final value = 'b.${_q(column)}';
      if (link == null || link.parent == t.name) {
        select.add(value);
      } else if (link.list) {
        final ids =
            'json_each($value) j LEFT JOIN ${_m(link.parent!)} p '
            'ON p.bk = j.value';
        select.add(
          'CASE WHEN json_valid($value) THEN '
          '(SELECT json_group_array(p.live) FROM $ids) END',
        );
        ownerAbsent.add(
          '($value IS NOT NULL AND CASE WHEN json_valid($value) THEN EXISTS '
          '(SELECT 1 FROM $ids WHERE p.live IS NULL) ELSE 1 END)',
        );
      } else if (link.typed case final typed?) {
        final cases = <String>[];
        for (final MapEntry(key: type, value: parent) in typed.tables.entries) {
          final p = 'p${alias++}';
          joins.add(
            'LEFT JOIN ${_m(parent)} $p ON b.${_q(typed.typeColumn)} = '
            "'$type' AND $p.bk = $value",
          );
          cases.add("WHEN '$type' THEN $p.live");
        }
        final translated =
            'CASE b.${_q(typed.typeColumn)} ${cases.join(' ')} END';
        select.add('CASE WHEN $value IS NULL THEN NULL ELSE $translated END');
        ownerAbsent.add('($value IS NOT NULL AND $translated IS NULL)');
      } else {
        final p = 'p${alias++}';
        joins.add('LEFT JOIN ${_m(link.parent!)} $p ON $p.bk = $value');
        select.add('$p.live');
        ownerLeftOut.add('($p.bk IS NOT NULL AND $p.live IS NULL)');
        ownerAbsent.add('($value IS NOT NULL AND $p.bk IS NULL)');
        if (t.rule.partOf.contains(column)) {
          owner[column] =
              'WHEN $value IS NOT NULL THEN '
              '$p.fate IN (${_Fate.same}, ${_Fate.yoursKept})';
        }
      }
    }
    select
      ..add(
        'CASE WHEN ${ownerLeftOut.isEmpty ? '0' : ownerLeftOut.join(' OR ')} '
        'THEN ${_Fate.ownerLeftOut} '
        'WHEN ${ownerAbsent.isEmpty ? '0' : ownerAbsent.join(' OR ')} '
        'THEN ${_Fate.ownerNotInBackup} ELSE 0 END',
      )
      ..add(
        owner.isEmpty
            ? '0'
            : 'CASE ${t.rule.partOf.map((c) => owner[c]!).join(' ')} '
                  'ELSE 0 END',
      )
      ..add(self == null ? '0' : '-1');
    // Each column keeps its declared type, so a comparison with the live
    // column can use an index on this one.
    await database.customStatement(
      'CREATE TABLE $x ($_rid INTEGER PRIMARY KEY, '
      '${t.columns.map((c) => '${_q(c)} ${t.types[c]}').join(', ')}, '
      '$_out, $_own, $_round)',
    );
    await database.customStatement(
      'INSERT INTO $x SELECT ${select.join(', ')} '
      'FROM $_bk.${_q(t.name)} b ${joins.join(' ')}',
    );
    await database.customStatement(
      'INSERT INTO $m SELECT $_rid, NULL, $_out FROM $x WHERE $_out <> 0',
    );
    if (!liveIsEmpty) {
      // A row whose owner the backup does not hold (a 2.x backup has rows of
      // sessions it left out) cannot be placed, but it can be recognized: the
      // same row under the same id is here already.
      await database.customStatement(
        'UPDATE $m AS m SET live = bk, fate = ${_Fate.same} '
        'WHERE fate = ${_Fate.ownerNotInBackup} AND EXISTS ('
        'SELECT 1 FROM $_bk.${_q(t.name)} b JOIN $live l ON l.rowid = b.rowid '
        'WHERE b.rowid = m.bk AND '
        "${equal(t.columns, 'b', 'l')})",
      );
    }

    // A key is what the backup holds of it: a key column the backup does
    // not hold cannot tell two records apart.
    final keys = [
      for (final key in t.keys)
        [
          for (final c in key)
            if (carried == null || carried.contains(c)) c,
        ],
    ].where((key) => key.isNotEmpty).toList();

    // One index per key, and the live table read once per key with each of
    // its rows looked up there: the time a match takes does not depend on
    // which index of the live table the planner would have liked.
    final keyIndexes = <String>[];
    if (!liveIsEmpty) {
      for (var i = 0; i < keys.length; i++) {
        final index = _q('k\$${t.name}\$$i');
        keyIndexes.add(index);
        await database.customStatement(
          'CREATE INDEX $_bk.$index ON ${_q('x\$${t.name}')} '
          '(${keys[i].map(_q).join(', ')})',
        );
      }
    }

    tick(0.3);

    Future<void> settle(int round) async {
      if (!liveIsEmpty) {
        final same = equal(t.content, 'x', 'l');
        for (final (i, key) in keys.indexed) {
          await database.customStatement(
            'INSERT OR IGNORE INTO $m '
            'SELECT x.$_rid, '
            'coalesce(min(CASE WHEN $same THEN l.rowid END), min(l.rowid)), '
            'CASE WHEN max($same) = 1 THEN ${_Fate.same} '
            'ELSE ${_Fate.yoursKept} END '
            'FROM $live l CROSS JOIN $x x INDEXED BY ${keyIndexes[i]} '
            'ON ${key.map((c) => 'x.${_q(c)} IS l.${_q(c)}').join(' AND ')} '
            'WHERE x.$_out = 0 AND x.$_round = ? GROUP BY x.$_rid',
            [round],
          );
        }
      }
      tick(0.7);
      const unsettled = 'NOT EXISTS (SELECT 1 FROM';
      final rest =
          'x.$_out = 0 AND x.$_round = $round '
          'AND $unsettled $m m WHERE m.bk = x.$_rid)';
      await database.customStatement(
        'INSERT INTO $m SELECT x.$_rid, NULL, ${_Fate.insideYours} '
        'FROM $x x WHERE x.$_own = 1 AND $rest',
      );
      if (yoursOnly) {
        await database.customStatement(
          'INSERT INTO $m SELECT x.$_rid, NULL, ${_Fate.yoursOnly} '
          'FROM $x x WHERE $rest',
        );
      }

      final values = [
        for (final c in t.content) overrides[c] ?? 'x.${_q(c)}',
      ].join(', ');
      final rowId = t.rowId;
      final int expected;
      if (rowId != null) {
        // Its own id where that is free; otherwise one above every id either
        // database has used.
        final sequence = await database
            .customSelect(
              "SELECT 1 FROM main.sqlite_master WHERE name = 'sqlite_sequence'",
            )
            .get();
        final base =
            (await database
                    .customSelect(
                      'SELECT max('
                      'coalesce((SELECT max(rowid) FROM $live), 0), '
                      'coalesce((SELECT max($_rid) FROM $x), 0)'
                      '${sequence.isEmpty ? '' : ', coalesce((SELECT seq FROM main.sqlite_sequence WHERE name = ?), 0)'}'
                      ') AS base',
                      variables: [
                        if (sequence.isNotEmpty) Variable.withString(t.name),
                      ],
                    )
                    .getSingle())
                .read<int>('base');
        expected = await database.customUpdate(
          'INSERT INTO $m SELECT x.$_rid, '
          'CASE WHEN l.rowid IS NULL THEN x.$_rid ELSE ? + row_number() '
          'OVER (PARTITION BY l.rowid IS NULL ORDER BY x.$_rid) END, '
          '${_Fate.added} '
          'FROM $x x LEFT JOIN $live l ON l.rowid = x.$_rid WHERE $rest',
          variables: [Variable.withInt(base)],
        );
        if (expected == 0) return;
        await beforeAdding();
        final written = await database.customUpdate(
          'INSERT OR IGNORE INTO $live '
          '(${_q(rowId)}, ${t.content.map(_q).join(', ')}) '
          'SELECT m.live, $values FROM $x x JOIN $m m ON m.bk = x.$_rid '
          'WHERE m.fate = ${_Fate.added} AND x.$_round = ?',
          variables: [Variable.withInt(round)],
        );
        if (written == expected) return;
        await database.customStatement(
          'UPDATE $m AS m SET live = NULL, fate = ${_Fate.conflict} '
          'WHERE fate = ${_Fate.added} '
          'AND bk IN (SELECT $_rid FROM $x WHERE $_round = ?) '
          'AND NOT EXISTS (SELECT 1 FROM $live l WHERE l.rowid = m.live)',
          [round],
        );
      } else {
        expected = await database.customUpdate(
          'INSERT INTO $m SELECT x.$_rid, x.$_rid, ${_Fate.added} '
          'FROM $x x WHERE $rest',
        );
        if (expected == 0) return;
        await beforeAdding();
        final written = await database.customUpdate(
          'INSERT OR IGNORE INTO $live (${t.content.map(_q).join(', ')}) '
          'SELECT $values FROM $x x JOIN $m m ON m.bk = x.$_rid '
          'WHERE m.fate = ${_Fate.added} AND x.$_round = ?',
          variables: [Variable.withInt(round)],
        );
        if (written == expected) return;
        final key = t.primaryKey.isEmpty ? t.content : t.primaryKey;
        await database.customStatement(
          'UPDATE $m SET live = NULL, fate = ${_Fate.conflict} '
          'WHERE fate = ${_Fate.added} AND bk IN ('
          'SELECT x.$_rid FROM $x x WHERE x.$_round = ? AND NOT EXISTS ('
          'SELECT 1 FROM $live l WHERE '
          '${key.map((c) => 'l.${_q(c)} IS x.${_q(c)}').join(' AND ')}))',
          [round],
        );
      }
    }

    if (self == null) {
      await settle(0);
      return;
    }
    // A table that links to itself goes a generation at a time: a row is
    // settled once the row it descends from is.
    final parent = 'x.${_q(self)}';
    for (var round = 1; ; round++) {
      final ready = await database.customUpdate(
        'UPDATE $x AS x SET $_round = ? WHERE $_round = -1 AND $_out = 0 '
        'AND ($parent IS NULL OR EXISTS '
        '(SELECT 1 FROM $m m WHERE m.bk = $parent))',
        variables: [Variable.withInt(round)],
      );
      if (ready == 0) break;
      await database.customStatement(
        'UPDATE $x AS x SET $_out = ${_Fate.ownerLeftOut} WHERE $_round = ? '
        'AND $parent IS NOT NULL '
        'AND (SELECT live FROM $m m WHERE m.bk = $parent) IS NULL',
        [round],
      );
      await database.customStatement(
        'INSERT INTO $m SELECT $_rid, NULL, $_out FROM $x '
        'WHERE $_round = ? AND $_out <> 0',
        [round],
      );
      await database.customStatement(
        'UPDATE $x AS x SET ${_q(self)} = '
        '(SELECT live FROM $m m WHERE m.bk = $parent) '
        'WHERE $_round = ? AND $_out = 0 AND $parent IS NOT NULL',
        [round],
      );
      await settle(round);
    }
    await database.customStatement(
      'INSERT INTO $m SELECT $_rid, NULL, ${_Fate.ownerNotInBackup} FROM $x '
      'WHERE $_round = -1 AND $_out = 0',
    );
  }
}
