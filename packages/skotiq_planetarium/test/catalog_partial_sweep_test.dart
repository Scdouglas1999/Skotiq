// Startup reclaims a `<name>.partial` left by a download that never finished.
//
// The download's own cleanup runs only in its `finally`, so a crash, a kill or
// a power cut during the multi-hundred-megabyte GLADE+ fetch strands the whole
// file — seen in the wild as a 407 MiB glade_plus_galaxies.csv.partial six
// weeks old, with the Catalogs page showing GLADE+ as "not installed" and
// offering a fresh download beside it, nothing deleting it and nothing
// mentioning it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_catalog_partial_');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('initialize reclaims an abandoned partial download', () async {
    final abandoned = File('${tempDir.path}/glade_plus_galaxies.csv.partial');
    await abandoned.writeAsBytes(List<int>.filled(4096, 0x41));
    final keeper = File('${tempDir.path}/hygdata_v41.csv');
    await keeper.writeAsString('id,proper\n1,Sirius\n');

    await CatalogManager.instance.initialize(tempDir.path);

    expect(
      await abandoned.exists(),
      isFalse,
      reason: 'an unresumable leftover must not sit on the disk forever',
    );
    expect(
      await keeper.exists(),
      isTrue,
      reason: 'an installed catalog must survive the sweep',
    );
  });

  // The deep-star fetcher writes `<tile>.part` into a `deep_stars/`
  // SUBdirectory, so a top-level, `.partial`-only sweep walked straight past
  // it and those leftovers stayed forever too.
  test('a deep-star tile leftover in a subdirectory is reclaimed', () async {
    final tiles = Directory('${tempDir.path}/deep_stars')..createSync();
    final abandonedTile = File('${tiles.path}/nsdt_0421.nsdt.part');
    await abandonedTile.writeAsBytes(List<int>.filled(8192, 0x42));
    final installedTile = File('${tiles.path}/nsdt_0420.nsdt');
    await installedTile.writeAsBytes(List<int>.filled(16, 0x43));

    await CatalogManager.instance.initialize(tempDir.path);

    expect(
      await abandonedTile.exists(),
      isFalse,
      reason: 'a tile temp file is stranded by the same crash as a .partial',
    );
    expect(
      await installedTile.exists(),
      isTrue,
      reason: 'an installed tile must survive the sweep',
    );
  });

  test('a directory with no leftovers is untouched', () async {
    final keeper = File('${tempDir.path}/hygdata_v41.csv');
    await keeper.writeAsString('id,proper\n1,Sirius\n');

    await CatalogManager.instance.initialize(tempDir.path);

    expect(await keeper.exists(), isTrue);
    expect(
      await tempDir.list().length,
      1,
      reason: 'the sweep must remove only .partial files',
    );
  });
}
