// The viewport's bottom corners are shared, and the sharing has to be real.
//
// Each overlay is independently anchored in one stack, so an overlay that
// assumes it owns its corner collides with its neighbour on every frame at the
// default 1600x900 window: the field-of-view scale bar painted straight across
// the bottom-left histogram plot (its `10'` label inside the card's lower
// border), and the bottom-right image-stats card drawn over the compass rose,
// bisecting the circle and leaving only the red N arrow legible.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/overlay_painters.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _viewport = Size(1100, 720);

Future<Size> _measure(WidgetTester tester, Widget child) async {
  // Same constraints the viewport gives it: a Positioned with only edge
  // offsets, so the readout sizes to its content exactly as it does in the app.
  await tester.pumpWidget(
    // The HUD panels read providers for the data they show, so they need a
    // scope even when the test only cares about their footprint.
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Stack(
            children: [Positioned(bottom: 14, left: 14, child: child)],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.getSize(find.byWidget(child));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the scale bar clears the bottom-left HUD stack', (tester) async {
    // The scale bar is drawn along the bottom-LEFT edge, where the
    // at-a-glance quality stack sits (05 §14 corner assignment).
    final scaleBar = ScaleBarPainter(
      pixelScaleArcsecPerPixel: 1.29,
      imageWidthPixels: 4000,
      zoomLevel: 0.25,
      bottomMargin: PreviewReadoutInsets.bottomLeft,
    );
    final stackTop = _viewport.height - PreviewReadoutInsets.bottomLeft;
    // The bar's background plate extends ~8px above the bar and its label sits
    // below; the bar line itself is the lowest ink that matters here.
    expect(
      scaleBar.barBaselineIn(_viewport),
      lessThanOrEqualTo(stackTop),
      reason: 'the scale bar is drawn through the bottom-left HUD stack',
    );
  });

  testWidgets('the compass rose clears the histogram glass', (tester) async {
    // The compass rose is drawn in the bottom-RIGHT corner, which the
    // histogram glass now owns.
    const histogram = HistogramHud();
    final size = await _measure(tester, histogram);
    final histogramTop = _viewport.height - 14 - size.height;

    final compass = CompassOverlayPainter(
      rotationDegrees: 12,
      bottomMargin: PreviewReadoutInsets.bottomRight,
      colors: SkotiqColors.dark,
    );
    expect(
      compass.boundsIn(_viewport).bottom,
      lessThanOrEqualTo(histogramTop),
      reason: 'the histogram glass is drawn on top of the compass rose',
    );
    expect(
      PreviewReadoutInsets.bottomRight,
      greaterThanOrEqualTo(14 + size.height),
      reason: 'the reserved inset must cover the panel it is reserving for',
    );
  });
}
