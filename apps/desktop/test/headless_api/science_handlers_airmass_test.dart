// The airmass the REMOTE half of the photometric-calibration wizard fits on.
//
// A tablet or phone paired to a headless host does not run the in-app wizard —
// it POSTs to /api/science/calibration/image/<id>/match-stars and this handler
// computes the per-frame airmass that the returned matches carry into the
// extinction fit. It must answer from the shared model, and a frame with no
// recorded altitude must have no airmass: an invented X = 1.0 claims a zenith
// observation, drags the extinction slope toward zero, and the wrong k then
// rides along in every magnitude the saved transform standardizes.
//
// These drive the real handler through a real database and assert on the
// response, so cutting its call to the shared model breaks them.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/science_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// Reports enough stars to clear the handler's 4-star gate, then refuses to
/// calibrate. Refusing is deliberate: a successful match needs a loaded HYG
/// catalog and a native FITS read, and the airmass decision happens before
/// either. Stopping at calibration gives a stable, assertable outcome that
/// still proves the frame got PAST the airmass gate.
class _StubScienceBackend extends Mock implements ScienceBackend {
  @override
  Future<List<StarMeasurement>> measureStars(
    String imagePath,
    PhotometryOptions options,
  ) async => List.generate(
    8,
    (i) => StarMeasurement(
      x: 100.0 + i * 20,
      y: 100.0 + i * 15,
      flux: 20000.0 - i * 500,
      hfr: 2.4,
      fwhm: 3.1,
      snr: 60.0 - i,
      eccentricity: 0.2,
      sharpness: 0.5,
      background: 120.0,
      peak: 9000.0,
    ),
  );

  @override
  Future<FramePhotometricCalibration?> calibrateFramePhotometry(
    String imagePath,
    WcsSolution wcs,
    PhotometricCatalogSource catalog,
    ScienceFrameContext? frameContext,
  ) async => null;
}

void main() {
  late ProviderContainer container;
  late ScienceHandlers handlers;
  late SkotiqDatabase database;
  late Directory captures;

  setUp(() async {
    captures = await Directory.systemTemp.createTemp('match-stars-airmass');
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        scienceBackendProvider.overrideWithValue(_StubScienceBackend()),
      ],
    );
    handlers = ScienceHandlers(container);
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    if (captures.existsSync()) {
      captures.deleteSync(recursive: true);
    }
  });

  /// A plate-solved light frame that exists on disk, at [mountAltitude].
  Future<int> frameAtAltitude(String name, double? mountAltitude) async {
    final file = File('${captures.path}/$name');
    await file.writeAsBytes(const [0, 0, 0, 0], flush: true);
    final id = await database.imagesDao.insertSequenceFrame(
      filePath: file.path,
      fileName: name,
      fileFormat: 'fits',
      exposureDuration: 60.0,
      capturedAt: DateTime.utc(2026, 8, 1, 23, 30),
      isAccepted: true,
      producingNodeId: 'node-match',
      filter: 'V',
      mountAltitude: mountAltitude,
    );
    await database.imagesDao.updatePlateSolveResult(
      id,
      solvedRa: 5.5,
      solvedDec: -5.4,
      solvedRotation: 0.0,
      solvedPixelScale: 1.5,
    );
    return id;
  }

  Future<Response> matchStars(int imageId) => translateHandlerErrors(
    handlers.handleMatchPhotometricCalibrationStars(
      Request(
        'POST',
        Uri.parse(
          'http://localhost/api/science/calibration/image/$imageId/match-stars',
        ),
      ),
      '$imageId',
    ),
  );

  test(
    'a frame with no recorded altitude is refused, not called X = 1.0',
    () async {
      final response = await matchStars(
        await frameAtAltitude('noalt.fits', null),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['error'],
        contains('no recorded above-horizon mount altitude'),
      );
    },
  );

  test('a sub-horizon frame is refused too', () async {
    final response = await matchStars(await frameAtAltitude('set.fits', -3.5));

    expect(response.statusCode, HttpStatus.badRequest);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['error'], contains('no recorded above-horizon mount altitude'));
  });

  test('a real low-altitude frame passes the airmass gate', () async {
    // 4° is where the retired clamp(1, 8) bound; the shared model reads 11.897
    // there. The frame must reach calibration rather than be refused, which is
    // what distinguishes "the gate works" from "the gate rejects everything".
    expect(airmassForTrueAltitude(4.0), closeTo(11.897, 0.005));

    final response = await matchStars(await frameAtAltitude('low.fits', 4.0));

    final body = jsonDecode(await response.readAsString()) as Map;
    expect(
      body['error'],
      isNot(contains('no recorded above-horizon mount altitude')),
      reason: 'an above-horizon frame must not be refused for its airmass',
    );
    expect(body['error'], contains('calibration failed'));
  });
}
