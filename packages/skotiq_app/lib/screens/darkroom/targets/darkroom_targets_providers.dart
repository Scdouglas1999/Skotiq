import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show DsoDesignations;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../darkroom_previews.dart';
import 'darkroom_targets_model.dart';

/// How the Darkroom reads a frame file's header, for the `OBJECT` of lights
/// that name no target.
final darkroomFrameHeaderReaderProvider = Provider<FrameHeaderReader>(
  (ref) => readFrameHeader,
);

/// The user's project rule settings.
final darkroomProjectRuleProvider = FutureProvider.autoDispose<ProjectRule>(
  (ref) => ref.watch(settingsDaoProvider).readProjectRule(),
);

/// The user's corrections to where targets are listed.
final darkroomTargetPlacementsProvider =
    FutureProvider.autoDispose<TargetPlacements>(
  (ref) => ref.watch(settingsDaoProvider).readTargetPlacements(),
);

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
  final rule = await ref.watch(darkroomProjectRuleProvider.future);
  final placements = await ref.watch(darkroomTargetPlacementsProvider.future);
  final grouped = await loadDarkroomTargets(
    db,
    await installedDsoDesignations(ref.read(loggingServiceProvider)),
    readHeader: ref.watch(darkroomFrameHeaderReaderProvider),
  );
  final masters = await mastersDao.getAll();
  final rows = await withCatalogObjectTypes(
    await db.targetsDao.getAllTargets(),
    ref.read(loggingServiceProvider),
  );
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
    framesByTarget: grouped.byTarget,
    unidentified: grouped.unidentified,
    masters: masters,
    targetRows: rows,
    foldedByMaster: folded,
    usedByMaster: used,
    draftPreviews: drafts,
    rule: rule,
    placements: placements,
  );
});

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
  final folded = <int, Set<int>>{
    for (final m in masters)
      m.id: {
        for (final r in await mastersDao.getFramesForMaster(m.id)) r.imageId,
      },
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
  final library = ref.watch(calibrationLibraryProvider);
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
        gain: f.comparableGain,
        gainIsUnknownIso: f.hasUnknownIso,
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
