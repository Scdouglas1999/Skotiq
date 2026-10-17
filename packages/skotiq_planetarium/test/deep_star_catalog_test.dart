import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/catalogs/deep_star_catalog.dart';

void main() {
  late Directory directory;
  late DeepStarCatalogManager manager;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'skotiq_deep_star_catalog_test_',
    );
    manager = DeepStarCatalogManager(directory: directory.path);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('interrupted download files remain visible and deletable', () async {
    await File(
      '${directory.path}/config.json',
    ).writeAsString('{"baseUrl":"https://catalog.example"}');
    await File('${directory.path}/tile_r01_d02.nsdt.part').writeAsBytes([1, 2]);

    final interrupted = await manager.status();
    expect(interrupted.isInstalled, isFalse);
    expect(interrupted.hasLocalFiles, isTrue);
    expect(interrupted.hasCatalogData, isTrue);

    await manager.delete();

    expect(await File('${directory.path}/config.json').exists(), isTrue);
    expect(
      await File('${directory.path}/tile_r01_d02.nsdt.part').exists(),
      isFalse,
    );
    final cleaned = await manager.status();
    expect(cleaned.hasCatalogData, isFalse);
  });

  test('corrupt manifest remains visible for cleanup', () async {
    await File('${directory.path}/manifest.json').writeAsString('not json');

    final status = await manager.status();

    expect(status.isInstalled, isFalse);
    expect(status.hasLocalFiles, isTrue);
    expect(status.hasCatalogData, isTrue);
  });
}
