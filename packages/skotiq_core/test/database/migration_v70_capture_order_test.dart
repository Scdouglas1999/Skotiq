// The v70 migration numbers old mosaic grids with its own frozen copy of the
// capture-order inference; today it answers exactly as the live one does.
// When the live geometry changes on purpose, delete this test: the copy is
// meant to stay as it is.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show MosaicStartCorner, inferMosaicCaptureOrder, mosaicPanelCenters;
import 'package:skotiq_core/src/database/database.dart';

void main() {
  test('the frozen v70 rule agrees with the live inference', () {
    var cases = 0;
    for (final (columns, rows) in [(3, 2), (2, 3), (4, 4), (1, 3), (5, 1)]) {
      for (final corner in MosaicStartCorner.values) {
        for (final serpentine in [false, true]) {
          for (final rotation in [0.0, 12.5, 35.0, 90.0, 181.0, -47.0]) {
            for (final centerRa in [0.01, 6.5, 23.99]) {
              final panels = mosaicPanelCenters(
                centerRaHours: centerRa,
                centerDecDegrees: 41,
                stepRaDegrees: 0.8,
                stepDecDegrees: 0.6,
                columns: columns,
                rows: rows,
                rotationDegrees: rotation,
                startCorner: corner,
                serpentine: serpentine,
              );
              for (final kept in [
                panels,
                panels.where((p) => p.index.isOdd),
                panels.take(1),
                const <Never>[],
              ]) {
                final input = [
                  for (final p in kept)
                    (
                      index: p.index,
                      raHours: p.raHours,
                      decDegrees: p.decDegrees,
                    ),
                ];
                final live = inferMosaicCaptureOrder(
                  columns: columns,
                  rows: rows,
                  rotationDegrees: rotation,
                  panels: input,
                );
                final frozen = v70CaptureOrderOfStoredGrid(
                  columns: columns,
                  rows: rows,
                  rotationDegrees: rotation,
                  panels: input,
                );
                expect(
                  (frozen.startCorner, frozen.serpentine),
                  (live.startCorner.name, live.serpentine),
                  reason: '$columns x $rows $corner $serpentine $rotation',
                );
                cases++;
              }
            }
          }
        }
      }
    }
    expect(cases, greaterThan(1000));
  });
}
