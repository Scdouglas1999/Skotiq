// qa-surfaces S41: after a solved frame folded into the atlas, Your sky still
// read "Your sky is dark" until Refresh was pressed: the host read its
// coverage once.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../harness/in_memory_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('coverage follows a fold without a refresh', () async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    final seen = <int>[];
    container.listen<AsyncValue<List<AtlasTileCoverage>>>(
      skyAtlasCoverageProvider,
      (_, next) {
        final rows = next.valueOrNull;
        if (rows != null) seen.add(rows.length);
      },
      fireImmediately: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.last, 0);

    await container
        .read(skyAtlasDaoProvider)
        .upsertTile(
          tileId: 42,
          channels: 1,
          centerRaDeg: 40,
          centerDecDeg: 20,
          coverageMean: 1,
          totalFrames: 1,
          integrationSeconds: 2,
          sidecarPath: '/nowhere/42.skt',
        );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.last, 1);
  });
}
