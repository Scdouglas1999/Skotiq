// Catalog hot-path timings against a directory of installed catalogs
// (hyg_v44.csv, NGC.csv and their metadata; add glade_plus_galaxies.csv and
// pass `glade` for the annotation cone).
//
//   dart compile exe tool/bench_catalogs.dart -o /tmp/bench && /tmp/bench <dir> [glade]
//
// Use a copy of the catalog directory: initialize() sweeps abandoned partials.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:io';

import 'package:skotiq_astro/skotiq_astro.dart';

/// Longest gap between 4 ms timer ticks while [body] runs: how long the
/// calling isolate (the UI isolate in the app) could not run anything else.
Future<(T, int stallMs, int wallMs)> stalled<T>(
  Future<T> Function() body,
) async {
  var last = DateTime.now().microsecondsSinceEpoch;
  var worst = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final now = DateTime.now().microsecondsSinceEpoch;
    if (now - last > worst) worst = now - last;
    last = now;
  });
  final sw = Stopwatch()..start();
  final value = await body();
  sw.stop();
  final now = DateTime.now().microsecondsSinceEpoch;
  if (now - last > worst) worst = now - last;
  timer.cancel();
  return (value, worst ~/ 1000, sw.elapsedMilliseconds);
}

Future<int> medianUs(Future<void> Function() body, {int n = 15}) async {
  final t = <int>[];
  for (var i = 0; i < n; i++) {
    final sw = Stopwatch()..start();
    await body();
    t.add(sw.elapsedMicroseconds);
  }
  t.sort();
  return t[n ~/ 2];
}

Future<void> main(List<String> args) async {
  final dir = args[0];
  final withGlade = args.length > 1 && args[1] == 'glade';
  final m = CatalogManager.instance;

  final (_, initStall, initWall) = await stalled(() async {
    await m.initialize(dir);
    await Future.wait([m.stars.load(), m.dsos.load()]);
  });
  print(
    'initialize + both catalogs parsed: wall $initWall ms, isolate stall $initStall ms',
  );

  for (final q in [
    'M31',
    'andromeda',
    'NGC 7000',
    'vega',
    'hip 91262',
    'orion',
  ]) {
    late int count;
    final us = await medianUs(() async => count = (await m.search(q)).length);
    final (_, stall, _) = await stalled(() => m.search(q));
    print(
      'search "$q": median ${(us / 1000).toStringAsFixed(1)} ms, stall $stall ms, $count results',
    );
  }

  // Annotation after a plate solve: cone searches around the solved center.
  for (final f in [
    (10.68, 41.27, 1.5, 'M31 1.5deg'),
    (266.4, -29.0, 2.0, 'Sgr 2deg'),
  ]) {
    late int nd, ns;
    final usD = await medianUs(
      () async => nd = (await m.searchDsoNearby(
        ra: f.$1,
        dec: f.$2,
        radiusDegrees: f.$3,
      )).length,
    );
    final usS = await medianUs(
      () async => ns = (await m.searchStarsNearby(
        ra: f.$1,
        dec: f.$2,
        radiusDegrees: f.$3,
        maxMagnitude: 12,
      )).length,
    );
    print(
      'annotation cone ${f.$4}: dso ${(usD / 1000).toStringAsFixed(1)} ms ($nd), stars ${(usS / 1000).toStringAsFixed(1)} ms ($ns)',
    );
  }

  // What the planetarium draws from: views of the lists parsed above.
  final (stars, sStall, sWall) = await stalled(
    () => m.stars.brighterThan(12.0),
  );
  final (dsos, dStall, dWall) = await stalled(() => m.dsos.brighterThan(16.0));
  print(
    'planetarium star list: wall $sWall ms, stall $sStall ms, ${stars.length} stars',
  );
  print(
    'planetarium dso list: wall $dWall ms, stall $dStall ms, ${dsos.length} dsos',
  );

  final sIdx = StarSpatialIndex()..addAllPreSortedByMagnitude(stars);
  final dIdx = DsoSpatialIndex()..addAllPreSortedByMagnitude(dsos);
  sIdx.warmGrid();
  dIdx.warmGrid();
  // Dense field: galactic center, 60 and 10 degree views.
  for (final fov in [60.0, 10.0]) {
    late int n;
    final us = await medianUs(() async {
      n = sIdx
          .queryBrightestInViewport(
            17.76,
            -29.0,
            fov,
            maxMagnitude: 12,
            maxResults: 8000,
            aspectRatio: 1.6,
          )
          .length;
      n += dIdx
          .queryBrightestInViewport(
            17.76,
            -29.0,
            fov,
            maxMagnitude: 16,
            maxResults: 2000,
            aspectRatio: 1.6,
          )
          .length;
    }, n: 41);
    print('planetarium dense field query fov $fov: median $us us, $n objects');
  }

  print('rss after all loads: ${ProcessInfo.currentRss ~/ (1024 * 1024)} MB');

  if (withGlade) {
    final cat = AnnotationCatalog(
      ngcLoader: m.dsos,
      gladeLoader: GladePlusCatalogLoader('$dir/glade_plus_galaxies.csv'),
    );
    final (objs, gStall, gWall) = await stalled(
      () => cat.searchNearby(
        ra: 10.68,
        dec: 41.27,
        radiusDegrees: 1.5,
        maxMagnitude: 18,
      ),
    );
    print(
      'annotation GLADE+ cone M31 1.5deg: wall $gWall ms, stall $gStall ms, ${objs.length} objects',
    );
  }
  exit(0);
}
