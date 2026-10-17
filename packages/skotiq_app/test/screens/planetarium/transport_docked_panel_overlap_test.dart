// An open right-docked panel must not cover the planetarium's time transport.
//
// At a 900x900 window with the Layers drawer open the drawer is pinned to the
// right edge from x=620; a transport centred on the FULL 900 px canvas sits at
// x 432-700, rendering the clock as `18:46:` with the seconds behind the drawer
// and a fast-forward button that cannot be clicked at all, because the drawer
// takes the pointer. There is no overlap at 1600x900, and none at 420x900 where
// the drawer becomes a full-width sheet, which is why this pins the mid width
// specifically.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/planetarium_screen.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The Layers/Plan drawer width the shell docks at 900 px
/// (`clampPanelWidth(900, fraction: 0.30, min: 280, max: 380)`).
const double _drawerWidth = 280;
const Size _window = Size(900, 900);

Future<void> _pumpSlot(WidgetTester tester, double dockedWidth) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: SizedBox(
              width: _window.width,
              height: _window.height,
              child: Stack(
                children: [
                  PlanetariumTransportSlot(
                    colors: SkotiqColors.of(context),
                    compact: false,
                    dockedWidth: dockedWidth,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the transport clears an open drawer at 900 px', (tester) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpSlot(tester, _drawerWidth);

    final transport = tester.getRect(find.byType(TimeControlPanel));
    expect(
      transport.right,
      lessThanOrEqualTo(_window.width - _drawerWidth),
      reason: 'the fast-forward button sat behind the drawer and could not be '
          'clicked',
    );
    expect(transport.width, greaterThan(0));
  });

  testWidgets(
      'with no drawer open the transport is centred on the whole '
      'canvas', (tester) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpSlot(tester, 0);

    final transport = tester.getRect(find.byType(TimeControlPanel));
    expect(
      transport.center.dx,
      closeTo(_window.width / 2, 1.0),
      reason: 'the inset is load-bearing, not a constant shift',
    );
  });

  // An inset that only dodges the drawer moves the transport INTO the
  // instruments instead: at 900x900 with the Layers drawer open, transport
  // x 283-555 against compass dial 240-315 and minimap 500-620 covers the
  // compass's `S` label with the 77/90 deg altitude ticks and the left third of
  // the minimap including its `W`. The band arithmetic is pinned with those
  // exact numbers (tablet form factor: compass 90 + 40 altitude bar, minimap
  // 120, edge padding 16).
  group('the transport clears the compass and the minimap', () {
    test('at 900 px with a drawer open there is no room beside them', () {
      final band = planetariumTransportBand(
        stackWidth: 724, // 900 px window less the app nav rail
        dockedWidth: 280,
        edgePadding: 16,
        compassExtent: 130,
        minimapExtent: 120,
        instrumentBottom: 56,
        transportMinWidth: PlanetariumTransportSlot.minWidth,
      );
      // 724 - (16+130+8) - (280+16+120+8) = 146 px, half a transport.
      expect(
        band.bottom,
        greaterThan(56 + 130),
        reason: 'with nowhere to sit beside them it must clear them upward',
      );
      expect(band.left, 0);
      expect(band.right, 280, reason: 'the docked panel still owns its width');
    });

    test('at 1600 px it still centres between them', () {
      final band = planetariumTransportBand(
        stackWidth: 1424,
        dockedWidth: 380,
        edgePadding: 16,
        compassExtent: 120,
        minimapExtent: 100,
        instrumentBottom: 56,
        transportMinWidth: PlanetariumTransportSlot.minWidth,
      );
      expect(band.bottom, 44, reason: 'the bottom band is where it belongs');
      expect(band.left, 16 + 120 + 8);
      expect(band.right, 380 + 16 + 100 + 8);
      expect(
        1424 - band.left - band.right,
        greaterThanOrEqualTo(PlanetariumTransportSlot.minWidth),
      );
    });

    test('with both instruments hidden it uses the whole band', () {
      final band = planetariumTransportBand(
        stackWidth: 724,
        dockedWidth: 280,
        edgePadding: 16,
        compassExtent: 0,
        minimapExtent: 0,
        instrumentBottom: 56,
        transportMinWidth: PlanetariumTransportSlot.minWidth,
      );
      expect(band.left, 0);
      expect(band.right, 280);
      expect(band.bottom, 44);
    });
  });
}
