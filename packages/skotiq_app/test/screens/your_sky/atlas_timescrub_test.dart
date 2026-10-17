import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/widgets/atlas_timescrub.dart';
import 'package:skotiq_core/skotiq_core.dart';

SkyAtlasFoldRow _fold({
  required int id,
  required int tileId,
  required DateTime foldedAt,
}) {
  return SkyAtlasFoldRow(
    id: id,
    tileId: tileId,
    healpixOrder: 9,
    foldedAt: foldedAt,
    framesAdded: 1,
    weightAdded: 1.0,
    integrationSecondsAdded: 300.0,
    rejected: 0,
    contributor: '',
    label: 'session',
  );
}

void main() {
  group('scrubStopsFromFolds', () {
    test('one stop per distinct instant, ascending', () {
      final t1 = DateTime.utc(2026, 6, 1, 22);
      final t2 = DateTime.utc(2026, 6, 3, 21);
      final t3 = DateTime.utc(2026, 6, 5, 23);
      // Out-of-order, with a same-instant batch (two tiles folded at t2).
      final folds = [
        _fold(id: 1, tileId: 10, foldedAt: t3),
        _fold(id: 2, tileId: 11, foldedAt: t1),
        _fold(id: 3, tileId: 12, foldedAt: t2),
        _fold(id: 4, tileId: 13, foldedAt: t2),
      ];

      final stops = scrubStopsFromFolds(folds);

      expect(stops, [t1, t2, t3]);
    });

    test('empty timeline yields no stops', () {
      expect(scrubStopsFromFolds(const []), isEmpty);
    });

    test('normalizes mixed-zone instants to UTC', () {
      final local = DateTime(2026, 6, 1, 22);
      final folds = [_fold(id: 1, tileId: 10, foldedAt: local)];
      final stops = scrubStopsFromFolds(folds);
      expect(stops.single.isUtc, isTrue);
      expect(stops.single, local.toUtc());
    });
  });
}
