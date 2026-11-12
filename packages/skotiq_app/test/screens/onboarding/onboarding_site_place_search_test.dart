// The first-run site step finds a site by place name, as Settings > Location
// does.
//
// Walk-2 F19: Settings had "Search place" and read DMS; the onboarding step
// had neither, so the same data had two different editors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/site_step.dart';
import 'package:skotiq_app/widgets/site/place_search.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  testWidgets('a searched place becomes the site, elevation included',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingSiteStep(),
      size: const Size(1000, 1000),
      extraOverrides: [
        placeSearchProvider.overrideWithValue((query) async {
          expect(query, 'Cherry Springs');
          return const [
            PlaceSearchHit(
              latitude: 41.6626,
              longitude: -77.8236,
              elevation: 701,
              label: 'Cherry Springs State Park, Pennsylvania',
            ),
          ];
        }),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Search place'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(PlaceSearchInput),
        matching: find.byType(TextField),
      ),
      'Cherry Springs',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cherry Springs State Park, Pennsylvania · 701 m'));
    await tester.pumpAndSettle();

    final settings = handle.container.read(appSettingsProvider).value!;
    expect(settings.latitude, closeTo(41.6626, 1e-6));
    expect(settings.longitude, closeTo(-77.8236, 1e-6));
    expect(settings.elevation, 701);
  });

  testWidgets('a name that matches nothing says so in place', (tester) async {
    await pumpAppScreen(
      tester,
      const OnboardingSiteStep(),
      size: const Size(1000, 1000),
      extraOverrides: [
        placeSearchProvider.overrideWithValue((query) async => const []),
      ],
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(PlaceSearchInput),
        matching: find.byType(TextField),
      ),
      'Nowhere Flats',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('No places matched "Nowhere Flats".'), findsOneWidget);
  });

  testWidgets('a search that cannot reach the service says so', (tester) async {
    await pumpAppScreen(
      tester,
      const OnboardingSiteStep(),
      size: const Size(1000, 1000),
      extraOverrides: [
        placeSearchProvider.overrideWithValue(
          (query) async => throw const PlaceSearchUnavailable(
            'Could not reach geocoding-api.open-meteo.com. Check the internet '
            'connection, or enter the coordinates.',
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(PlaceSearchInput),
        matching: find.byType(TextField),
      ),
      'Cherry Springs',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.textContaining('No places matched'), findsNothing);
    expect(
      find.textContaining('Could not reach geocoding-api.open-meteo.com'),
      findsOneWidget,
    );
  });
}
