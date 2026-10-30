import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/frame_science_selection.dart';

typedef _Row = ({int? image, int seconds});

List<_Row> _select(List<_Row> rows, [int? image]) => selectFrameScienceRows(
      rows,
      capturedImageId: image,
      imageIdOf: (row) => row.image,
      timestampOf: (row) =>
          DateTime.fromMillisecondsSinceEpoch(row.seconds * 1000),
    );

void main() {
  test('prefers all matching rows over a more recent frame', () {
    const rows = [
      (image: 1, seconds: 10),
      (image: 2, seconds: 20),
      (image: 1, seconds: 11)
    ];
    expect(_select(rows, 1), [rows[0], rows[2]]);
  });
  test('missing or unknown current frame selects latest timestamp, not ID', () {
    const rows = [
      (image: 9, seconds: 10),
      (image: 2, seconds: 30),
      (image: 2, seconds: 20),
      (image: null, seconds: 99)
    ];
    for (final id in [null, 42]) {
      expect(_select(rows, id), [rows[1], rows[2]]);
    }
  });
  test('timestamp ties retain first encountered frame even with unsorted rows',
      () {
    const rows = [
      (image: 1, seconds: 10),
      (image: 2, seconds: 30),
      (image: 1, seconds: 30)
    ];
    expect(_select(rows), [rows[0], rows[2]]);
  });
  test('empty and entirely unassociated measurements remain usable', () {
    expect(_select([]), isEmpty);
    const rows = [(image: null, seconds: 1), (image: null, seconds: 2)];
    expect(_select(rows, 42), same(rows));
  });
}
