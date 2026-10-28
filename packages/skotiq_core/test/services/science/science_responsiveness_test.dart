import 'dart:async';
import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';
import 'package:skotiq_core/src/services/science/default_science_backend.dart';
import 'package:skotiq_core/src/models/science/science_models.dart';
import 'package:skotiq_core/src/services/science/photometric_catalog_service.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import '../../harness/in_memory_database.dart';

class _Native extends Mock implements RustLibApi {}

class _Capture extends Mock implements CapturedImageResult {}

class _Catalog extends Mock implements PhotometricCatalogService {}

class _MeasuredBackend extends DefaultScienceBackend {
  _MeasuredBackend(
    super.ref, {
    this.stars = const [
      StarMeasurement(
        x: 50,
        y: 40,
        flux: 1000,
        hfr: 2,
        fwhm: 4,
        snr: 20,
        eccentricity: .2,
        sharpness: .4,
        background: 100,
        peak: 2000,
      ),
    ],
  });
  final List<StarMeasurement> stars;
  @override
  Future<List<StarMeasurement>> measureStars(
    String path,
    PhotometryOptions options,
  ) async => stars;
}

void main() {
  final native = _Native();
  setUpAll(() => RustLib.initMock(api: native));
  tearDownAll(RustLib.dispose);
  setUp(() => reset(native));
  test(
    'PSF maps read only image geometry, without generating a full display image',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'science-header-',
      );
      addTearDown(() => directory.delete(recursive: true));
      String card(String key, String value) =>
          '${key.padRight(8)}= ${value.padLeft(20)}'.padRight(80);
      final path = '${directory.path}/frame.fits';
      await File(path).writeAsString(
        (card('SIMPLE', 'T') +
                card('BITPIX', '16') +
                card('NAXIS', '2') +
                card('NAXIS1', '100') +
                card('NAXIS2', '80') +
                'END'.padRight(80))
            .padRight(2880),
      );
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceBackendProvider.overrideWith((ref) => _MeasuredBackend(ref)),
        ],
      );
      addTearDown(container.dispose);
      final map = await container
          .read(scienceBackendProvider)
          .buildPsfFieldMap(
            path,
            null,
            const PsfMapOptions(gridRows: 2, gridCols: 2),
          );
      expect(map.tiles.where((t) => t.starCount > 0).single.medianFwhm, 4);
      verifyNever(
        () => native.crateApiImagingApiReadFitsFile(
          filePath: any(named: 'filePath'),
        ),
      );
    },
  );

  test(
    'catalog workers retain matched astrometric residuals without display pixels',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'science-catalog-',
      );
      addTearDown(() => directory.delete(recursive: true));
      String card(String key, String value) =>
          '${key.padRight(8)}= ${value.padLeft(20)}'.padRight(80);
      final path = '${directory.path}/frame.fits';
      await File(path).writeAsString(
        (card('SIMPLE', 'T') +
                card('BITPIX', '16') +
                card('NAXIS', '2') +
                card('NAXIS1', '100') +
                card('NAXIS2', '80') +
                'END'.padRight(80))
            .padRight(2880),
      );
      final projection = GnomonicProjection(
        const SolvedWcs(
          raHours: 2,
          decDegrees: 42,
          pixelScaleArcsec: 1.5,
          rotationDeg: 0,
          imageWidth: 100,
          imageHeight: 80,
        ),
      );
      final stars = <StarMeasurement>[];
      final catalogStars = <PhotometricCatalogStar>[];
      for (final x in [20.0, 50.0, 80.0]) {
        for (final y in [15.0, 40.0, 65.0]) {
          stars.add(
            StarMeasurement(
              x: x,
              y: y,
              flux: 1000,
              hfr: 2,
              fwhm: 4,
              snr: 20,
              eccentricity: .2,
              sharpness: .4,
              background: 100,
              peak: 2000,
            ),
          );
          final sky = projection.pixelToWorld(x: x + .5, y: y);
          catalogStars.add(
            PhotometricCatalogStar(
              raDegrees: sky.raDegrees,
              decDegrees: sky.decDegrees,
              magV: 12,
            ),
          );
        }
      }
      final catalog = _Catalog();
      when(
        () => catalog.coneSearch(
          raDegrees: any(named: 'raDegrees'),
          decDegrees: any(named: 'decDegrees'),
          radiusDegrees: any(named: 'radiusDegrees'),
          maxMagnitude: any(named: 'maxMagnitude'),
        ),
      ).thenAnswer(
        (_) async => PhotometricConeResult(
          source: PhotometricCatalogSource.localApass,
          stars: catalogStars,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          scienceBackendProvider.overrideWith(
            (ref) => _MeasuredBackend(ref, stars: stars),
          ),
          photometricCatalogServiceProvider.overrideWith((ref) => catalog),
        ],
      );
      addTearDown(container.dispose);
      final map = await container
          .read(scienceBackendProvider)
          .computeAstrometricResiduals(
            path,
            const WcsSolution(
              raHours: 2,
              decDegrees: 42,
              pixelScaleArcsecPerPixel: 1.5,
              rotationDegrees: 0,
              fieldWidthDegrees: .05,
              fieldHeightDegrees: .04,
              solverId: 'fixture',
            ),
            const AstrometryOptions(),
          );
      expect(map, isNotNull);
      expect(map!.vectors, hasLength(9));
      expect(map.rmsArcsec, closeTo(.75, 1e-6));
      verifyNever(
        () => native.crateApiImagingApiReadFitsFile(
          filePath: any(named: 'filePath'),
        ),
      );
    },
  );

  test(
    'line ratios keep the event loop responsive and retain physical ratios',
    () async {
      final source = Float64List.fromList(
        List.generate(
          512 * 512,
          (i) => 100.0 + (i % 11) + (i % 10 == 0 ? 1000.0 : 0.0),
        ),
      );
      when(
        () => native.crateApiImagingApiReadFitsLinearData(
          filePath: any(named: 'filePath'),
        ),
      ).thenAnswer((call) async {
        final path = call.namedArguments[#filePath];
        final scale = path == 'Ha'
            ? 1.0
            : path == 'OIII'
            ? 2.0
            : .5;
        return FitsLinearReadResult(
          width: 512,
          height: 512,
          bitpix: -64,
          exposureTime: 60,
          linearData: Float64List.fromList(
            source.map((v) => v * scale).toList(),
          ),
        );
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var yielded = false;
      Timer.run(() => yielded = true);
      final product = await container
          .read(scienceBackendProvider)
          .computeLineRatios(
            const NarrowbandSet(
              hAlphaPath: 'Ha',
              oiiiPath: 'OIII',
              siiPath: 'SII',
            ),
            const LineRatioOptions(continuumCorrection: false),
          );
      expect(
        product.metrics.map((m) => m.value),
        orderedEquals([.5, 2.0, .25]),
      );
      expect(product.previewImage, isNotEmpty);
      expect(
        yielded,
        isTrue,
        reason: 'Line-ratio pixels must be processed off the UI isolate',
      );
    },
  );

  test('line-ratio input errors survive the worker boundary', () async {
    var mismatched = true;
    when(
      () => native.crateApiImagingApiReadFitsLinearData(
        filePath: any(named: 'filePath'),
      ),
    ).thenAnswer(
      (call) async => FitsLinearReadResult(
        width: mismatched && call.namedArguments[#filePath] == 'Ha' ? 2 : 1,
        height: 1,
        bitpix: -64,
        linearData: Float64List.fromList([100]),
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    Future<LineRatioProduct> run() => container
        .read(scienceBackendProvider)
        .computeLineRatios(
          const NarrowbandSet(
            hAlphaPath: 'Ha',
            oiiiPath: 'OIII',
            siiPath: 'SII',
          ),
          const LineRatioOptions(),
        );
    await expectLater(
      run(),
      throwsA(
        isA<LineRatioError>().having(
          (error) => error.code,
          'code',
          LineRatioErrorCode.dimensionMismatch,
        ),
      ),
    );
    mismatched = false;
    await expectLater(
      run(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('exposure'),
        ),
      ),
    );
  });

  test('live quality fallback accepts the camera uint16 buffer', () async {
    when(
      () => native.crateApiImagingApiComputeLastCaptureQualityMaps(
        deviceId: any(named: 'deviceId'),
        gridRows: any(named: 'gridRows'),
        gridCols: any(named: 'gridCols'),
        lowClipAdu: any(named: 'lowClipAdu'),
        highClipAdu: any(named: 'highClipAdu'),
      ),
    ).thenAnswer(
      (_) async => throw StateError('native computation unavailable'),
    );
    final capture = _Capture();
    when(() => capture.width).thenReturn(64);
    when(() => capture.height).thenReturn(64);
    when(
      () => native.crateApiImagingApiGetLastImage(deviceId: 'camera'),
    ).thenAnswer((_) async => capture);
    when(
      () => native.crateApiImagingApiGetLastRawImageData(deviceId: 'camera'),
    ).thenAnswer((_) async => Uint16List.fromList(List.filled(64 * 64, 1050)));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final (frame, tiles) = await container
        .read(scienceBackendProvider)
        .computeLastCaptureQualityMaps(
          deviceId: 'camera',
          gridRows: 2,
          gridCols: 2,
          lowClipAdu: 0,
          highClipAdu: 65535,
          timestamp: DateTime.utc(2026),
          capturedImageId: 42,
          sessionId: 7,
        );
    expect(frame.mean, 1050);
    expect(frame.processingTier, 'live');
    expect(frame.capturedImageId, 42);
    expect(tiles, isNotEmpty);
  });

  test('FITS quality fallback keeps the event loop responsive', () async {
    when(
      () => native.crateApiImagingApiComputeFitsQualityMaps(
        filePath: any(named: 'filePath'),
        gridRows: any(named: 'gridRows'),
        gridCols: any(named: 'gridCols'),
        lowClipAdu: any(named: 'lowClipAdu'),
        highClipAdu: any(named: 'highClipAdu'),
      ),
    ).thenAnswer(
      (_) async => throw StateError('native computation unavailable'),
    );
    final pixels = Float64List.fromList(
      List.generate(1024 * 1024, (i) => 1000.0 + (i * 17 % 101)),
    );
    when(
      () => native.crateApiImagingApiReadFitsLinearData(
        filePath: any(named: 'filePath'),
      ),
    ).thenAnswer(
      (_) async => FitsLinearReadResult(
        width: 1024,
        height: 1024,
        bitpix: -64,
        linearData: pixels,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final backend = container.read(scienceBackendProvider);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    addTearDown(timer.cancel);
    final watch = Stopwatch()..start();
    final (frame, tiles) = await backend.computeFitsQualityMaps(
      filePath: '/fixture.fits',
      gridRows: 12,
      gridCols: 16,
      lowClipAdu: 0,
      highClipAdu: 65535,
      timestamp: DateTime.utc(2026),
      capturedImageId: 42,
      sessionId: 7,
    );
    timer.cancel();
    printOnFailure(
      'Quality fallback: ${watch.elapsedMilliseconds} ms; event-loop ticks=$ticks',
    );
    expect(frame.capturedImageId, 42);
    expect(frame.background, closeTo(1050, 1));
    expect(tiles, isNotEmpty);
    expect(
      ticks,
      greaterThan(0),
      reason: 'Science must yield the UI event loop during pixel analysis',
    );
  });
}
