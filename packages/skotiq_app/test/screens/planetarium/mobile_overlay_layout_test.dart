// Orientation-aware overlay placement tests for the mobile planetarium.
//
// [MobileOverlaySlots] recomputes every overlay rectangle (tool rail, compass,
// mini-map, time panel, FAB column) from the live viewport + SafeArea, so the
// layout re-flows on rotate; hard-coded offsets tuned for portrait overlap and
// clip in landscape. The geometry is a pure value type, so it can be verified at
// every supported phone size in BOTH orientations without pumping the GPU sky
// view (which planetarium_screen_test.dart documents as out of scope).
//
// Asserts, per the mobile-responsive standard:
//   * no two floating overlays overlap,
//   * every overlay sits inside the viewport (nothing clipped),
//   * a portrait -> landscape rotate keeps overlays in bounds and
//     collision-free.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/mobile_overlay_layout.dart';

/// Phone-tier sizing matching `AdaptiveSizing` (FormFactor.phone) so the test
/// mirrors what the screen actually passes the resolver.
MobileOverlaySlots _resolve(Size viewport, {EdgeInsets? safeArea}) {
  // A representative phone SafeArea: status bar / home indicator in portrait,
  // a side notch when rotated to landscape.
  final insets = safeArea ??
      (viewport.width > viewport.height
          ? const EdgeInsets.only(left: 44, right: 44, bottom: 21)
          : const EdgeInsets.only(top: 47, bottom: 34));
  return MobileOverlaySlots.resolve(
    viewport: viewport,
    safeArea: insets,
    edge: 12,
    compassSize: 60,
    minimapSize: 80,
    timePanelSize: const Size(150, 40),
    // search (40) + filter (40) + info (56) FABs with 12px gaps.
    fabColumnSize: const Size(56, 40 + 12 + 40 + 12 + 56),
  );
}

const _portrait = <(String, Size)>[
  ('small 360x640', Size(360, 640)),
  ('modern 390x844', Size(390, 844)),
  ('large 430x932', Size(430, 932)),
];
const _landscape = <(String, Size)>[
  ('small 640x360', Size(640, 360)),
  ('modern 844x390', Size(844, 390)),
  ('large 932x430', Size(932, 430)),
];

void main() {
  group('MobileOverlaySlots placement', () {
    for (final (label, size) in [..._portrait, ..._landscape]) {
      test('$label: floating overlays never overlap and stay in bounds', () {
        final slots = _resolve(size);

        expect(slots.allWithinBounds, isTrue,
            reason: 'Every overlay must sit inside the $label viewport — '
                'nothing clipped off-screen.\n'
                'compass=${slots.compass}\nminimap=${slots.minimap}\n'
                'timePanel=${slots.timePanel}\nfab=${slots.fabColumn}\n'
                'leftRail=${slots.leftRail}');

        expect(slots.floatingOverlaysOverlap, isFalse,
            reason: 'No two floating overlays (compass / mini-map / time panel '
                '/ FAB column) may overlap at $label.\n'
                'compass=${slots.compass}\nminimap=${slots.minimap}\n'
                'timePanel=${slots.timePanel}\nfab=${slots.fabColumn}');
      });
    }

    test('orientation flag tracks aspect ratio', () {
      expect(_resolve(const Size(390, 844)).isLandscape, isFalse,
          reason: 'A taller-than-wide viewport is portrait.');
      expect(_resolve(const Size(844, 390)).isLandscape, isTrue,
          reason: 'A wider-than-tall viewport is landscape.');
    });

    test(
        'portrait -> landscape rotate keeps overlays in bounds and '
        'collision-free (the regression this fix targets)', () {
      // Same logical device, rotated: 390x844 -> 844x390 with the notch moving
      // from the top to the side.
      final portrait = MobileOverlaySlots.resolve(
        viewport: const Size(390, 844),
        safeArea: const EdgeInsets.only(top: 47, bottom: 34),
        edge: 12,
        compassSize: 60,
        minimapSize: 80,
        timePanelSize: const Size(150, 40),
        fabColumnSize: const Size(56, 160),
      );
      expect(portrait.allWithinBounds, isTrue);
      expect(portrait.floatingOverlaysOverlap, isFalse);

      final landscape = MobileOverlaySlots.resolve(
        viewport: const Size(844, 390),
        safeArea: const EdgeInsets.only(left: 47, right: 34, bottom: 21),
        edge: 12,
        compassSize: 60,
        minimapSize: 80,
        timePanelSize: const Size(150, 40),
        fabColumnSize: const Size(56, 160),
      );

      expect(landscape.allWithinBounds, isTrue,
          reason: 'After rotating to landscape, every overlay must still sit '
              'inside the (now short) viewport.');
      expect(landscape.floatingOverlaysOverlap, isFalse,
          reason: 'After rotating to landscape, the compass / mini-map / time '
              'panel / FAB column must not collide — the exact failure the '
              'fixed-offset layout produced.');

      // The compass moves to the top-right corner in landscape (free space),
      // not bottom-left where the cramped height would stack it onto the time
      // panel.
      expect(landscape.compass.top, lessThan(landscape.timePanel.top),
          reason: 'In landscape the compass should lift to the top, above the '
              'bottom-anchored time panel.');
    });

    test('degenerate tiny viewport does not throw or invert rects', () {
      // Below any supported size; the clamp helper must keep rects well-formed.
      final slots =
          _resolve(const Size(200, 200), safeArea: const EdgeInsets.all(0));
      for (final r in <Rect>[
        slots.leftRail,
        slots.compass,
        slots.minimap,
        slots.timePanel,
        slots.fabColumn,
      ]) {
        expect(r.width >= 0 && r.height >= 0, isTrue,
            reason: 'No rect may have negative extent even on a tiny viewport: '
                '$r');
      }
    });
  });
}
