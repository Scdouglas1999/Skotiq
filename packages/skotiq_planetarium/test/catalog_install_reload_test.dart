// Catalogs installed while the app runs are searchable at once: the loaded
// deep-sky list is not the empty list read at startup before the download.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_catalog_reload_');
    await CatalogManager.instance.initialize(tempDir.path);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a deep-sky catalog installed after startup resolves M31', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final keepAlive = container.listen(loadedDsosProvider, (_, _) {});
    addTearDown(keepAlive.close);

    // Startup: nothing installed yet.
    await container.read(catalogStateProvider.notifier).refreshStatus();
    expect(await container.read(loadedDsosProvider.future), isEmpty);

    // The download lands the OpenNGC file and reports completion.
    await File(
      '../skotiq_astro/test/fixtures/target_search_ngc.csv',
    ).copy(CatalogManager.instance.dsoCatalogPath);
    await container.read(catalogStateProvider.notifier).refreshStatus();

    final dsos = await container.read(loadedDsosProvider.future);
    expect(dsos.map((d) => d.id), contains('NGC224'));
    final m31 = await container
        .read(objectSearchProvider.notifier)
        .resolveBest('M31');
    expect(m31?.id, 'NGC224');
  });
}
