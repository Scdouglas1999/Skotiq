import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/providers/darkroom_autopilot/dawn_autopilot_providers.dart';
import 'package:skotiq_core/src/providers/science/photometric_catalog_service_provider.dart';

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
  test('default Darkroom photometry searches the deep catalog around the '
      "master's centre", () async {
    final wcs = SolvedWcs.tryFromFits(
      crval1: 35.6336,
      crval2: 42.3604,
      crpix1: 2257,
      crpix2: 1651,
      cd1_1: 0.0002037,
      cd1_2: 0.00001,
      cd2_1: 0.00001,
      cd2_2: -0.0002037,
      imageWidth: 4514,
      imageHeight: 3301,
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
            masterFitsPath: '/masters/ngc891.fits',
            channels: 3,
            width: 4514,
            height: 3301,
            frameCount: 490,
            totalIntegrationSeconds: 58800,
          ),
          wcs: wcs,
        );
    expect(result.hasStars, isTrue, reason: result.unavailableReason);
    // The cone is centered on the image, half a pixel from CRPIX here.
    expect(catalog.requests.single[0], closeTo(35.6336, 2e-4));
    expect(catalog.requests.single[1], closeTo(42.3604, 2e-4));
    expect(result.stars.single, {
      'raDeg': 35.63,
      'decDeg': 42.36,
      'vMag': 13.4,
      'bMinusV': 0.65,
    });
  });
}
