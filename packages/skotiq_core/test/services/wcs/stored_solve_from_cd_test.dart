// A solve posted with a CD matrix but no scalar rotation or pixel scale is
// still a solve: the atlas, First Light and overlays read it from the matrix.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_core/src/services/wcs/plate_solve_data_from_result.dart';

void main() {
  test('a stored CD matrix gives the rotation and scale a row left out', () {
    // 1.5"/px, rotated 30 degrees.
    const scaleDeg = 1.5 / 3600.0;
    const matrix = (
      cd1_1: -scaleDeg * 0.8660254037844387,
      cd1_2: scaleDeg * 0.5,
      cd2_1: scaleDeg * 0.5,
      cd2_2: scaleDeg * 0.8660254037844387,
    );
    final wcs = solvedWcsFromStored(
      raHours: 10.0,
      decDegrees: 41.0,
      rotationDeg: null,
      pixelScaleArcsec: null,
      imageWidth: 6248,
      imageHeight: 4176,
      cd1_1: matrix.cd1_1,
      cd1_2: matrix.cd1_2,
      cd2_1: matrix.cd2_1,
      cd2_2: matrix.cd2_2,
    );

    expect(wcs, isNotNull);
    expect(wcs!.pixelScaleArcsec, closeTo(1.5, 1e-9));
    expect(
      wcs.rotationDeg,
      closeTo(
        SolvedWcs.rotationFromCd(
          cd1_1: matrix.cd1_1,
          cd1_2: matrix.cd1_2,
          cd2_1: matrix.cd2_1,
          cd2_2: matrix.cd2_2,
        ),
        1e-9,
      ),
    );
  });

  test('a row with neither a rotation nor a CD matrix is not a solve', () {
    expect(
      solvedWcsFromStored(
        raHours: 10.0,
        decDegrees: 41.0,
        rotationDeg: null,
        pixelScaleArcsec: 1.5,
        imageWidth: 100,
        imageHeight: 100,
      ),
      isNull,
    );
  });
}
