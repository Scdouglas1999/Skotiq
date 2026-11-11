import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

void main() {
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester,
    CelestialObject object,
  ) async {
    final container = ProviderContainer();
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);
    container
        .read(observationTimeProvider.notifier)
        .setTime(DateTime(2026, 3, 14, 22, 0, 0));
    container.read(observationTimeProvider.notifier).pause();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ObjectDetailsPanel(object: object),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  // The observation clock's timer must be gone before the test ends.
  Future<void> unmount(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  }

  testWidgets('a southern object keeps its minus sign', (tester) async {
    final container = await pumpPanel(
      tester,
      const DeepSkyObject(
        id: 'M42',
        name: 'Orion Nebula',
        coordinates: CelestialCoordinate(ra: 5.588, dec: -5.39),
        type: DsoType.nebula,
      ),
    );
    expect(find.text('05h 35m 16.8s'), findsOneWidget);
    expect(find.text('-05° 23\' 24"'), findsOneWidget);
    await unmount(tester, container);
  });

  testWidgets('seconds carry instead of reading 60', (tester) async {
    final container = await pumpPanel(
      tester,
      const DeepSkyObject(
        id: 'X',
        name: 'Boundary',
        coordinates: CelestialCoordinate(
          ra: 2 + 59 / 60 + 59.96 / 3600,
          dec: 42 + 47 / 60,
        ),
        type: DsoType.galaxy,
      ),
    );
    expect(find.text('03h 00m 00.0s'), findsOneWidget);
    expect(find.text('+42° 47\' 00"'), findsOneWidget);
    await unmount(tester, container);
  });
}
