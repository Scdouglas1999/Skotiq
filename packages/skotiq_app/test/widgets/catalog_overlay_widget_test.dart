// Widget test for F5-CATALOG-OVERLAY. Verifies:
//   * The overlay paints a marker for every projected catalog object
//     supplied via a fake catalog source
//   * The HUD reports the visible/total counts the painter emits
//   * Tapping a marker selects it in the side-panel provider
//   * The fallback banner appears when WCS is null

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/catalog_overlay_widget.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _StubCatalogSource implements CatalogOverlaySource {
  _StubCatalogSource({this.dsos = const []});

  final List<DeepSkyObject> dsos;
  final List<Star> stars = const <Star>[];

  @override
  Future<List<DeepSkyObject>> loadDsos() async => dsos;

  @override
  Future<List<Star>> loadStars() async => stars;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> get dsoCatalogAvailable async => dsos.isNotEmpty;

  @override
  Future<bool> get starCatalogAvailable async => stars.isNotEmpty;
}

const _wcs = SolvedWcs(
  raHours: 5.5,
  decDegrees: -5.0,
  rotationDeg: 0.0,
  pixelScaleArcsec: 1.5,
  imageWidth: 600,
  imageHeight: 600,
);

DeepSkyObject _dso({
  required String id,
  required double raHours,
  required double decDeg,
  required double magnitude,
  DsoType type = DsoType.galaxy,
}) {
  return DeepSkyObject(
    id: id,
    name: id,
    coordinates: CelestialCoordinate(ra: raHours, dec: decDeg),
    type: type,
    magnitude: magnitude,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  required CatalogOverlayService service,
  bool enabled = true,
  double magLimit = 10,
  bool includeDsos = true,
  bool includeStars = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(800, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        catalogOverlayServiceProvider.overrideWithValue(service),
        catalogOverlayEnabledProvider.overrideWith((_) => enabled),
        catalogOverlayMagnitudeLimitProvider.overrideWith((_) => magLimit),
        catalogOverlayIncludeDsosProvider.overrideWith((_) => includeDsos),
        catalogOverlayIncludeStarsProvider.overrideWith((_) => includeStars),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(body: child),
      ),
    ),
  );

  // Resolve the FutureProvider that backs the overlay's data.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'renders one painted marker per catalog object in the FOV',
    (tester) async {
      // Three objects all near the WCS centre so they project on-screen.
      final source = _StubCatalogSource(
        dsos: [
          _dso(id: 'M81', raHours: 5.5, decDeg: -5.0, magnitude: 6.9),
          _dso(id: 'NGC1', raHours: 5.5001, decDeg: -5.0, magnitude: 7.5),
          _dso(id: 'M99', raHours: 5.5, decDeg: -4.999, magnitude: 8.0),
        ],
      );
      final service = CatalogOverlayService(source: source);

      await _pump(
        tester,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: _wcs,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );

      // Inspect the painter via the widget tree to confirm three objects.
      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(CatalogOverlayWidget),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter as CatalogOverlayPainter;
      expect(painter.objects, hasLength(3));
      final ids = painter.objects.map((o) => o.id).toSet();
      expect(ids, containsAll(<String>['M81', 'NGC1', 'M99']));

      // HUD reports the correct counts.
      expect(find.text('3 of 3 objects ≤ mag 10.0'), findsOneWidget);
    },
  );

  testWidgets(
    'tapping a marker opens the catalog details panel',
    (tester) async {
      final source = _StubCatalogSource(
        dsos: [
          _dso(id: 'M81', raHours: 5.5, decDeg: -5.0, magnitude: 6.9),
        ],
      );
      final service = CatalogOverlayService(source: source);

      await _pump(
        tester,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: _wcs,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );

      expect(find.text('M81'), findsNothing);
      await tester.tapAt(const Offset(300, 300));
      await tester.pumpAndSettle();

      expect(find.text('M81'), findsOneWidget);
      expect(find.text('Catalog'), findsOneWidget);
      expect(find.text('Type'), findsOneWidget);
    },
  );

  testWidgets(
    'shows fallback banner when WCS is missing',
    (tester) async {
      final service = CatalogOverlayService(source: _StubCatalogSource());
      await _pump(
        tester,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: null,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );
      expect(find.text('Catalog overlay unavailable'), findsOneWidget);
    },
  );

  testWidgets(
    'renders nothing when the toggle is off',
    (tester) async {
      final service = CatalogOverlayService(source: _StubCatalogSource());
      await _pump(
        tester,
        enabled: false,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: _wcs,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );
      // When disabled, the catalog overlay widget should produce a
      // SizedBox.shrink() — no painter or banner descendant.
      expect(
        find.descendant(
          of: find.byType(CatalogOverlayWidget),
          matching: find.byType(CustomPaint),
        ),
        findsNothing,
      );
      expect(find.text('Catalog overlay unavailable'), findsNothing);
    },
  );

  testWidgets(
    'shows "no catalog installed" banner when source is empty + unavailable',
    (tester) async {
      final service = CatalogOverlayService(source: _UnavailableSource());
      await _pump(
        tester,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: _wcs,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );
      expect(find.text('No catalog installed'), findsOneWidget);
    },
  );

  testWidgets(
    'shows a clear empty state when every catalog layer is disabled',
    (tester) async {
      final service = CatalogOverlayService(source: _StubCatalogSource());
      await _pump(
        tester,
        includeDsos: false,
        includeStars: false,
        service: service,
        child: const SizedBox(
          width: 600,
          height: 600,
          child: CatalogOverlayWidget(
            wcs: _wcs,
            zoomLevel: 1.0,
            imageOffset: Offset.zero,
            imageSize: Size(600, 600),
          ),
        ),
      );
      expect(find.text('No catalog layers selected'), findsOneWidget);
    },
  );
}

class _UnavailableSource implements CatalogOverlaySource {
  @override
  Future<List<DeepSkyObject>> loadDsos() async => const [];

  @override
  Future<List<Star>> loadStars() async => const [];

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<bool> get dsoCatalogAvailable async => false;

  @override
  Future<bool> get starCatalogAvailable async => false;
}
