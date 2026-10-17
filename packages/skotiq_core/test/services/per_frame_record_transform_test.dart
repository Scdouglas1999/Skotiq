import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

/// The per-sub registration transform surfaced by the native integrate pass is
/// the input the drizzle flow needs. These tests pin the seam-boundary decode:
/// `PerFrameRecord.fromJson` lifts the native `transform` (row-major 9-element
/// array) + `transformKind` token, and round-trips them through `toJson`.
void main() {
  group('PerFrameRecord transform decode', () {
    test(
      'decodes the row-major 9-element transform + kind from native JSON',
      () {
        final record = PerFrameRecord.fromJson(<String, dynamic>{
          'path': '/l/a.fits',
          'weight': 0.9,
          'rmsResidualPx': 0.4,
          'accepted': true,
          'reason': null,
          'snr': 42.0,
          'fwhm': 2.5,
          'eccentricity': 0.3,
          // Native sends ints/doubles mixed; decode must coerce to double.
          'transform': [1, 0.0, 5, 0, 1.0, -3, 0, 0, 1],
          'transformKind': 'affine',
        });

        expect(record.transform, isNotNull);
        expect(record.transform, hasLength(9));
        expect(record.transform![0], 1.0);
        expect(record.transform![2], 5.0);
        expect(record.transform![5], -3.0);
        // The decoded list is statically typed double — `5` (an int in JSON) was
        // coerced, not left as a dynamic int.
        expect(record.transform, isA<List<double>>());
        expect(record.transformKind, 'affine');
      },
    );

    test('a sub that failed registration carries a null transform', () {
      final record = PerFrameRecord.fromJson(<String, dynamic>{
        'path': '/l/bad.fits',
        'weight': 0.0,
        'rmsResidualPx': null,
        'accepted': false,
        'reason': 'registration failed: too few stars',
      });

      expect(record.accepted, isFalse);
      expect(record.transform, isNull);
      expect(record.transformKind, isNull);
    });

    test(
      'toJson omits the transform keys when null, includes them when set',
      () {
        const without = PerFrameRecord(
          path: '/l/a.fits',
          weight: 1.0,
          rmsResidualPx: 0.4,
          accepted: true,
          reason: null,
        );
        expect(without.toJson().containsKey('transform'), isFalse);
        expect(without.toJson().containsKey('transformKind'), isFalse);

        const with9 = PerFrameRecord(
          path: '/l/a.fits',
          weight: 1.0,
          rmsResidualPx: 0.4,
          accepted: true,
          reason: null,
          transform: [1, 0, 2, 0, 1, 0, 0, 0, 1],
          transformKind: 'similarity',
        );
        final json = with9.toJson();
        expect(json['transform'], [1, 0, 2, 0, 1, 0, 0, 0, 1]);
        expect(json['transformKind'], 'similarity');
      },
    );

    test(
      'IntegrateSessionResult.fromJson threads the transform through frames',
      () {
        final result = IntegrateSessionResult.fromJson(<String, dynamic>{
          'masterFitsPath': '/out/master.fits',
          'previewPath': null,
          'rejectionMapPath': null,
          'framesIntegrated': 2,
          'framesRejected': 0,
          'totalIntegrationSec': 240.0,
          'rmsResidual': 0.4,
          'width': 100,
          'height': 80,
          'channels': 1,
          'perFrameStats': [
            {
              'path': '/l/a.fits',
              'weight': 1.0,
              'accepted': true,
              'transform': [1, 0, 0, 0, 1, 0, 0, 0, 1],
              'transformKind': 'similarity',
            },
            {
              'path': '/l/b.fits',
              'weight': 0.95,
              'accepted': true,
              'transform': [1, 0, 4, 0, 1, -2, 0, 0, 1],
              'transformKind': 'similarity',
            },
          ],
        });

        expect(result.perFrameStats, hasLength(2));
        expect(result.perFrameStats[0].transform![0], 1.0);
        expect(result.perFrameStats[1].transform![2], 4.0);
        expect(result.perFrameStats[1].transform![5], -2.0);
      },
    );
  });
}
