import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/workbench_view.dart';
import 'package:skotiq_core/skotiq_core.dart';

DbCapturedImage _sub(int id, double hfr) => DbCapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: false,
      hfr: hfr,
    );

void main() {
  test('field quality selection follows identity across same-length refreshes',
      () {
    final oldSubs = [_sub(1, 2.5), _sub(2, 2.0)];

    expect(
      reconcileFieldQualityIndex(
        oldSubs: oldSubs,
        newSubs: [_sub(2, 2.0), _sub(1, 2.5)],
        currentIndex: 1,
      ),
      0,
    );

    // If the selected frame vanished, choose the sharpest new frame rather
    // than reusing index 1 for an unrelated capture.
    expect(
      reconcileFieldQualityIndex(
        oldSubs: oldSubs,
        newSubs: [_sub(8, 3.1), _sub(9, 1.7)],
        currentIndex: 1,
      ),
      1,
    );
  });
}
