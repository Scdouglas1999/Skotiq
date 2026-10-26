import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _Catalog extends PhotometricCatalogService {
  _Catalog(super.ref);
  final requests = <List<double>>[];
  @override
  Future<PhotometricConeResult> coneSearch({
    required double raDegrees,
    required double decDegrees,
    required double radiusDegrees,
    double maxMagnitude = 16.0,
  }) async {
    requests.add([raDegrees, decDegrees, radiusDegrees, maxMagnitude]);
    return const PhotometricConeResult(
      source: PhotometricCatalogSource.localApass,
      stars: [
        PhotometricCatalogStar(
          raDegrees: 35.63,
          decDegrees: 42.36,
          magV: 13.4,
          colorIndexBv: 0.65,
        ),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'default Darkroom photometry reads FITS WCS and uses the deep catalog',
    () async {
      final dir = await Directory.systemTemp.createTemp('darkroom-wcs-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/master.fits');
      final cards = <String, String>{
        'SIMPLE': 'T',
        'BITPIX': '-32',
        'NAXIS': '3',
        'NAXIS1': '4514',
        'NAXIS2': '3301',
        'NAXIS3': '3',
        'CRVAL1': '35.6336',
        'CRVAL2': '42.3604',
        'CRPIX1': '2257',
        'CRPIX2': '1651',
        'CD1_1': '0.0002037',
        'CD1_2': '0.00001',
        'CD2_1': '0.00001',
        'CD2_2': '-0.0002037',
      };
      final header =
          '${cards.entries.map((e) => '${e.key.padRight(8)}= ${e.value}'.padRight(80)).join()}${'END'.padRight(80)}';
      await file.writeAsString(
        header.padRight(((header.length + 2879) ~/ 2880) * 2880),
      );
      late _Catalog catalog;
      final container = ProviderContainer(
        overrides: [
          photometricCatalogServiceProvider.overrideWith(
            (ref) => catalog = _Catalog(ref),
          ),
        ],
      );
      addTearDown(container.dispose);
      final result = await container
          .read(dawnPhotometryResolverProvider)
          .resolve(
            master: DawnMaster(
              masterId: 1,
              targetId: null,
              name: 'NGC891 RGB',
              filter: 'RGB',
              masterFitsPath: file.path,
              channels: 3,
              width: 4514,
              height: 3301,
              frameCount: 490,
              totalIntegrationSeconds: 58800,
            ),
            wcs: null,
          );
      expect(result.hasStars, isTrue, reason: result.unavailableReason);
      expect(catalog.requests.single[0], closeTo(35.6336, 1e-7));
      expect(catalog.requests.single[1], closeTo(42.3604, 1e-7));
      expect(result.stars.single, {
        'raDeg': 35.63,
        'decDeg': 42.36,
        'vMag': 13.4,
        'bMinusV': 0.65,
      });
    },
  );
}
