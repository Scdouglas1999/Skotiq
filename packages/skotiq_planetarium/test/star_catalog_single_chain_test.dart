import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

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

  test('the rendered star list and starsProvider are the same list', () async {
    final path = await writeCatalog();
    final catalog = _CountingCatalog(path);
    final container = ProviderContainer(
      overrides: [starCatalogProvider.overrideWithValue(catalog)],
    );
    addTearDown(container.dispose);

    final rendered = await container.read(loadedStarsProvider.future);
    final legacy = await container.read(starsProvider.future);

    expect(
      identical(rendered, legacy),
      isTrue,
      reason: 'a second parse would produce a second list',
    );
    expect(catalog.loadCalls, 1);
    expect(rendered, hasLength(1));
  });

  test('the fallback flag describes the catalog that is on screen', () async {
    final catalog = _CountingCatalog('${tempDir.path}/absent.csv');
    final container = ProviderContainer(
      overrides: [starCatalogProvider.overrideWithValue(catalog)],
    );
    addTearDown(container.dispose);

    final rendered = await container.read(loadedStarsProvider.future);

    expect(container.read(starCatalogFallbackProvider), isTrue);
    expect(
      container.read(starCatalogLoadOutcomeProvider),
      StarCatalogLoadOutcome.fileMissing,
    );
    expect(
      identical(rendered, await container.read(starsProvider.future)),
      isTrue,
      reason: 'the banner and the sky must be reading one catalog',
    );
  });

  test('the depth the renderer needs is the depth that is loaded', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // The renderer's deep-zoom limit. Loading shallower would silently thin the
    // sky at narrow FOV; deeper costs memory nothing draws.
    expect(container.read(starCatalogProvider).magnitudeLimit, 12.0);
  });
}

class _CountingCatalog extends HygStarCatalog {
  _CountingCatalog(String path) : super(catalogPath: path);

  int loadCalls = 0;

  @override
  Future<List<Star>> loadObjects() {
    loadCalls++;
    return super.loadObjects();
  }
}
