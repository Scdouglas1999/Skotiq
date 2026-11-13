import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

List<MosaicPanel> _grid({
  MosaicStartCorner corner = MosaicStartCorner.topLeft,
  bool serpentine = true,
}) =>
    mosaicPanelCenters(
      centerRaHours: 10,
      centerDecDegrees: 20,
      stepRaDegrees: 1,
      stepDecDegrees: 1,
      columns: 3,
      rows: 2,
      startCorner: corner,
      serpentine: serpentine,
    );

void main() {
  test('panel 1 is the top-left panel: north-east, rows down, columns across',
      () {
    final panels = _grid();
    expect([for (final p in panels) (p.row, p.col)],
        [(0, 0), (0, 1), (0, 2), (1, 2), (1, 1), (1, 0)]);
    expect([for (final p in panels) p.number], [1, 2, 3, 4, 5, 6]);
    expect(panels.first.name, 'Panel 1');
    final first = panels.first;
    final last = panels.last;
    expect(first.decDegrees, greaterThan(20), reason: 'row 0 is north');
    expect(first.raHours, greaterThan(10), reason: 'column 0 is east');
    expect(last.decDegrees, lessThan(20));
  });

  test('the start corner and serpentine change only the order', () {
    final topLeft = _grid();
    final bottomRight =
        _grid(corner: MosaicStartCorner.bottomRight, serpentine: false);
    expect([for (final p in bottomRight) (p.row, p.col)],
        [(1, 2), (1, 1), (1, 0), (0, 2), (0, 1), (0, 0)]);
    MosaicPanel at(List<MosaicPanel> ps, int row, int col) =>
        ps.firstWhere((p) => p.row == row && p.col == col);
    for (final p in topLeft) {
      final same = at(bottomRight, p.row, p.col);
      expect(same.raHours, p.raHours);
      expect(same.decDegrees, p.decDegrees);
    }
  });

  test('panel target names come from one rule', () {
    expect(mosaicPanelName(2), 'Panel 3');
    expect(mosaicPanelTargetName('M31 Mosaic', 2), 'M31 Mosaic Panel 3');
  });
}
