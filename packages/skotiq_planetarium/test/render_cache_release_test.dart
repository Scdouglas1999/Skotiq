import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The renderer's process-wide caches must be releasable.
///
/// `_PaintCache.clearCaches()` — the function that disposes cached
/// `TextPainter`s, shaders and the baked GPU sprite atlas — had no callers
/// anywhere, and neither did `_ProjectionCache.clear()`. So the sprite atlas (a
/// `ui.Image` from `Picture.toImageSync`) and a projection cache holding a
/// strong reference to every projected `Star`/`DeepSkyObject` survived closing
/// the planetarium, for the life of the process. On a Raspberry Pi appliance
/// nothing ever gave that memory back.
void main() {
  const stars = <Star>[
    Star(
      id: 'HIP24608',
      name: 'Capella',
      coordinates: CelestialCoordinate(ra: 5.27815, dec: 45.997991),
      magnitude: 0.08,
    ),
    Star(
      id: 'HIP32349',
      name: 'Sirius',
      coordinates: CelestialCoordinate(ra: 6.752481, dec: -16.716116),
      magnitude: -1.46,
    ),
  ];

  Future<ProviderContainer> pumpSkyView(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        combinedStarsProvider.overrideWithValue(const AsyncValue.data(stars)),
        fovFilteredDsosProvider.overrideWithValue(
          const AsyncValue.data(<DeepSkyObject>[]),
        ),
        planetPositionsProvider.overrideWithValue(const []),
      ],
    );
    // The sky is drawn from the observer's site; without one the view renders
    // its no-site state instead.
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);
    container
        .read(skyViewStateProvider.notifier)
        .setCenter(stars.first.coordinates.ra, stars.first.coordinates.dec);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: InteractiveSkyView())),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('closing the sky view releases the renderer caches', (
    tester,
  ) async {
    final container = await pumpSkyView(tester);

    expect(
      SkyCanvasPainter.projectionCacheEntryCount,
      greaterThan(0),
      reason:
          'the paint must have populated the cache for the test to mean '
          'anything',
    );
    final atlasWasBaked = SkyCanvasPainter.spriteAtlasIsResident;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();

    expect(SkyCanvasPainter.projectionCacheEntryCount, 0);
    if (atlasWasBaked) {
      expect(
        SkyCanvasPainter.spriteAtlasIsResident,
        isFalse,
        reason: 'the GPU sprite atlas must not outlive the screen',
      );
    }
  });

  testWidgets('memory pressure releases the caches while still on screen', (
    tester,
  ) async {
    final container = await pumpSkyView(tester);

    expect(SkyCanvasPainter.projectionCacheEntryCount, greaterThan(0));

    // What the engine sends on a system low-memory warning.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/system',
      const JSONMessageCodec().encodeMessage(<String, dynamic>{
        'type': 'memoryPressure',
      }),
      (_) {},
    );
    await tester.pump();

    expect(SkyCanvasPainter.projectionCacheEntryCount, 0);
    expect(SkyCanvasPainter.spriteAtlasIsResident, isFalse);

    // And the view keeps working: the next paint rebuilds what it needs.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });

  testWidgets('a second sky view closing does not strip the first', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        combinedStarsProvider.overrideWithValue(const AsyncValue.data(stars)),
        fovFilteredDsosProvider.overrideWithValue(
          const AsyncValue.data(<DeepSkyObject>[]),
        ),
        planetPositionsProvider.overrideWithValue(const []),
      ],
    );
    // The sky is drawn from the observer's site; without one the view renders
    // its no-site state instead.
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);

    Future<void> pumpWith(int views) => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < views; i++)
                  const Expanded(child: InteractiveSkyView()),
              ],
            ),
          ),
        ),
      ),
    );

    await pumpWith(2);
    await tester.pump();
    expect(SkyCanvasPainter.projectionCacheEntryCount, greaterThan(0));

    // Close one. The other is still drawing, so the shared caches must stay.
    await pumpWith(1);
    await tester.pump();
    expect(
      SkyCanvasPainter.projectionCacheEntryCount,
      greaterThan(0),
      reason: 'a still-mounted view would have to re-project its whole catalog',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(SkyCanvasPainter.projectionCacheEntryCount, 0);
    container.dispose();
  });
}
