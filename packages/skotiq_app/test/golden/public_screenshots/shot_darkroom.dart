// The Darkroom's registered masters: a master per filter of each target's
// plan, built this morning from every night before tonight. The frames each master
// folded are the seeded frames, so the counts agree with History and Plan.
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

import '../surface_golden_harness.dart';
import 'shot_night.dart';

/// The preview of each master, by target name and filter: the app's
/// auto-stretch of one of the owner's subs through that filter (see
/// `test/fixtures/README.md`). A target or filter with no sub on record has
/// no preview.
Map<String, Map<String, String>> masterPreviews() {
  final dir = '${SurfaceGoldenHarness.repoRoot().path}'
      '/packages/skotiq_app/test/fixtures/darkroom';
  final out = <String, Map<String, String>>{};
  final pattern = RegExp(r'^(.+)_([LRGB])\.(png|jpg)$');
  for (final f in Directory(dir).listSync().whereType<File>()) {
    final m = pattern.firstMatch(f.uri.pathSegments.last);
    if (m == null) continue;
    (out[m.group(1)!] ??= {})[m.group(2)!] = f.path;
  }
  return out;
}

/// Where the master of [target] through [filter] is saved.
String masterPath(ShotTarget target, String filter) =>
    'D:\\Astro\\Skotiq\\Masters\\${target.folder}_$filter.xisf';

/// Every master file [seedDarkroom] registers.
List<String> masterPaths() => [
      for (final target in ShotNight.targets)
        for (final filter in target.plan.frames.keys)
          masterPath(target, filter),
    ];

/// Masters for every target of tonight's run, from the nights before tonight.
Future<void> seedDarkroom(SkotiqDatabase db) async {
  final dao = IntegratedMastersDao(db);
  final previews = masterPreviews();
  final builtAt = ShotNight.at(-1, 7, 40);
  for (final target in ShotNight.targets) {
    for (final filter in target.plan.frames.keys) {
      final frames = [
        for (final night in ShotNight.pastNights)
          for (final f in night.frames)
            if (f.target.id == target.id && f.filter == filter) f,
      ];
      if (frames.isEmpty) continue;
      final seconds = frames.fold(0.0, (s, f) => s + f.exposureSecs);
      final id = await dao.insertMaster(
        targetId: target.id,
        name: '${target.name} $filter',
        masterFitsPath: masterPath(target, filter),
        previewPngPath: previews[target.folder]?[filter],
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        width: ShotNight.sensorWidth,
        height: ShotNight.sensorHeight,
        frameCount: frames.length,
        totalIntegrationSeconds: seconds,
        filter: filter,
        statsJson: jsonEncode({
          'framesIntegrated': frames.length,
          'framesRejected': 0,
        }),
        createdAt: builtAt.toUtc(),
        updatedAt: builtAt.toUtc(),
      );
      for (final f in frames) {
        await dao.recordFoldedFrame(
          masterId: id,
          imageId: ShotNight.frameId(f),
          foldedAt: builtAt,
          fwhm: f.fwhmArcsec,
          eccentricity: f.eccentricity,
        );
      }
    }
  }
}
