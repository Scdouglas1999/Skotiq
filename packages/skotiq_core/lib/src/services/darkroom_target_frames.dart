import 'package:skotiq_astro/skotiq_astro.dart';

import '../database/database.dart';
import '../models/imaging/frame_type_record.dart';
import 'frame_header.dart';
import 'logging_service.dart';

/// A sub further than this from a target's catalog position is not of that
/// target: drawn as off target on the nights strip, and never attributed to
/// it by position. Guided tracking lets the reported pointing wander a few
/// arcminutes on a good night, so the limit sits well above that.
const double darkroomOffTargetArcmin = 15;

/// The group of lights that name no target, no object and no session.
const String darkroomNoTargetKey = 'Frames with no target';

/// Every captured light, grouped into the Darkroom's targets.
class DarkroomTargetFrames {
  const DarkroomTargetFrames(this.byTarget, {this.unidentified = const {}});

  /// The lights of each target, by the name the Darkroom lists it under.
  final Map<String, List<DbCapturedImage>> byTarget;

  /// The groups that are not a target: lights with no target, listed by their
  /// session or as [darkroomNoTargetKey].
  final Set<String> unidentified;

  List<DbCapturedImage>? operator [](String key) => byTarget[key];
}

/// The plate-solved center of [frame] in hours and degrees, when it has one.
({double raHours, double dec})? darkroomSolvedCenter(DbCapturedImage frame) {
  final ra = frame.solvedRa, dec = frame.solvedDec;
  if (!frame.isPlateSolved || ra == null || dec == null) return null;
  if (ra < 0 || ra >= 24 || dec.abs() > 90) return null;
  return (raHours: ra, dec: dec);
}

/// The saved targets whose catalog position lies within
/// [darkroomOffTargetArcmin] of [frame]'s plate-solved center, nearest first.
List<DbTarget> darkroomTargetsAt(
  DbCapturedImage frame,
  Iterable<DbTarget> targets,
) {
  final center = darkroomSolvedCenter(frame);
  if (center == null) return const [];
  return darkroomTargetsAtPosition(center.raHours, center.dec, targets);
}

/// The saved targets within [darkroomOffTargetArcmin] of ([raHours], [dec]),
/// nearest first.
List<DbTarget> darkroomTargetsAtPosition(
  double raHours,
  double dec,
  Iterable<DbTarget> targets,
) {
  final near = <(double, DbTarget)>[];
  for (final t in targets) {
    final arcmin =
        AstronomyCalculations.angularSeparation(
          ra1Deg: raHours * 15,
          dec1Deg: dec,
          ra2Deg: t.ra * 15,
          dec2Deg: t.dec,
        ) *
        60;
    if (arcmin <= darkroomOffTargetArcmin) near.add((arcmin, t));
  }
  near.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, t) in near) t];
}

/// Groups [lights] into targets, each light by the first rule that names one:
/// 1. its target;
/// 2. the one target the rest of its sequence run imaged;
/// 3. the FITS `OBJECT` in [objectNames];
/// 4. the saved target its plate solve lies on, when it lies on exactly one.
///    A light taken by hand joins a target this way only when no run imaged
///    that target, so framing snapshots never mix into a run's masters;
/// 5. its session, else [darkroomNoTargetKey].
///
/// Targets [identity] resolves to one catalog object are one group, listed
/// under the name whose first light is oldest.
DarkroomTargetFrames groupDarkroomTargets(
  Iterable<DbCapturedImage> lights,
  List<DbTarget> targets, {
  Map<int, String> objectNames = const {},
  CatalogIdentity<String>? identity,
}) {
  final rowById = {for (final t in targets) t.id: t};
  final runTargets = <String, Set<int>>{};
  final imagedByRun = <int>{};
  for (final f in lights) {
    final run = f.producingRunId, target = f.targetId;
    if (target == null || !rowById.containsKey(target)) continue;
    if (run != null && run.isNotEmpty) {
      runTargets.putIfAbsent(run, () => {}).add(target);
      imagedByRun.add(target);
    }
  }

  final byKey = <String, List<DbCapturedImage>>{};
  final unidentified = <String>{};
  for (final f in lights) {
    final run = f.producingRunId;
    final byRun = run == null ? null : runTargets[run];
    String? key = rowById[f.targetId]?.name;
    key ??= byRun != null && byRun.length == 1
        ? rowById[byRun.single]!.name
        : null;
    key ??= objectNames[f.id];
    if (key == null) {
      final on = darkroomTargetsAt(f, targets);
      final byHand = run == null || run.isEmpty;
      if (on.length == 1 && !(byHand && imagedByRun.contains(on.single.id))) {
        key = on.single.name;
      }
    }
    if (key == null) {
      key = f.sessionId == null
          ? darkroomNoTargetKey
          : 'Session ${f.sessionId}';
      unidentified.add(key);
    }
    byKey.putIfAbsent(key, () => []).add(f);
  }

  if (identity != null) _joinByCatalogIdentity(byKey, targets, identity);
  unidentified.removeWhere((key) => !byKey.containsKey(key));
  return DarkroomTargetFrames(byKey, unidentified: unidentified);
}

void _joinByCatalogIdentity(
  Map<String, List<DbCapturedImage>> byKey,
  List<DbTarget> targets,
  CatalogIdentity<String> identity,
) {
  final rowsByName = {for (final t in targets) t.name: t};
  final keysByObject = <String, List<String>>{};
  for (final key in byKey.keys) {
    final object = identity.objectOf([rowsByName[key]?.catalogId, key]);
    if (object != null) keysByObject.putIfAbsent(object, () => []).add(key);
  }
  for (final keys in keysByObject.values) {
    if (keys.length < 2) continue;
    DateTime first(String key) => byKey[key]!
        .map((f) => f.capturedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    keys.sort((a, b) {
      final byAge = first(a).compareTo(first(b));
      return byAge != 0 ? byAge : a.compareTo(b);
    });
    final kept = byKey[keys.first]!;
    for (final other in keys.skip(1)) {
      kept.addAll(byKey.remove(other)!);
    }
  }
}

/// The catalog identity of every OpenNGC object, built once per installed
/// file; null while the catalog is not installed.
Future<CatalogIdentity<String>?> darkroomCatalogIdentity() async {
  final manager = CatalogManager.instance;
  if (!manager.isInitialized) return null;
  if (!(await manager.status(SkyCatalog.dso)).isInstalled) return null;
  final reader = manager.dsos;
  return await (_identities[reader] ??= reader.load().then(
    CatalogIdentity.ofDsos,
  ));
}

final Expando<Future<CatalogIdentity<String>>> _identities = Expando();

/// Every captured light of the database, grouped by [groupDarkroomTargets].
Future<DarkroomTargetFrames> loadDarkroomTargets(
  SkotiqDatabase db, {
  FrameHeaderReader readHeader = readFrameHeader,
  CatalogIdentity<String>? identity,
}) async {
  final lights = [
    for (final f in await db.imagesDao.getAllImages())
      if (f.isLight) f,
  ];
  final targets = await db.targetsDao.getAllTargets();
  final rowIds = {for (final t in targets) t.id};
  final objectNames = <int, String>{};
  for (final f in lights) {
    if (rowIds.contains(f.targetId)) continue;
    try {
      final name = (await readHeader(f.filePath)).string('OBJECT')?.trim();
      if (name != null && name.isNotEmpty) objectNames[f.id] = name;
    } catch (e) {
      // An unreadable file is grouped by the other rules.
      Log.debug(
        'Darkroom: no OBJECT for ${f.filePath}: $e',
        source: 'darkroom',
      );
    }
  }
  CatalogIdentity<String>? catalog = identity;
  if (catalog == null) {
    try {
      catalog = await darkroomCatalogIdentity();
    } catch (e) {
      Log.warning(
        'Darkroom: the catalog could not be read, so targets that are one '
        'object under two names stay apart: $e',
        source: 'darkroom',
      );
    }
  }
  return groupDarkroomTargets(
    lights,
    targets,
    objectNames: objectNames,
    identity: catalog,
  );
}
