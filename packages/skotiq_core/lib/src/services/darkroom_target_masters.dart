/// Which integrated masters belong to which Darkroom target: the one rule the
/// Targets tab, the Edit tab's library and a night's Workbench all read.
library;

import 'dart:convert';

import 'package:skotiq_astro/skotiq_astro.dart' show DsoDesignations;

import '../database/daos/integrated_masters_dao.dart';
import '../database/database.dart';
import '../models/darkroom/master_naming.dart';
import '../models/darkroom/target_standing.dart'
    show normalizeDarkroomTargetName;
import '../models/imaging/integrated_master.dart';
import 'darkroom_target_frames.dart';

/// The target [master] belongs to.
///
/// The target row's name when the master carries one; otherwise the `target`
/// the guided build recorded in the master's settings; otherwise the master's
/// own name with its filter suffix taken off. The guided build keys its jobs by
/// the same name, so an image lands under the target the Targets tab lists.
String darkroomMasterTargetName(
  IntegratedMaster master,
  Map<int, String> targetNames,
) {
  final byId = master.targetId == null ? null : targetNames[master.targetId];
  if (byId != null && byId.trim().isNotEmpty) return byId.trim();
  try {
    final settings = jsonDecode(master.settingsJson);
    if (settings is Map && settings['target'] is String) {
      final name = (settings['target'] as String).trim();
      if (name.isNotEmpty) return name;
    }
  } on FormatException {
    // Settings that are not JSON name no target; the master's name does.
  }
  final name = targetInMasterName(master.name, master.filter);
  return name.isEmpty ? 'Unnamed target' : name;
}

/// Whether [master] belongs to the target listed as [key], whose lights carry
/// the target rows [rowIds]: the target row it records, the frames it folded,
/// else the target [darkroomMasterTargetName] reads, the same one the Edit
/// tab's library files it under.
bool darkroomMasterBelongsTo(
  IntegratedMaster master,
  String key, {
  Set<int> rowIds = const {},
  Set<int> frameIds = const {},
  Set<int> foldedIds = const {},
}) {
  if (master.targetId != null && rowIds.isNotEmpty) {
    return rowIds.contains(master.targetId);
  }
  if (frameIds.isNotEmpty && foldedIds.any(frameIds.contains)) return true;
  final wanted = normalizeDarkroomTargetName(key);
  return wanted.isNotEmpty &&
      normalizeDarkroomTargetName(darkroomMasterTargetName(master, const {})) ==
          wanted;
}

/// The target rows a group's lights record, with the row listed under its
/// name: more than one when the group joins one object saved under two names.
Set<int> darkroomTargetRowIds(List<DbCapturedImage> frames, DbTarget? row) => {
  if (row != null) row.id,
  for (final f in frames)
    if (f.targetId != null) f.targetId!,
};

/// The masters the Targets tab files under the targets [imageIds] belong to,
/// newest first. A night's Workbench lists these, so the two places agree on
/// which masters are a target's.
Future<List<IntegratedMaster>> darkroomMastersOfFrames(
  SkotiqDatabase db,
  IntegratedMastersDao mastersDao,
  DsoDesignations catalog,
  Set<int> imageIds,
) async {
  if (imageIds.isEmpty) return const [];
  final grouped = await loadDarkroomTargets(db, catalog);
  final rowsByName = {
    for (final t in await db.targetsDao.getAllTargets()) t.name: t,
  };
  final masters = await mastersDao.getAll();
  final folded = {
    for (final MapEntry(:key, :value)
        in (await mastersDao.getFramesByMaster()).entries)
      key: {for (final r in value) r.imageId},
  };
  final own = <IntegratedMaster>{};
  for (final MapEntry(key: key, value: frames) in grouped.byTarget.entries) {
    final frameIds = {for (final f in frames) f.id};
    if (!frameIds.any(imageIds.contains)) continue;
    for (final m in masters) {
      if (darkroomMasterBelongsTo(
        m,
        key,
        rowIds: darkroomTargetRowIds(frames, rowsByName[key]),
        frameIds: frameIds,
        foldedIds: folded[m.id] ?? const {},
      )) {
        own.add(m);
      }
    }
  }
  return own.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
