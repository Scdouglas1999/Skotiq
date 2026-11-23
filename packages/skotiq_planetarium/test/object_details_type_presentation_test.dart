import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_design/skotiq_design.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

// The details header draws a type the way the rest of the panel does: an
// emission nebula is a cloud in the nebula color, not a gray star.
void main() {
  testWidgets('an emission nebula header uses the nebula icon and color', (
    tester,
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
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ObjectDetailsPanel(
                object: DeepSkyObject(
                  id: 'NGC7000',
                  name: 'North America Nebula',
                  coordinates: CelestialCoordinate(ra: 20.98, dec: 44.33),
                  type: DsoType.emissionNebula,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final header = tester.widget<Icon>(find.byIcon(LucideIcons.cloud).first);
    expect(header.color, SkyPlotColors.nebula);
    expect(find.byIcon(LucideIcons.star), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
