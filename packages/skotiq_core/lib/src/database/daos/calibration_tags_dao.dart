import 'dart:convert';

import 'package:drift/drift.dart';

import '../../models/calibration/calibration_library_models.dart';
import '../database.dart';
import '../epoch_seconds.dart';

part 'calibration_tags_dao.g.dart';

/// One row of the v46 `calibration_tags` table: user tags / notes plus the
/// FITS-enriched camera-id cache for a `(master_type, master_id)` artifact.
class CalibrationTagEntry {
  final int id;
  final CalibrationMasterType masterType;
  final int masterId;
  final List<String> tags;
  final String? notes;
  final String? cameraId;
  final DateTime updatedAt;

  /// Shared-library provenance: who shared this master, when, under what
  /// license, and the serialized `Provenance` blob. Null for a master the user
  /// captured locally (only set when a master was pulled from a hub).
  final String? sharedBy;
  final DateTime? sharedAt;
  final String? license;
  final String? provenanceJson;

  /// Retract handle: the hub master id this LOCAL master was published
  /// under. Non-null marks a master the user has shared to the hub (and so can
  /// un-share / retract); cleared back to null on retract.
  final String? publishedRemoteId;

  const CalibrationTagEntry({
    required this.id,
    required this.masterType,
    required this.masterId,
    required this.tags,
    required this.notes,
    required this.cameraId,
    required this.updatedAt,
    this.sharedBy,
    this.sharedAt,
    this.license,
    this.provenanceJson,
    this.publishedRemoteId,
  });
}

/// Reads and writes for `calibration_tags`.
///
/// Identity is `UNIQUE(master_type, master_id)` where `master_id` is the row
/// id in the artifact's source table (`dark_library` / `flat_library` /
/// `defect_maps`). Upserts merge: a null argument leaves the stored value
/// untouched, so setting tags never clobbers the camera-id cache and vice
/// versa.
@DriftAccessor(include: {'../schema/post_session.drift'})
class CalibrationTagsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$CalibrationTagsDaoMixin {
  CalibrationTagsDao(super.db);

  /// Merge-upsert the row for `(type, masterId)`. Null fields keep the
  /// previously stored value; to clear notes pass `clearNotes: true`. The
  /// sharing columns ([sharedBy] / [sharedAt] / [license] / [provenanceJson])
  /// are stamped when a master is merged in from a hub.
  Future<void> upsert(
    CalibrationMasterType type,
    int masterId, {
    List<String>? tags,
    String? notes,
    bool clearNotes = false,
    String? cameraId,
    String? sharedBy,
    DateTime? sharedAt,
    String? license,
    String? provenanceJson,
    String? publishedRemoteId,
    bool clearPublishedRemoteId = false,
  }) async {
    final existing = await getForMaster(type, masterId);
    final mergedSharedAt = sharedAt ?? existing?.sharedAt;
    final merged = CalibrationTagsCompanion(
      tagsJson: Value(jsonEncode(tags ?? existing?.tags ?? const <String>[])),
      notes: Value(clearNotes ? null : (notes ?? existing?.notes)),
      cameraId: Value(cameraId ?? existing?.cameraId),
      updatedAt: Value(toEpochSeconds(DateTime.now())),
      sharedBy: Value(sharedBy ?? existing?.sharedBy),
      sharedAt: Value(
        mergedSharedAt == null ? null : toEpochSeconds(mergedSharedAt),
      ),
      license: Value(license ?? existing?.license),
      provenanceJson: Value(provenanceJson ?? existing?.provenanceJson),
      publishedRemoteId: Value(
        clearPublishedRemoteId
            ? null
            : (publishedRemoteId ?? existing?.publishedRemoteId),
      ),
    );

    if (existing == null) {
      await into(calibrationTags).insert(
        merged.copyWith(
          masterType: Value(calibrationMasterTypeWireName(type)),
          masterId: Value(masterId),
        ),
      );
      return;
    }
    await (update(
      calibrationTags,
    )..where((t) => _isMaster(t, type, masterId))).write(merged);
  }

  /// The row for one artifact, or null when never tagged/enriched.
  Future<CalibrationTagEntry?> getForMaster(
    CalibrationMasterType type,
    int masterId,
  ) async {
    final row =
        await (select(calibrationTags)
              ..where((t) => _isMaster(t, type, masterId))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Every row, keyed `'<wireType>:<masterId>'` for O(1) joining onto a
  /// listed library page.
  Future<Map<String, CalibrationTagEntry>> getAllKeyed() async {
    final rows = await select(calibrationTags).get();
    final out = <String, CalibrationTagEntry>{};
    for (final row in rows) {
      final entry = _mapRow(row);
      if (entry == null) continue;
      out['${calibrationMasterTypeWireName(entry.masterType)}:'
              '${entry.masterId}'] =
          entry;
    }
    return out;
  }

  /// Remove the annotation row when its artifact is deleted.
  Future<int> deleteForMaster(CalibrationMasterType type, int masterId) {
    return (delete(
      calibrationTags,
    )..where((t) => _isMaster(t, type, masterId))).go();
  }

  static Expression<bool> _isMaster(
    CalibrationTags t,
    CalibrationMasterType type,
    int masterId,
  ) =>
      t.masterType.equals(calibrationMasterTypeWireName(type)) &
      t.masterId.equals(masterId);

  CalibrationTagEntry? _mapRow(CalibrationTagRow row) {
    final type = calibrationMasterTypeFromWire(row.masterType);
    if (type == null) return null; // Unknown future type — skip, don't throw.
    final sharedAtSecs = row.sharedAt;
    return CalibrationTagEntry(
      id: row.id,
      masterType: type,
      masterId: row.masterId,
      tags: _decodeTags(row.tagsJson),
      notes: row.notes,
      cameraId: row.cameraId,
      updatedAt: fromEpochSeconds(row.updatedAt),
      sharedBy: row.sharedBy,
      sharedAt: sharedAtSecs == null ? null : fromEpochSeconds(sharedAtSecs),
      license: row.license,
      provenanceJson: row.provenanceJson,
      publishedRemoteId: row.publishedRemoteId,
    );
  }

  static List<String> _decodeTags(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } on FormatException {
      // Corrupt tags JSON degrades to "no tags" — the artifact row itself is
      // authoritative and must stay listable.
    }
    return const [];
  }
}
