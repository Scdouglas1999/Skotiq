// A name search walks the whole star catalog (about 120,000 stars). It must
// hand the isolate back between slices, or the screen freezes until it ends:
// Tonight's Go to froze for 11 s on the imaging laptop.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  final catalog = [
    for (var i = 0; i < 200000; i++)
      Star(
        id: 'HIP $i',
        name: 'HIP $i',
        coordinates: CelestialCoordinate(ra: (i % 24).toDouble(), dec: 10),
        magnitude: 6 + (i % 600) / 100,
        catalogIds: ['HIP $i', 'HD ${i + 7}'],
      ),
  ];

  test('other work runs while a search walks a large star catalog', () async {
    final container = ProviderContainer(
      overrides: [
        loadedStarsProvider.overrideWith((ref) async => catalog),
        loadedDsosProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(loadedStarsProvider.future);
    await container.read(loadedDsosProvider.future);

    var searchEnded = false;
    final search = container
        .read(objectSearchProvider.notifier)
        .resolveBest('HD 150007')
        .whenComplete(() => searchEnded = true);
    bool? ranDuringSearch;
    Timer.run(() => ranDuringSearch = !searchEnded);

    final found = await search;
    expect(found?.id, 'HIP 150000');
    expect(
      ranDuringSearch,
      isTrue,
      reason: 'a timer queued at the start must run before the scan ends',
    );
  });
}
