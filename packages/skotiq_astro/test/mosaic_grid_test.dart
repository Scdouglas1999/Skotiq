import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  test('the panels it takes to cover an area, at 15 % overlap', () {
    const cases = [
      // total w, total h, panel w, panel h -> rows, cols
      (180.0, 180.0, 120.0, 80.0, 3, 2),
      (60.0, 60.0, 120.0, 80.0, 1, 1),
      (102.0, 68.0, 120.0, 80.0, 1, 1),
      (102.1, 68.1, 120.0, 80.0, 2, 2),
      (10000.0, 10000.0, 1.0, 1.0, 100, 100),
    ];
    for (final (tw, th, pw, ph, rows, cols) in cases) {
      final grid = MosaicGrid.covering(
        totalWidth: tw,
        totalHeight: th,
        panelWidth: pw,
        panelHeight: ph,
      );
      expect((grid.rows, grid.columns), (rows, cols), reason: '$tw x $th');
    }
  });

  test('extent and step follow the overlap', () {
    const grid = MosaicGrid(columns: 3, rows: 2, overlapPercent: 10);
    expect(grid.step(60), closeTo(54, 1e-12));
    final (w, h) = grid.extent(60, 40);
    expect(w, closeTo(60 + 2 * 54, 1e-12));
    expect(h, closeTo(40 + 36, 1e-12));
  });
}
