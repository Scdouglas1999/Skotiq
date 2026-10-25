import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../darkroom_previews.dart';
import 'darkroom_targets_model.dart';

/// Every imaged target with its nights and masters, most recently imaged
/// first. Re-read when a master build finishes.
final darkroomTargetsProvider =
    FutureProvider.autoDispose<List<DarkroomTarget>>((ref) async {
  ref.listen(darkroomBuildJobsProvider, (previous, next) {
    if (next?.stage == DarkroomJobStage.done &&
        previous?.stage != DarkroomJobStage.done) {
      ref.invalidateSelf();
    }
  });
  ref.watch(darkroomDraftPreviewRevisionProvider);
  final db = ref.watch(databaseProvider);
  final mastersDao = ref.watch(integratedMastersDaoProvider);
  final framesByTarget = await loadDarkroomTargets(db);
  final masters = await mastersDao.getAll();
  final rows = await db.targetsDao.getAllTargets();
  final folded = <int, Set<int>>{};
  final used = <int, Set<int>>{};
  final drafts = <int, String>{};
  final recipes = RecipesDao(db);
  for (final m in masters) {
    final path = m.masterFitsPath;
    if (path != null) {
      final draft = darkroomRecipeDraftPreview(
        await recipes.listForMaster(path),
      );
      if (draft != null) drafts[m.id] = draft;
    }
    final records = await mastersDao.getFramesForMaster(m.id);
    folded[m.id] = {for (final r in records) r.imageId};
    used[m.id] = {
      for (final r in records)
        if (r.accepted) r.imageId,
    };
  }
  return buildDarkroomTargets(
    framesByTarget: framesByTarget,
    masters: masters,
    targetRows: rows,
    foldedByMaster: folded,
    usedByMaster: used,
    draftPreviews: drafts,
  );
});

/// The calibration masters the library offers one filter of a target.
class DarkroomFilterCalibration {
  const DarkroomFilterCalibration({
    required this.filter,
    required this.exposureSeconds,
    required this.match,
    this.missing = const {},
  });

  final String filter;

  /// Matched masters whose file is not on this computer: `dark`, `bias` or
  /// `flat`.
  final Set<String> missing;

  /// The exposure most of the filter's kept subs were taken at.
  final double exposureSeconds;
  final CalibrationMatchSet match;
}

/// Per-filter dark, bias and flat matches for the target named [key], from
/// the local library and the settings most of each filter's subs share.
final darkroomTargetCalibrationProvider = FutureProvider.autoDispose
    .family<List<DarkroomFilterCalibration>, String>((ref, key) async {
  // A master built or removed in the Calibration tab changes the matches.
  ref.watch(calibrationLibraryRevisionProvider);
  final targets = await ref.watch(darkroomTargetsProvider.future);
  final target = targets.where((t) => t.key == key).firstOrNull;
  if (target == null) return const [];
  final library = ref.watch(calibrationLibraryServiceProvider);
  final result = <DarkroomFilterCalibration>[];
  for (final channel in target.channels) {
    final subs = [
      for (final f in target.frames)
        if (f.isAccepted && darkroomFilterOf(f) == channel.filter) f,
    ];
    if (subs.isEmpty) continue;
    final f = _typical(subs);
    final temps = [
      for (final s in subs)
        if (s.sensorTemp != null) s.sensorTemp!,
    ]..sort();
    final match = await library.match(
      LightFrameContext(
        gain: f.gain,
        offset: f.offset,
        exposureSeconds: f.exposureDuration,
        temperature: temps.isEmpty ? null : temps[temps.length ~/ 2],
        filter: f.filter,
        binX: f.binX,
        binY: f.binY,
      ),
      includeRemote: false,
    );
    result.add(
      DarkroomFilterCalibration(
        filter: channel.filter,
        exposureSeconds: f.exposureDuration,
        match: match,
        missing: {
          for (final (kind, m) in [
            ('dark', match.dark),
            ('bias', match.bias),
            ('flat', match.flat),
          ])
            if (m != null && !await _present(m.record.filePath)) kind,
        },
      ),
    );
  }
  return result;
});

Future<bool> _present(String? path) async =>
    path != null && path.isNotEmpty && await File(path).exists();

/// The sub whose exposure, gain, offset and binning most subs share.
DbCapturedImage _typical(List<DbCapturedImage> subs) {
  final counts = <String, List<DbCapturedImage>>{};
  for (final s in subs) {
    counts
        .putIfAbsent(
          '${s.exposureDuration}/${s.gain}/${s.offset}/${s.binX}x${s.binY}',
          () => [],
        )
        .add(s);
  }
  return (counts.values.toList()..sort((a, b) => b.length.compareTo(a.length)))
      .first
      .first;
}

/// Calibration the operator chose on the Targets tab, per target: for each
/// filter, the flat to use in place of the library's match.
final darkroomFlatChoicesProvider =
    StateProvider.family<Map<String, String>, String>((ref, key) => const {});
