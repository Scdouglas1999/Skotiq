import 'package:drift/drift.dart';

import '../database/database.dart';
import '../database/daos/integrated_masters_dao.dart';
import '../models/imaging/integrated_master.dart';
import 'darkroom_target_frames.dart';
import 'file_trash.dart';
import 'target_standing.dart';

/// One target as the Darkroom lists it: its name, its saved target row when
/// it has one, its lights and its masters.
class DarkroomTargetGroup {
  const DarkroomTargetGroup({
    required this.key,
    required this.frames,
    this.row,
    this.masters = const [],
  });

  final String key;
  final DbTarget? row;
  final List<DbCapturedImage> frames;
  final List<IntegratedMaster> masters;

  /// The target rows its lights record, with its own row.
  Set<int> get rowIds => {
    if (row != null) row!.id,
    for (final f in frames)
      if (f.targetId != null) f.targetId!,
  };
}

/// What an edit changed, so that it can be put back.
class TargetEdit {
  const TargetEdit({
    required this.summary,
    this.frameTargets = const {},
    this.masterTargets = const {},
    this.createdRow,
    this.renamedRow,
    this.placementsBefore,
  });

  /// What was done, in a sentence for the undo bar.
  final String summary;

  /// The target each moved light recorded before.
  final Map<int, int?> frameTargets;

  /// The target each moved master recorded before.
  final Map<int, int?> masterTargets;

  /// A target row the edit created.
  final int? createdRow;

  /// A renamed target row and its name before.
  final ({int id, String name})? renamedRow;
  final TargetPlacements? placementsBefore;
}

/// Everything "Delete target and its files" removes, for the confirmation to
/// list before anything is touched.
class TargetDeletion {
  const TargetDeletion({
    required this.group,
    required this.lightFiles,
    required this.masterFiles,
    required this.targetRows,
    required this.restorable,
  });

  final DarkroomTargetGroup group;
  final List<String> lightFiles;
  final List<String> masterFiles;

  /// The saved targets removed from the target list.
  final List<DbTarget> targetRows;

  /// Whether the files go to the platform's trash.
  final bool restorable;

  List<String> get files => [...lightFiles, ...masterFiles];
}

/// The user's corrections to the Darkroom's targets. Each is a separate,
/// deliberate action; nothing here runs on its own.
class DarkroomTargetEdits {
  DarkroomTargetEdits(this._db, {required Future<FileTrash> Function() trash})
    : _trash = trash;

  final SkotiqDatabase _db;

  /// The trash, found only when a deletion needs it.
  final Future<FileTrash> Function() _trash;

  IntegratedMastersDao get _masters => IntegratedMastersDao(_db);

  /// Lists [key] as [placement] says: a project, hidden, or by the rule.
  Future<TargetEdit> place(String key, TargetPlacement placement) async {
    final before = await TargetPlacements.load(_db.settingsDao);
    await before.withPlacement(key, placement).save(_db.settingsDao);
    return TargetEdit(
      summary: switch (placement) {
        TargetPlacement.hidden => 'Moved $key to Other captures.',
        TargetPlacement.project => 'Listed $key as a project.',
        TargetPlacement.auto => 'Listed $key by the project rule.',
      },
      placementsBefore: before,
    );
  }

  /// Names [group] [name]. A saved target is renamed; a group with no saved
  /// target becomes a new one its lights record.
  Future<TargetEdit> rename(DarkroomTargetGroup group, String name) async {
    final to = name.trim();
    if (to.isEmpty) throw ArgumentError('A target needs a name.');
    final taken = await _rowNamed(to);
    if (taken != null && taken.id != group.row?.id) {
      throw StateError(
        'A target named "${taken.name}" already exists. Merge into it '
        'instead.',
      );
    }
    final placements = await TargetPlacements.load(_db.settingsDao);
    await placements.renamed(group.key, to).save(_db.settingsDao);
    final row = group.row;
    if (row != null) {
      await _db.targetsDao.updateTarget(
        row.copyWith(name: to, updatedAt: DateTime.now()),
      );
      return TargetEdit(
        summary: 'Renamed ${group.key} to $to.',
        renamedRow: (id: row.id, name: row.name),
        placementsBefore: placements,
      );
    }
    final created = await _createRowFor(to, group.frames);
    return TargetEdit(
      summary: 'Named these lights $to.',
      frameTargets: await _moveFrames(group.frames, created),
      createdRow: created,
      placementsBefore: placements,
    );
  }

  /// Files every light and master of [from] under [into]: the two are one
  /// object under two names. [from]'s saved target stays in the target list.
  Future<TargetEdit> merge(
    DarkroomTargetGroup from,
    DarkroomTargetGroup into,
  ) async {
    if (from.key == into.key) {
      throw ArgumentError('A target cannot be merged into itself.');
    }
    final existing = into.row;
    final target = existing?.id ?? await _createRowFor(into.key, into.frames);
    final frameTargets = await _moveFrames([
      ...from.frames,
      if (existing == null) ...into.frames,
    ], target);
    final masterTargets = <int, int?>{};
    for (final m in from.masters) {
      if (m.targetId == target) continue;
      masterTargets[m.id] = m.targetId;
      await _masters.setTarget(m.id, target);
    }
    return TargetEdit(
      summary: 'Merged ${from.key} into ${into.key}.',
      frameTargets: frameTargets,
      masterTargets: masterTargets,
      createdRow: existing == null ? target : null,
    );
  }

  /// Files [frames] under the saved target [into].
  Future<TargetEdit> assign(List<DbCapturedImage> frames, DbTarget into) async {
    final count = frames.length;
    return TargetEdit(
      summary:
          'Filed $count light${count == 1 ? '' : 's'} under '
          '${into.name}.',
      frameTargets: await _moveFrames(frames, into.id),
    );
  }

  /// Puts back what [edit] changed.
  Future<void> undo(TargetEdit edit) async {
    await _db.transaction(() async {
      for (final MapEntry(key: id, value: target)
          in edit.frameTargets.entries) {
        await (_db.update(_db.capturedImages)..where((i) => i.id.equals(id)))
            .write(CapturedImagesCompanion(targetId: Value(target)));
      }
      for (final MapEntry(key: id, value: target)
          in edit.masterTargets.entries) {
        await _masters.setTarget(id, target);
      }
      final renamed = edit.renamedRow;
      if (renamed != null) {
        final row = await _db.targetsDao.getTargetById(renamed.id);
        if (row != null) {
          await _db.targetsDao.updateTarget(row.copyWith(name: renamed.name));
        }
      }
      final created = edit.createdRow;
      if (created != null) await _db.targetsDao.deleteTarget(created);
      await edit.placementsBefore?.save(_db.settingsDao);
    });
  }

  /// What deleting [group] would remove. Nothing is touched.
  Future<TargetDeletion> planDeletion(DarkroomTargetGroup group) async {
    final rows = <DbTarget>[];
    for (final id in group.rowIds) {
      final row = await _db.targetsDao.getTargetById(id);
      if (row != null) rows.add(row);
    }
    return TargetDeletion(
      group: group,
      lightFiles: [
        for (final f in group.frames) ...[
          f.filePath,
          if (f.thumbnailPath?.isNotEmpty == true) f.thumbnailPath!,
        ],
      ],
      masterFiles: [
        for (final m in group.masters)
          for (final path in [
            m.masterFitsPath,
            m.previewPngPath,
            m.sidecarPath,
            m.rejectionMapPath,
            m.rejectionMapPreviewPath,
            m.coverageMapPath,
            m.coverageMapPreviewPath,
          ])
            if (path != null && path.isNotEmpty) path,
      ],
      targetRows: rows,
      restorable: (await _trash()).restorable,
    );
  }

  /// Removes what [deletion] lists: the files (into the trash where the
  /// platform has one), then the lights, masters and saved targets from the
  /// database. Returns the files that could not be removed; their rows stay.
  Future<List<String>> delete(TargetDeletion deletion) async {
    final failed = (await (await _trash()).remove(deletion.files)).toSet();
    await _db.transaction(() async {
      for (final f in deletion.group.frames) {
        if (failed.contains(f.filePath)) continue;
        await _db.imagesDao.deleteImage(f.id);
      }
      for (final m in deletion.group.masters) {
        if (failed.contains(m.masterFitsPath)) continue;
        await _masters.deleteMaster(m.id);
      }
      if (failed.isEmpty) {
        for (final row in deletion.targetRows) {
          await _db.targetsDao.deleteTarget(row.id);
        }
      }
      final placements = await TargetPlacements.load(_db.settingsDao);
      await placements
          .withPlacement(deletion.group.key, TargetPlacement.auto)
          .save(_db.settingsDao);
    });
    return failed.toList();
  }

  Future<DbTarget?> _rowNamed(String name) async {
    final wanted = normalizeDarkroomTargetName(name);
    for (final row in await _db.targetsDao.getAllTargets()) {
      if (normalizeDarkroomTargetName(row.name) == wanted) return row;
    }
    return null;
  }

  /// A saved target named [name] at the median plate-solved center of
  /// [frames], else their median pointing.
  Future<int> _createRowFor(String name, List<DbCapturedImage> frames) async {
    double median(List<double> values) {
      if (values.isEmpty) return 0;
      values.sort();
      return values[values.length ~/ 2];
    }

    final solved = [
      for (final f in frames)
        if (darkroomSolvedCenter(f) case final c?) c,
    ];
    final pointed = [
      for (final f in frames)
        if (f.mountRa != null && f.mountDec != null)
          (raHours: f.mountRa!, dec: f.mountDec!),
    ];
    final at = solved.isNotEmpty ? solved : pointed;
    return _db.targetsDao.createTarget(
      TargetsCompanion.insert(
        name: name,
        ra: median([for (final c in at) c.raHours]),
        dec: median([for (final c in at) c.dec]),
      ),
    );
  }

  /// Sets the target of [frames] to [target]; returns each one's target
  /// before.
  Future<Map<int, int?>> _moveFrames(
    List<DbCapturedImage> frames,
    int target,
  ) async {
    final before = {
      for (final f in frames)
        if (f.targetId != target) f.id: f.targetId,
    };
    if (before.isEmpty) return before;
    await (_db.update(_db.capturedImages)..where((i) => i.id.isIn(before.keys)))
        .write(CapturedImagesCompanion(targetId: Value(target)));
    return before;
  }
}
