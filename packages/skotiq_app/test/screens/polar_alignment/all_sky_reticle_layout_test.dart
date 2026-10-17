// Regression guard for: "All-Sky reticle labels collide: the error marker, the
// az/alt caption and the 'Dn' compass label are drawn on top of each other".
//
// A caption at Positioned(bottom: 8) INSIDE the reticle Stack, a bottom compass
// label painted at radius + 4, and an altitude-dominated error pinning the
// marker to the bottom of the rim put three elements in the same ~30px band by
// construction.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/polar_alignment/widgets/all_sky_target_reticle.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the numeric caption sits outside the reticle box',
      (tester) async {
    // The audit's numbers: a 1800" total dominated by altitude, which pins the
    // marker to the bottom of the rim.
    await tester.pumpWidget(_wrap(
      const AllSkyTargetReticle(
        azimuthErrorArcsec: -351.4,
        altitudeErrorArcsec: -1765.4,
        acceptanceThresholdArcsec: 30,
      ),
    ));
    await tester.pump();

    final reticle = tester.getRect(find.byKey(allSkyReticleCanvasKey));
    final caption = tester.getRect(find.textContaining('Az '));
    final total = tester.getRect(find.textContaining('"').first);

    expect(caption.top, greaterThanOrEqualTo(reticle.bottom),
        reason: 'the az/alt caption must not be drawn over the reticle');
    expect(total.top, greaterThanOrEqualTo(reticle.bottom),
        reason: 'the total-error readout must not be drawn over the reticle');
    expect(reticle.width, closeTo(reticle.height, 0.5),
        reason: 'the painted reticle stays square');
  });

  testWidgets('a squeezed panel shrinks the reticle instead of the numbers',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const SizedBox(
        height: 160,
        child: AllSkyTargetReticle(
          azimuthErrorArcsec: -351.4,
          altitudeErrorArcsec: -1765.4,
          acceptanceThresholdArcsec: 30,
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final reticle = tester.getRect(find.byKey(allSkyReticleCanvasKey));
    final caption = tester.getRect(find.textContaining('Az '));
    expect(caption.top, greaterThanOrEqualTo(reticle.bottom));
    expect(caption.bottom, lessThanOrEqualTo(reticle.top + 160 + 0.5));
  });

  group('painted compass labels', () {
    const sizes = [Size(280, 280), Size(160, 160), Size(420, 420)];
    const cardinals = <(String, Alignment)>[
      ('Up', Alignment.topCenter),
      ('Dn', Alignment.bottomCenter),
      ('E', Alignment.centerRight),
      ('W', Alignment.centerLeft),
    ];

    testWidgets('stay inside the reticle box and clear the clamped marker',
        (tester) async {
      // A pure geometry check, but it needs the real text metrics, so it runs
      // under the widget binding.
      for (final size in sizes) {
        final box = Offset.zero & size;
        final marker = allSkyMarkerReach(size);
        for (final (text, alignment) in cardinals) {
          final label = allSkyCardinalLabelRect(
            size: size,
            alignment: alignment,
            text: text,
          );
          expect(box.contains(label.topLeft), isTrue,
              reason: '$text at $size starts outside the box');
          expect(box.contains(label.bottomRight - const Offset(0.01, 0.01)),
              isTrue,
              reason: '$text at $size runs past the box edge');
          expect(label.overlaps(marker), isFalse,
              reason: '$text at $size sits where a clamped marker lands');
        }
      }
    });
  });
}
