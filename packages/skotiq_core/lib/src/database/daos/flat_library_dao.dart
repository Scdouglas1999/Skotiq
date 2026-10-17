import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/imaging/integrated_master.dart';
import '../../providers/database_provider.dart';
import '../database.dart';

/// Data-access object for the v41 `flat_library` table — the master-flat
/// artifact library, the missing counterpart to `dark_library`.
///
/// Like [StackedResultsDao] / [IntegratedMastersDao], the table is managed with
/// raw DDL (see [SkotiqDatabase._createPostSessionTables]) and this DAO is a
/// plain class reading/writing via `customSelect`/`customStatement`. Its match
/// API ([findBestMatch]) deliberately mirrors `DarkLibraryDao.findBestMatch`:
/// exact gain/offset/binning + filter, temperature within tolerance, preferring
/// the closest temperature then the newest.
class FlatLibraryDao {
  FlatLibraryDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, file_path, filter, equipment_profile_id, '
      'optical_train_id, temperature, gain, offset, bin_x, bin_y, width, '
      'height, flat_kind, master_frame_count, created_at';

  /// Insert (or replace on duplicate file path) a master-flat entry; returns id.
  Future<int> addEntry({
    required String filePath,
    String? filter,
    int? equipmentProfileId,
    String? opticalTrainId,
    double? temperature,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    int? width,
    int? height,
    String flatKind = 'sky',
    int masterFrameCount = 0,
    DateTime? createdAt,
  }) async {
    // Dedup by file path (a master flat is rebuilt to the same path on rerun).
    final existing = await _db
        .customSelect(
          'SELECT id FROM flat_library WHERE file_path = ? LIMIT 1',
          variables: [Variable<String>(filePath)],
        )
        .get();
    final createdSecs = _toEpochSeconds((createdAt ?? DateTime.now()).toUtc());

    if (existing.isNotEmpty) {
      final id = existing.first.read<int>('id');
      await _db.customUpdate(
        'UPDATE flat_library SET filter = ?, equipment_profile_id = ?, '
        'optical_train_id = ?, temperature = ?, gain = ?, offset = ?, '
        'bin_x = ?, bin_y = ?, width = ?, height = ?, flat_kind = ?, '
        'master_frame_count = ?, created_at = ? WHERE id = ?',
        variables: [
          Variable<String>(filter),
          Variable<int>(equipmentProfileId),
          Variable<String>(opticalTrainId),
          Variable<double>(temperature),
          Variable<int>(gain),
          Variable<int>(offset),
          Variable<int>(binX),
          Variable<int>(binY),
          Variable<int>(width),
          Variable<int>(height),
          Variable<String>(flatKind),
          Variable<int>(masterFrameCount),
          Variable<int>(createdSecs),
          Variable<int>(id),
        ],
        updateKind: UpdateKind.update,
      );
      return id;
    }

    return _db.customInsert(
      'INSERT INTO flat_library('
      'file_path, filter, equipment_profile_id, optical_train_id, temperature, '
      'gain, offset, bin_x, bin_y, width, height, flat_kind, '
      'master_frame_count, created_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(filePath),
        Variable<String>(filter),
        Variable<int>(equipmentProfileId),
        Variable<String>(opticalTrainId),
        Variable<double>(temperature),
        Variable<int>(gain),
        Variable<int>(offset),
        Variable<int>(binX),
        Variable<int>(binY),
        Variable<int>(width),
        Variable<int>(height),
        Variable<String>(flatKind),
        Variable<int>(masterFrameCount),
        Variable<int>(createdSecs),
      ],
    );
  }

  /// All entries, newest first.
  Future<List<FlatLibraryEntry>> getAllEntries() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM flat_library ORDER BY created_at DESC, id DESC',
        )
        .get();
    return rows.map(_mapRow).toList();
  }

  /// Fetch one entry by id, or null.
  Future<FlatLibraryEntry?> getEntryById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM flat_library WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _mapRow(rows.first);
  }

  /// Find the best master flat for a light frame's parameters.
  ///
  /// Matching rules (mirrors [DarkLibraryDao.findBestMatch]):
  /// - `filter` must match exactly (a flat is filter-specific) when provided.
  /// - `gain`, `offset`, and binning must match exactly.
  /// - Optical-train tag must match exactly when both sides provide one.
  /// - Temperature must be within [temperatureToleranceC] when both are known.
  /// - Among matches, the closest-temperature entry wins; ties break newest.
  ///
  /// Returns null when nothing qualifies.
  Future<FlatLibraryEntry?> findBestMatch({
    String? filter,
    int gain = 0,
    int offset = 0,
    int binX = 1,
    int binY = 1,
    String? opticalTrainId,
    double? temperature,
    double temperatureToleranceC = 5.0,
  }) async {
    final clauses = <String>[
      'gain = ?',
      'offset = ?',
      'bin_x = ?',
      'bin_y = ?',
    ];
    final vars = <Variable<Object>>[
      Variable<int>(gain),
      Variable<int>(offset),
      Variable<int>(binX),
      Variable<int>(binY),
    ];
    if (filter != null && filter.trim().isNotEmpty) {
      clauses.add('filter = ?');
      vars.add(Variable<String>(filter.trim()));
    }
    if (opticalTrainId != null && opticalTrainId.trim().isNotEmpty) {
      // Accept rows with a matching tag OR no tag at all (a generic flat).
      clauses.add('(optical_train_id = ? OR optical_train_id IS NULL)');
      vars.add(Variable<String>(opticalTrainId.trim()));
    }

    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM flat_library WHERE ${clauses.join(' AND ')}',
          variables: vars,
        )
        .get();
    if (rows.isEmpty) return null;

    var candidates = rows.map(_mapRow).toList();

    // Temperature gate (only when both sides know the temperature).
    if (temperature != null) {
      candidates = candidates.where((c) {
        if (c.temperature == null) return true; // accept temp-less flats
        return (c.temperature! - temperature).abs() <= temperatureToleranceC;
      }).toList();
    }
    if (candidates.isEmpty) return null;

    if (temperature == null) {
      candidates.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return candidates.first;
    }
    candidates.sort((a, b) {
      final aD = a.temperature != null
          ? (a.temperature! - temperature).abs()
          : double.maxFinite;
      final bD = b.temperature != null
          ? (b.temperature! - temperature).abs()
          : double.maxFinite;
      final byTemp = aD.compareTo(bD);
      if (byTemp != 0) return byTemp;
      return b.createdAt.compareTo(a.createdAt);
    });
    return candidates.first;
  }

  /// Delete one entry by id.
  Future<int> deleteEntry(int id) {
    return _db.customUpdate(
      'DELETE FROM flat_library WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  FlatLibraryEntry _mapRow(QueryRow row) {
    return FlatLibraryEntry(
      id: row.read<int>('id'),
      filePath: row.read<String>('file_path'),
      filter: row.readNullable<String>('filter'),
      equipmentProfileId: row.readNullable<int>('equipment_profile_id'),
      opticalTrainId: row.readNullable<String>('optical_train_id'),
      temperature: row.readNullable<double>('temperature'),
      gain: row.read<int>('gain'),
      offset: row.read<int>('offset'),
      binX: row.read<int>('bin_x'),
      binY: row.read<int>('bin_y'),
      width: row.readNullable<int>('width'),
      height: row.readNullable<int>('height'),
      flatKind: row.read<String>('flat_kind'),
      masterFrameCount: row.read<int>('master_frame_count'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [FlatLibraryDao].
final flatLibraryDaoProvider = Provider<FlatLibraryDao>((ref) {
  return FlatLibraryDao(ref.watch(databaseProvider));
});
