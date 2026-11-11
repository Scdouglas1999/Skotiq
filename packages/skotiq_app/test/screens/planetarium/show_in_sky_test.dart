// "Show in sky" hand-off: the planetarium's counterpart to the framing
// hand-off. The link itself (build, redirect, parse back) is pinned in
// test/router/app_routes_test.dart; these tests pin the effect on the sky view
// state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/show_in_sky.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Unmount before disposing: `ObservationTimeNotifier` (read via
/// `selectCoordinates`) owns a periodic Timer, and `testWidgets` asserts no
/// timer is pending at the end of the test body — which runs before
/// `addTearDown` callbacks, so the container has to be torn down inline.
Future<void> _teardown(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
}

void main() {
  group('focusSkyOn', () {
    testWidgets('centers the sky view and selects the coordinate',
        (tester) async {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      // The zenith — and so the sky view's home pose — is only defined for an
      // observer, so this case needs a site on record.
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40.0, longitude: -105.0);
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // The sky view starts at its default pose (the zenith — it no longer
      // opens on RA 0h / Dec 0, which pointed below the horizon), and nothing
      // is selected.
      final homeRa = container.read(skyViewHomeCenterProvider)!.$1;
      expect(
        container.read(skyViewStateProvider).centerRA,
        closeTo(homeRa, 0.02),
      );
      expect(container.read(selectedObjectProvider).coordinates, isNull);

      focusSkyOn(
        capturedRef,
        const CelestialCoordinate(ra: 13.5, dec: 47.2),
      );
      await tester.pump();

      final view = container.read(skyViewStateProvider);
      expect(view.centerRA, closeTo(13.5, 1e-6));
      expect(view.centerDec, closeTo(47.2, 1e-6));
      // State, not an event: a cold start reads this on first build, so the
      // hand-off survives the sky view not yet being mounted.
      expect(container.read(flyToRequestProvider), isNull);

      final selection = container.read(selectedObjectProvider);
      expect(selection.coordinates, isNotNull);
      expect(selection.coordinates!.ra, closeTo(13.5, 1e-6));

      await _teardown(tester, container);
    });

    testWidgets(
        'forces the equatorial frame so an RA/Dec target actually moves',
        (tester) async {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      // The zenith — and so the sky view's home pose — is only defined for an
      // observer, so this case needs a site on record.
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40.0, longitude: -105.0);
      // A user who left the sky view in the horizontal frame would otherwise
      // arrive at a planetarium that simply did not move: centerRA/centerDec
      // are inert there.
      container.read(skyViewStateProvider.notifier).setViewMode(
            SkyViewMode.horizontal,
            observer: container.read(observerLocationProvider),
            instant: DateTime.utc(2026, 7, 29, 15, 52),
          );

      late WidgetRef capturedRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      focusSkyOn(capturedRef, const CelestialCoordinate(ra: 5.59, dec: -5.39));
      await tester.pump();

      final view = container.read(skyViewStateProvider);
      expect(view.viewMode, SkyViewMode.equatorial);
      expect(view.centerRA, closeTo(5.59, 1e-6));
      expect(view.centerDec, closeTo(-5.39, 1e-6));

      await _teardown(tester, container);
    });
  });
}
