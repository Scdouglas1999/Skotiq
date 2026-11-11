// Whether a planner candidate fits the camera's field: the detail pane drew
// every target in a fixed 90' box, so M31 (178') looked like an empty frame
// and nothing said it was six times the sensor's long side.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';

void main() {
  // 1920 x 1080 at 3.76 um behind 800 mm: about 31' x 17'.
  const width = 31.0;
  const height = 17.4;

  PlannerFieldFit? fit(double? size) => PlannerFieldFit.of(
        sizeArcmin: size,
        fieldWidthArcmin: width,
        fieldHeightArcmin: height,
      );

  test('a small galaxy fits with room around it', () {
    expect(fit(7.4)!.kind, PlannerFieldFitKind.fits);
    expect(fit(7.4)!.label, 'Fits the frame');
  });

  test('a target just inside the short side fills the frame', () {
    expect(fit(16)!.kind, PlannerFieldFitKind.fills);
  });

  test('a target wider than the short side needs a second row', () {
    final fit20 = fit(20)!;
    expect(fit20.kind, PlannerFieldFitKind.mosaic);
    expect((fit20.columns, fit20.rows), (1, 2));
  });

  test('a target larger than the field needs a mosaic, and how big', () {
    final m31 = fit(177.8)!;
    expect(m31.kind, PlannerFieldFitKind.mosaic);
    expect(m31.columns, 7);
    expect(m31.rows, 13);
    expect(m31.label, 'Needs a 7 × 13 mosaic');
  });

  test('no catalogued size, no verdict', () {
    expect(fit(null), isNull);
    expect(fit(0), isNull);
  });
}
