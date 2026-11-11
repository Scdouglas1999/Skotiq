import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

/// The package must load the HYG catalog exactly once.
///
/// A second chain would parse the same ~120k-row CSV in its own isolate and
/// retain its own `List<Star>`, and whichever one the fallback banner reads
/// would not be the catalog on screen.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hyg_single_chain');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  Future<String> writeCatalog() async {
    final header = List<String>.filled(33, 'c').join(',');
    final row = List<String>.filled(33, '');
    row[0] = '1';
    row[6] = 'Test Star';
    row[7] = '5.5';
    row[8] = '-5.4';
    row[13] = '2.5';
    row[29] = 'ORI';
    final file = File('${tempDir.path}/hygdata.csv');
    await file.writeAsString('$header\n${row.join(',')}\n');
    return file.path;
  }

  test('the star list and the star index come from one parse', () async {
    final path = await writeCatalog();
    final catalog = _CountingCatalog(path);
    final container = ProviderContainer(
      overrides: [starCatalogProvider.overrideWithValue(catalog)],
    );
    addTearDown(container.dispose);

    final rendered = await container.read(loadedStarsProvider.future);
    await container.read(starSpatialIndexProvider.future);

    expect(catalog.loadCalls, 1);
    expect(rendered, hasLength(1));
  });

  test('the fallback flag describes the catalog that is on screen', () async {
    final catalog = _CountingCatalog('${tempDir.path}/absent.csv');
    final container = ProviderContainer(
      overrides: [starCatalogProvider.overrideWithValue(catalog)],
    );
    addTearDown(container.dispose);

    await container.read(loadedStarsProvider.future);

    expect(container.read(starCatalogFallbackProvider), isTrue);
    expect(catalog.loadOutcome, StarCatalogLoadOutcome.fileMissing);
  });

  test('the depth the renderer needs is the depth it is given', () async {
    final path = await writeCatalog();
    final file = File(path);
    final lines = await file.readAsLines();
    final faint = lines[1].split(',')
      ..[0] = '2'
      ..[1] = '2'
      ..[13] = '12.5';
    await file.writeAsString('${lines.join('\n')}\n${faint.join(',')}\n');
    final container = ProviderContainer(
      overrides: [starCatalogProvider.overrideWithValue(HygStarCatalog(path))],
    );
    addTearDown(container.dispose);

    // Magnitude 12 is the renderer's deep-zoom limit. Shallower would thin
    // the sky at narrow FOV; deeper costs memory nothing draws.
    final stars = await container.read(loadedStarsProvider.future);
    expect(stars.map((s) => s.magnitude), [2.5]);
  });
}

class _CountingCatalog extends HygStarCatalog {
  _CountingCatalog(super.path);

  int loadCalls = 0;

  @override
  Future<List<Star>> load() {
    loadCalls++;
    return super.load();
  }
}
