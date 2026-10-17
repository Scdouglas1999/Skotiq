// Tests for the shared-calibration-library headless handlers
// (match / accept / publish / retract) — the remote-client (tablet → appliance)
// path for Collaborative Sky shared calibration.
//
// The underlying `CalibrationLibraryService` logic is covered in
// skotiq_core; here we exercise the HANDLER SEAM the prior suite never
// touched: body decode, the accept `isRemote` gate, the publish fail-closed
// license parse + consent construction, the 404-on-missing-record branches, the
// StateError → 400 mapping, and the happy-path response shapes the
// `calibration_library_settings.dart` UI consumes. The service is replaced with
// a fake so each seam is asserted in isolation.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/calibration_library_handlers.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

/// A [CalibrationLibraryService] whose share/match methods are replaced with
/// scriptable stubs, so the handler seam can be asserted without a hub or a
/// populated library. Its [getRecord] backs both the publish/retract 404 branch
/// and the happy paths.
class _FakeCalibrationLibraryService extends CalibrationLibraryService {
  _FakeCalibrationLibraryService(SkotiqDatabase db)
    : super(
        db: db,
        flatLibraryDao: FlatLibraryDao(db),
        tagsDao: CalibrationTagsDao(db),
      );

  CalibrationMasterRecord? record;
  CalibrationMatchSet Function(LightFrameContext context)? onMatch;
  RemoteMasterAcceptance Function(CalibrationMasterRecord remote)? onAccept;
  SharedCalibrationMaster Function(
    CalibrationMasterRecord record,
    ContributionConsent consent,
    Provenance provenance,
  )?
  onPublish;
  void Function(CalibrationMasterRecord record)? onRetract;

  /// The consent the last publish was invoked with (asserts the fail-closed
  /// license parse).
  ContributionConsent? lastConsent;

  @override
  Future<CalibrationMatchSet> match(
    LightFrameContext context, {
    CalibrationMatchTolerances tolerances = CalibrationMatchTolerances.defaults,
    bool includeRemote = true,
  }) async => (onMatch ?? (c) => CalibrationMatchSet(context: c))(context);

  @override
  Future<CalibrationMasterRecord?> getRecord(
    CalibrationMasterType type,
    int id,
  ) async => record;

  @override
  Future<RemoteMasterAcceptance> acceptRemoteMaster(
    CalibrationMasterRecord remote,
  ) async =>
      (onAccept ?? (r) => RemoteMasterAcceptance.merged(1, '/x.fits'))(remote);

  @override
  Future<SharedCalibrationMaster> publishMaster(
    CalibrationMasterRecord record, {
    required ContributionConsent consent,
    Provenance provenance = const Provenance(),
  }) async {
    lastConsent = consent;
    // Mirror the real service's consent gate so a fail-closed (private) license
    // surfaces the same StateError → 400 the handler maps.
    if (!consent.permitsSharing) {
      throw StateError(
        'consent does not permit sharing (license ${consent.license.wireName})',
      );
    }
    final fn = onPublish;
    if (fn != null) return fn(record, consent, provenance);
    return _master(record, consent.license, frameCount: record.frameCount ?? 0);
  }

  @override
  Future<void> retractPublishedMaster(CalibrationMasterRecord record) async =>
      onRetract?.call(record);

  static SharedCalibrationMaster _master(
    CalibrationMasterRecord record,
    ContributionLicense license, {
    int frameCount = 0,
  }) => SharedCalibrationMaster(
    id: 'hub-master-1',
    accountId: 'acct-1',
    masterType: calibrationMasterTypeWireName(record.type),
    cameraModel: record.cameraId ?? 'ASI2600MM',
    sensorWidth: record.width ?? 64,
    sensorHeight: record.height ?? 48,
    gain: record.gain ?? 0,
    offset: record.offset ?? 0,
    exposureSeconds: record.exposureSeconds ?? 0,
    binX: record.binX,
    binY: record.binY,
    frameCount: frameCount,
    license: license,
    provenance: const Provenance(),
    bytes: 0,
    createdAt: DateTime.utc(2026),
  );
}

CalibrationMasterRecord _localDark({int id = 7}) => CalibrationMasterRecord(
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

Map<String, dynamic> _remoteDarkJson() => {
  'type': 'dark',
  'id': 0,
  'isMaster': true,
  'gain': 100,
  'offset': 50,
  'binX': 1,
  'binY': 1,
  'width': 64,
  'height': 48,
  'cameraId': 'ASI2600MM',
  'createdAt': DateTime.utc(2026).toIso8601String(),
  'remoteId': 'hub-master-9',
  'license': 'cc-by',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CalibrationLibraryHandlers — share seam', () {
    late ProviderContainer container;
    late SkotiqDatabase db;
    late _FakeCalibrationLibraryService service;
    late CalibrationLibraryHandlers handlers;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      service = _FakeCalibrationLibraryService(db);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          calibrationLibraryServiceProvider.overrideWithValue(service),
        ],
      );
      handlers = CalibrationLibraryHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Request post(String path, Object body) => Request(
      'POST',
      Uri.parse('http://localhost$path'),
      body: jsonEncode(body),
    );

    Future<Map<String, dynamic>> bodyOf(Response r) async =>
        jsonDecode(await r.readAsString()) as Map<String, dynamic>;

    test(
      'GET list rejects malformed and contradictory query filters',
      () async {
        final cases = <({String query, String field})>[
          (query: 'type=unknown', field: 'type'),
          (query: 'gain=not-an-int', field: 'gain'),
          (query: 'binX=0', field: 'binX'),
          (query: 'exposureSeconds=NaN', field: 'exposureSeconds'),
          (query: 'exposureTolSecs=-1', field: 'exposureTolSecs'),
          (query: 'mastersOnly=sometimes', field: 'mastersOnly'),
          (query: 'offset=-1', field: 'offset'),
          (query: 'limit=0', field: 'limit'),
          (query: 'limit=1001', field: 'limit'),
          (query: 'tempMin=10&tempMax=-10', field: 'tempMin'),
        ];

        for (final testCase in cases) {
          final response = await translateHandlerErrors(
            handlers.handleList(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/calibration-library?${testCase.query}',
                ),
              ),
            ),
          );
          expect(
            response.statusCode,
            HttpStatus.badRequest,
            reason: testCase.query,
          );
          expect((await bodyOf(response))['field'], testCase.field);
        }
      },
    );

    test('DELETE rejects malformed deleteFile and non-positive ids', () async {
      final badBool = await translateHandlerErrors(
        handlers.handleDelete(
          Request(
            'DELETE',
            Uri.parse(
              'http://localhost/api/calibration-library/dark/7?deleteFile=maybe',
            ),
          ),
          'dark',
          '7',
        ),
      );
      expect(badBool.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(badBool))['field'], 'deleteFile');

      final badId = await translateHandlerErrors(
        handlers.handleDelete(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/calibration-library/dark/0'),
          ),
          'dark',
          '0',
        ),
      );
      expect(badId.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(badId))['field'], 'id');
    });

    // match

    test('POST match returns the transparent match set', () async {
      service.onMatch = (c) => CalibrationMatchSet(
        context: c,
        warnings: const ['No matching master dark'],
      );
      final response = await translateHandlerErrors(
        handlers.handleMatch(
          post('/api/calibration-library/match', {
            'gain': 100,
            'offset': 50,
            'exposureSeconds': 300.0,
            'cameraId': 'ASI2600MM',
          }),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await bodyOf(response);
      expect(body['warnings'], contains('No matching master dark'));
      expect((body['context'] as Map)['gain'], 100);
    });

    // accept

    test('POST accept rejects a non-remote record with 400', () async {
      // A record with no remoteId is local; accept must refuse before any
      // service call.
      final response = await translateHandlerErrors(
        handlers.handleAccept(
          post('/api/calibration-library/accept', _localDark().toJson()),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(response))['field'], 'remoteId');
    });

    test('POST accept returns the merge outcome shape on success', () async {
      service.onAccept = (r) => RemoteMasterAcceptance.merged(
        55,
        '/data/shared/dark_hub-master-9.fits',
      );
      final response = await translateHandlerErrors(
        handlers.handleAccept(
          post('/api/calibration-library/accept', _remoteDarkJson()),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await bodyOf(response);
      expect(body['kind'], 'merged');
      expect(body['mergedId'], 55);
      expect(body['filePath'], '/data/shared/dark_hub-master-9.fits');
    });

    test('POST accept maps a service StateError to 400', () async {
      service.onAccept = (r) =>
          throw StateError('no shared-master download directory is configured');
      final response = await translateHandlerErrors(
        handlers.handleAccept(
          post('/api/calibration-library/accept', _remoteDarkJson()),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(response))['error'], 'calibration_accept_failed');
    });

    // publish

    test('POST publish fails closed on an unknown license token', () async {
      // The record exists, but the license token is not recognized: the handler
      // must fall back to `private`, which the service then refuses (400).
      service.record = _localDark();
      final response = await translateHandlerErrors(
        handlers.handlePublish(
          post('/api/calibration-library/publish', {
            'type': 'dark',
            'id': 7,
            'license': 'totally-made-up-license',
          }),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(response))['error'], 'calibration_publish_failed');
      expect(
        service.lastConsent!.license,
        ContributionLicense.private,
        reason: 'an unknown license token fails closed to private',
      );
    });

    test('POST publish returns 404 when the master is missing', () async {
      service.record = null;
      final response = await translateHandlerErrors(
        handlers.handlePublish(
          post('/api/calibration-library/publish', {
            'type': 'dark',
            'id': 999,
            'license': 'cc-by',
          }),
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
      expect((await bodyOf(response))['error'], 'calibration_master_not_found');
    });

    test('POST publish returns the published shape on success', () async {
      service.record = _localDark();
      service.onPublish = (record, consent, provenance) =>
          _FakeCalibrationLibraryService._master(
            record,
            consent.license,
            frameCount: 40,
          );
      final response = await translateHandlerErrors(
        handlers.handlePublish(
          post('/api/calibration-library/publish', {
            'type': 'dark',
            'id': 7,
            'license': 'cc-by',
            'attributionName': 'Imager',
          }),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await bodyOf(response);
      expect(body['status'], 'published');
      expect(body['id'], 'hub-master-1');
      expect(body['masterType'], 'dark');
      expect(body['license'], 'cc-by');
      expect(body['frameCount'], 40);
      expect(
        service.lastConsent!.attributionName,
        'Imager',
        reason: 'consent carries the attribution name from the body',
      );
    });

    // retract

    test('POST retract returns 404 when the master is missing', () async {
      service.record = null;
      final response = await translateHandlerErrors(
        handlers.handleRetract(
          post('/api/calibration-library/retract', {'type': 'dark', 'id': 5}),
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
      expect((await bodyOf(response))['error'], 'calibration_master_not_found');
    });

    test('POST retract maps a service StateError to 400', () async {
      service.record = _localDark();
      service.onRetract = (r) =>
          throw StateError('this master has not been published to a hub');
      final response = await translateHandlerErrors(
        handlers.handleRetract(
          post('/api/calibration-library/retract', {'type': 'dark', 'id': 7}),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      expect((await bodyOf(response))['error'], 'calibration_retract_failed');
    });

    test('POST retract returns the retracted shape on success', () async {
      service.record = _localDark();
      var called = false;
      service.onRetract = (r) => called = true;
      final response = await translateHandlerErrors(
        handlers.handleRetract(
          post('/api/calibration-library/retract', {'type': 'dark', 'id': 7}),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await bodyOf(response);
      expect(body['status'], 'retracted');
      expect(body['type'], 'dark');
      expect(body['id'], 7);
      expect(called, isTrue);
    });
  });

  group('CalibrationLibraryHandlers — route scopes', () {
    test('share POSTs are control scope', () {
      for (final path in const [
        '/api/calibration-library/match',
        '/api/calibration-library/accept',
        '/api/calibration-library/publish',
        '/api/calibration-library/retract',
      ]) {
        expect(
          requiredAuthScopeNameForEndpoint(method: 'POST', path: path),
          'control',
          reason: '$path POST must be control scope',
        );
      }
    });

    test('the share surface is tagged to the calibration resource', () {
      expect(
        resourceKeyForEndpoint(
          method: 'POST',
          path: '/api/calibration-library/publish',
        ),
        'calibration',
      );
    });
  });
}
