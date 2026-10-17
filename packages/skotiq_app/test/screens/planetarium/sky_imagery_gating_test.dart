// Pins when the planetarium's sky-imagery layer runs, and that the survey
// credit is on screen whenever its imagery is.
//
// Two obligations are easy to regress without anything looking broken:
//
//   * Network. The app's normal deployment is an observatory laptop on an
//     isolated LAN. The layer must be OFF until the user asks for it, and must
//     ask for nothing at wide fields where the star chart is the better view.
//     Breaking this is invisible locally and costs a user their bandwidth
//     (and a pile of failing requests) in the field.
//   * Attribution. CDS and the survey publishers require the `obs_copyright`
//     credit while their imagery is displayed. Dropping it is a licence
//     violation that no rendering test would catch.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/sky_imagery/planetarium_sky_imagery_layer.dart';
import 'package:skotiq_app/screens/planetarium/widgets/full_screen_sky_view.dart';
import 'package:skotiq_app/screens/planetarium/sky_imagery/planetarium_sky_imagery_providers.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        HipsFrame,
        HipsProperties,
        HipsTileFormat,
        framingHipsPropertiesProvider;
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    hide SurveySource;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _props = HipsProperties(
  hipsOrder: 11,
  hipsOrderMin: 0,
  tileWidth: 512,
  tileWidthWasDefaulted: false,
  tileFormats: [HipsTileFormat.jpeg],
  frame: HipsFrame.equatorial,
  obsCopyright: 'Digitized Sky Survey / STScI',
  obsCopyrightUrl: 'https://archive.stsci.edu/dss/acknowledging.html',
);

void main() {
  ProviderContainer containerAt({required double fovDegrees}) {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    container.read(skyViewStateProvider.notifier).setFieldOfView(fovDegrees);
    return container;
  }

  group('activation', () {
    test('off by default — an offline laptop never reaches for the network',
        () {
      final container = containerAt(fovDegrees: 1.5);
      expect(container.read(planetariumSkyImageryEnabledProvider), isFalse);
      expect(container.read(planetariumSkyImageryActiveProvider), isFalse);
      expect(container.read(planetariumSkyImageryVisibleProvider), isFalse);
    });

    test('the toggle mounts the layer', () {
      final container = containerAt(fovDegrees: 1.5);
      container.read(planetariumSkyImageryEnabledProvider.notifier).state =
          true;
      expect(container.read(planetariumSkyImageryActiveProvider), isTrue);
      expect(container.read(planetariumSkyImageryWithinFovProvider), isTrue);
    });

    test(
        'a wide field asks for no tiles, but keeps the layer mounted so the '
        'cache survives a zoom-out', () {
      final container = containerAt(
        fovDegrees: kPlanetariumSkyImageryMaxFovDegrees + 0.5,
      );
      container.read(planetariumSkyImageryEnabledProvider.notifier).state =
          true;

      expect(container.read(planetariumSkyImageryWithinFovProvider), isFalse);
      expect(container.read(planetariumSkyImageryVisibleProvider), isFalse);
      // Still mounted: folding it away would drop the tile cache and force a
      // re-download the moment the user zoomed back in.
      expect(container.read(planetariumSkyImageryActiveProvider), isTrue);
    });

    test('the threshold itself is inclusive', () {
      final container = containerAt(
        fovDegrees: kPlanetariumSkyImageryMaxFovDegrees,
      );
      expect(container.read(planetariumSkyImageryWithinFovProvider), isTrue);
    });

    test('zooming out and back in preserves the user toggle', () {
      final container = containerAt(fovDegrees: 1.5);
      container.read(planetariumSkyImageryEnabledProvider.notifier).state =
          true;

      container.read(skyViewStateProvider.notifier).setFieldOfView(60);
      expect(container.read(planetariumSkyImageryWithinFovProvider), isFalse);
      expect(container.read(planetariumSkyImageryEnabledProvider), isTrue);

      container.read(skyViewStateProvider.notifier).setFieldOfView(1.5);
      expect(container.read(planetariumSkyImageryWithinFovProvider), isTrue);
    });
  });

  group('FullScreenSkyView forwarding', () {
    // FullScreenSkyView overrides build to add the background slot, replacing
    // AdaptiveInteractiveSkyView's own forwarding. A field the adapter gains
    // but the override drops would silently stop working on the main
    // planetarium view, with nothing wrong-looking in the diff. This pins every
    // field through to the v1 widget.
    testWidgets('carries every adapter field through to the sky view', (
      tester,
    ) async {
      const background = SkyBackgroundLayer(
        child: SizedBox.shrink(),
        occludesSkyGradient: true,
      );
      late Widget produced;

      await tester.pumpWidget(
        Builder(
          builder: (context) {
            // Built, not mounted: this asks the widget what it would produce
            // without standing up the whole sky-view provider graph.
            produced = const FullScreenSkyView(
              showFOV: true,
              customFOV: (1.25, 0.75),
              fovCenter: CelestialCoordinate(ra: 5.5, dec: -5.4),
              observedObjectIds: {'obs'},
              listedObjectIds: {'listed'},
              sequencedObjectIds: {'sequenced'},
              bortleClass: 3,
              horizonAltitudes: [1, 2, 3],
              measurementMode: true,
              backgroundLayer: background,
            ).build(context);
            return const SizedBox.shrink();
          },
        ),
      );

      final view = produced as InteractiveSkyView;
      expect(view.showFOV, isTrue);
      expect(view.customFOV, (1.25, 0.75));
      expect(view.fovCenter, const CelestialCoordinate(ra: 5.5, dec: -5.4));
      expect(view.observedObjectIds, {'obs'});
      expect(view.listedObjectIds, {'listed'});
      expect(view.sequencedObjectIds, {'sequenced'});
      expect(view.bortleClass, 3);
      expect(view.horizonAltitudes, [1, 2, 3]);
      expect(view.measurementMode, isTrue);
      expect(view.backgroundLayer, same(background));
    });
  });

  group('attribution', () {
    Future<void> pumpBadge(WidgetTester tester, {required bool visible}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            planetariumSkyImageryVisibleProvider.overrideWithValue(visible),
            framingHipsPropertiesProvider(
              kPlanetariumSkyImagerySurvey,
            ).overrideWith((ref) async => _props),
          ],
          child: MaterialApp(
            theme: ThemeData(extensions: const [SkotiqColors.dark]),
            home: const Scaffold(
              body: PlanetariumSkyImageryAttribution(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the survey credit is shown while imagery is displayed', (
      tester,
    ) async {
      await pumpBadge(tester, visible: true);
      expect(find.textContaining('Digitized Sky Survey'), findsOneWidget);
    });

    testWidgets('and nothing is shown when it is not', (tester) async {
      await pumpBadge(tester, visible: false);
      expect(find.textContaining('Digitized Sky Survey'), findsNothing);
    });
  });
}
