// The REST status the host answers when a hub call fails, for the three
// handler families that reach a hub: shared calibration, co-imaging and
// collaborative mosaics.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_desktop/headless_api/handlers/calibration_library_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/coimaging_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/mosaic_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _CalibrationLibrary implements CalibrationLibraryService {
  _CalibrationLibrary(this.publish);

  final Future<SharedCalibrationMaster> Function() publish;

  @override
  Future<CalibrationMasterRecord?> getRecord(
    CalibrationMasterType type,
    int id,
  ) async => CalibrationMasterRecord(
    type: CalibrationMasterType.dark,
    id: id,
    filePath: '/lib/dark_$id.fits',
    isMaster: true,
    frameCount: 40,
    exposureSeconds: 300,
    gain: 100,
    offset: 50,
    width: 64,
    height: 48,
    cameraId: 'ASI2600MM',
    createdAt: DateTime.utc(2026),
  );

  @override
  Future<SharedCalibrationMaster> publishMaster(
    CalibrationMasterRecord record, {
    required ContributionConsent consent,
    Provenance provenance = const Provenance(),
  }) => publish();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CoImaging implements CoImagingSessionService {
  _CoImaging(this.error);

  final Object error;

  @override
  Future<List<CoImagingSession>> listSessions() async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Mosaics implements CollaborativeMosaicService {
  _Mosaics(this.error);

  final Object error;

  @override
  Future<CollabMosaic> publishProject(int projectId) async => throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConstellationException _failure(ConstellationErrorKind kind, {int? status}) =>
    ConstellationException('hub said no', kind: kind, statusCode: status);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<int> publishCalibration(
    Future<SharedCalibrationMaster> Function() publish,
  ) async {
    final container = ProviderContainer(
      overrides: [
        calibrationLibraryServiceProvider.overrideWithValue(
          _CalibrationLibrary(publish),
        ),
      ],
    );
    addTearDown(container.dispose);
    final response = await translateHandlerErrors(
      CalibrationLibraryHandlers(container).handlePublish(
        Request(
          'POST',
          Uri.parse('http://localhost/api/calibration-library/publish'),
          body: jsonEncode({'type': 'dark', 'id': 7, 'license': 'cc-by'}),
        ),
      ),
    );
    return response.statusCode;
  }

  Future<int> listCoImaging(Object error) async {
    final container = ProviderContainer(
      overrides: [
        coImagingSessionServiceProvider.overrideWithValue(_CoImaging(error)),
      ],
    );
    addTearDown(container.dispose);
    final response = await translateHandlerErrors(
      CoImagingHandlers(container).handleListSessions(
        Request('GET', Uri.parse('http://localhost/api/coimaging/sessions')),
      ),
    );
    return response.statusCode;
  }

  Future<int> publishMosaic(Object error) async {
    final container = ProviderContainer(
      overrides: [
        collaborativeMosaicServiceProvider.overrideWithValue(_Mosaics(error)),
      ],
    );
    addTearDown(container.dispose);
    final response = await translateHandlerErrors(
      MosaicHandlers(container).handlePublishCollaborative(
        Request(
          'POST',
          Uri.parse('http://localhost/api/mosaic/projects/3/publish'),
        ),
        '3',
      ),
    );
    return response.statusCode;
  }

  // Every kind but `unknown` answers the same status on every surface.
  const shared = <ConstellationErrorKind, int>{
    ConstellationErrorKind.network: 502,
    ConstellationErrorKind.server: 503,
    ConstellationErrorKind.auth: 401,
    ConstellationErrorKind.notFound: 404,
    ConstellationErrorKind.conflict: 409,
    ConstellationErrorKind.geometryMismatch: 409,
    ConstellationErrorKind.protocol: 400,
  };

  test('the kinds every surface shares answer one status', () async {
    for (final MapEntry(key: kind, value: status) in shared.entries) {
      final error = _failure(kind, status: 418);
      expect(
        await publishCalibration(() async => throw error),
        status,
        reason: 'calibration $kind',
      );
      expect(await listCoImaging(error), status, reason: 'coimaging $kind');
      expect(await publishMosaic(error), status, reason: 'mosaic $kind');
    }
  });

  test('an unknown hub failure keeps each surface\'s own fallback', () async {
    final withStatus = _failure(ConstellationErrorKind.unknown, status: 429);
    final bare = _failure(ConstellationErrorKind.unknown);
    expect(await publishCalibration(() async => throw withStatus), 502);
    expect(await publishCalibration(() async => throw bare), 502);
    expect(await listCoImaging(withStatus), 500);
    expect(await listCoImaging(bare), 500);
    expect(await publishMosaic(withStatus), 429);
    expect(await publishMosaic(bare), 502);
  });

  test('a calibration master the hub refuses as unprocessable is a request '
      'fault (400), not an unreachable hub', () async {
    final client = SharedCalibrationClient(
      hubBaseUrl: Uri.parse('https://hub.example.org'),
      bearerToken: 'tok',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'code': 'pixelSanity',
              'message': 'master pixels are not plausible',
            },
          }),
          422,
        ),
      ),
    );
    addTearDown(client.close);
    final dir = Directory.systemTemp.createTempSync('sk_hub_status_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final master = File('${dir.path}/dark.fits')..writeAsBytesSync([1, 2, 3]);

    final status = await publishCalibration(
      () => client.publishMaster(
        masterType: 'dark',
        cameraModel: 'ASI2600MM',
        license: ContributionLicense.ccBy,
        filePath: master.path,
        provenance: const Provenance(),
        sensorWidth: 64,
        sensorHeight: 48,
        exposureSeconds: 300,
        frameCount: 40,
      ),
    );
    expect(status, HttpStatus.badRequest);
  });
}
