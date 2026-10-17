import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/widgets/atlas_coverage_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

AtlasTileCoverage _tile({
  required int tileId,
  required double ra,
  required double dec,
  double seconds = 600.0,
  int frames = 2,
}) {
  return AtlasTileCoverage(
    tileId: tileId,
    centerRaDeg: ra,
    centerDecDeg: dec,
    coverageMean: 1.0,
    totalFrames: frames,
    integrationSeconds: seconds,
    lastFoldIso: '2026-06-20',
    channels: 1,
  );
}

void main() {
  group('aitoffProject', () {
    const size = Size(400, 200);
    final center = Offset(size.width / 2, size.height / 2);

    test('the projection centre (RA=180, Dec=0) maps to the frame centre', () {
      final pos = aitoffProject(180.0, 0.0, size)!;
      expect(pos.dx, closeTo(center.dx, 1e-6));
      expect(pos.dy, closeTo(center.dy, 1e-6));
    });

    test('positive Dec is above centre, negative Dec below (y inverted)', () {
      final north = aitoffProject(180.0, 45.0, size)!;
      final south = aitoffProject(180.0, -45.0, size)!;
      expect(north.dy, lessThan(center.dy));
      expect(south.dy, greaterThan(center.dy));
      // Symmetric about the centre line.
      expect(north.dx, closeTo(center.dx, 1e-6));
      expect(south.dx, closeTo(center.dx, 1e-6));
      expect((center.dy - north.dy), closeTo(south.dy - center.dy, 1e-6));
    });

    test('RA increases LEFTWARD (astronomical convention)', () {
      // RA just east (greater) of the 180° centre lands left of centre.
      final east = aitoffProject(200.0, 0.0, size)!;
      final west = aitoffProject(160.0, 0.0, size)!;
      expect(east.dx, lessThan(center.dx));
      expect(west.dx, greaterThan(center.dx));
    });

    test('every finite RA/Dec stays inside the frame bounds', () {
      for (var ra = 0.0; ra < 360.0; ra += 15.0) {
        for (var dec = -90.0; dec <= 90.0; dec += 15.0) {
          final pos = aitoffProject(ra, dec, size)!;
          expect(pos.dx, inInclusiveRange(0.0, size.width));
          expect(pos.dy, inInclusiveRange(0.0, size.height));
        }
      }
    });

    test('non-finite inputs return null', () {
      expect(aitoffProject(double.nan, 0.0, size), isNull);
      expect(aitoffProject(0.0, double.infinity, size), isNull);
    });
  });

  group('AtlasCoverageOverlay', () {
    Widget host(Widget child) => MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        );

    testWidgets('renders the all-sky map with a coverage Semantics summary',
        (tester) async {
      await tester.pumpWidget(host(AtlasCoverageOverlay(
        coverage: [
          _tile(tileId: 1, ra: 180, dec: 0),
          _tile(tileId: 2, ra: 90, dec: 30, seconds: 1200),
        ],
      )));
      await tester.pumpAndSettle();

      expect(find.text('All-sky map'), findsOneWidget);
      // The container carries a screen-reader summary of coverage.
      expect(
        find.bySemanticsLabel(RegExp(r'All-sky coverage map: 2 tiles imaged')),
        findsOneWidget,
      );
    });

    // aitoffProject normalises x and y into the frame independently, so the
    // frame has to stay 2:1 or the whole sky is drawn squashed. A card wider
    // than the map's ceiling must therefore narrow the map, not flatten it.
    for (final surface in const [Size(2400, 1200), Size(360, 800)]) {
      testWidgets('the all-sky map keeps a 2:1 frame at $surface',
          (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = surface;
        addTearDown(() {
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
        });

        await tester.pumpWidget(host(AtlasCoverageOverlay(
          coverage: [_tile(tileId: 1, ra: 180, dec: 0)],
        )));
        await tester.pumpAndSettle();

        final sized = tester
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .where((paint) => !paint.size.isEmpty)
            .toList(growable: false);
        expect(sized, hasLength(1));
        expect(sized.single.size.aspectRatio, closeTo(2.0, 1e-9));
      });
    }

    testWidgets('an empty atlas shows no map section', (tester) async {
      await tester.pumpWidget(host(
        const AtlasCoverageOverlay(coverage: <AtlasTileCoverage>[]),
      ));
      await tester.pumpAndSettle();
      expect(find.text('All-sky map'), findsNothing);
      // The headline stats card still renders.
      expect(find.text('Atlas coverage'), findsOneWidget);
    });
  });
}
