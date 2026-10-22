// Tests for the headless calibration handlers.
//
// These tests exercise the dark library, flat history, and defect map
// REST surface end-to-end. We use an in-memory Drift database for
// realistic DB interactions and a temp directory standing in for
// `$DATA_DIR/calibration/`.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/calibration_handlers.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockDefectMapService extends Mock implements DefectMapService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CalibrationHandlers', () {
    late ProviderContainer container;
    late SkotiqDatabase db;
    late CalibrationHandlers handlers;
    late _MockDefectMapService defectMapService;
    late Directory tempDir;
    late Directory calibrationDir;
    late List<CalibrationMasterBuildRequest> builtRequests;

    setUp(() async {
      builtRequests = [];
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp(
        'sk_calibration_handlers_test_',
      );
      calibrationDir = Directory('${tempDir.path}/data');
      await calibrationDir.create(recursive: true);
      defectMapService = _MockDefectMapService();

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          defectMapServiceProvider.overrideWithValue(defectMapService),
          calibrationMasterBuildProvider.overrideWithValue((request) async {
            builtRequests.add(request);
            await File(request.outputPath).writeAsBytes(const [0]);
            return CalibrationMasterBuildResult(
              outputPath: request.outputPath,
              kind: request.kind,
              width: 4656,
              height: 3520,
              frameCount: request.framePaths.length,
              leakingFrames: const [],
              frameLevels: const [],
              leakBaseline: 233,
              leakThreshold: 5,
              masterMean: 233.4,
              rejectionFraction: 0.0017,
              exposureSecs: 90,
              gain: 76,
              offset: 15,
              binX: 1,
              binY: 1,
              ccdTempMean: -9.9,
              setTemp: -10,
            );
          }),
        ],
      );
      handlers = CalibrationHandlers(
        container,
        dataDirectoryOverride: () async => calibrationDir,
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> writeDarkFile(String name, {List<int>? bytes}) async {
      final file = File('${tempDir.path}/$name');
      await file.writeAsBytes(bytes ?? List<int>.generate(64, (i) => i % 256));
      return file;
    }

    Future<int> insertDark(
      File file, {
      double exposure = 60.0,
      int gain = 100,
      int offset = 10,
      double? temperature,
      String frameType = 'dark',
    }) async {
      return db.darkLibraryDao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: file.path,
          exposureTime: exposure,
          gain: Value(gain),
          offset: Value(offset),
          temperature: Value(temperature),
          frameType: Value(frameType),
        ),
      );
    }

    // GET /api/calibration/darks

    test('GET darks lists all entries with metadata', () async {
      final f1 = await writeDarkFile('a.fits');
      final f2 = await writeDarkFile('b.fits');
      await insertDark(f1, exposure: 60, gain: 100, temperature: -10);
      await insertDark(f2, exposure: 30, gain: 200, temperature: -15);

      final response = await translateHandlerErrors(
        handlers.handleListDarks(
          Request('GET', Uri.parse('http://localhost/api/calibration/darks')),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final darks = body['darks'] as List;
      expect(darks, hasLength(2));
      for (final dark in darks) {
        final m = dark as Map;
        expect(m['id'], isA<int>());
        expect(m['filePath'], isA<String>());
        expect(m['fileExists'], isTrue);
        expect(m['fileSize'], isA<int>());
        expect(m['fileSize'], greaterThan(0));
      }
    });

    test('GET darks filters by gain', () async {
      final f1 = await writeDarkFile('a.fits');
      final f2 = await writeDarkFile('b.fits');
      await insertDark(f1, gain: 100);
      await insertDark(f2, gain: 200);

      final response = await translateHandlerErrors(
        handlers.handleListDarks(
          Request(
            'GET',
            Uri.parse('http://localhost/api/calibration/darks?gain=200'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final darks = body['darks'] as List;
      expect(darks, hasLength(1));
      expect((darks.first as Map)['gain'], 200);
    });

    test('GET darks fileExists is false when file is gone', () async {
      final f = await writeDarkFile('orphan.fits');
      final id = await insertDark(f);
      await f.delete();

      final response = await translateHandlerErrors(
        handlers.handleGetDark(
          Request(
            'GET',
            Uri.parse('http://localhost/api/calibration/darks/$id'),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['dark'] as Map)['fileExists'], isFalse);
      expect((body['dark'] as Map)['fileSize'], isNull);
    });

    // POST /api/calibration/darks

    test('POST register dark with existing file returns 201', () async {
      final f = await writeDarkFile('register.fits');
      final body = jsonEncode({
        'filePath': f.path,
        'exposureDuration': 60.0,
        'gain': 120,
        'offset': 10,
        'binX': 1,
        'binY': 1,
        'sensorTempC': -20.0,
      });
      final response = await translateHandlerErrors(
        handlers.handleRegisterDark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks'),
            body: body,
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.created);
      final responseBody = jsonDecode(await response.readAsString()) as Map;
      final dark = responseBody['dark'] as Map;
      expect(dark['id'], isA<int>());
      expect(dark['gain'], 120);
      expect(dark['fileExists'], isTrue);
    });

    test('POST register dark with missing file returns 400', () async {
      final body = jsonEncode({
        'filePath': '${tempDir.path}/nonexistent.fits',
        'exposureDuration': 60.0,
      });
      final response = await translateHandlerErrors(
        handlers.handleRegisterDark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks'),
            body: body,
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      final responseBody = jsonDecode(await response.readAsString()) as Map;
      expect(responseBody['error'], 'dark_file_not_found');
    });

    // POST /api/calibration/darks/upload

    test('POST upload writes file and inserts row', () async {
      final payload = List<int>.generate(256, (i) => i % 256);
      final meta = jsonEncode({
        'exposureDuration': 120.0,
        'gain': 80,
        'offset': 5,
        'binX': 1,
        'binY': 1,
        'sensorTempC': -25.0,
        'frameType': 'dark',
      });

      final response = await translateHandlerErrors(
        handlers.handleUploadDark(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/calibration/darks/upload?meta=${Uri.encodeQueryComponent(meta)}&fileName=upload.fits',
            ),
            body: payload,
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.created);
      final responseBody = jsonDecode(await response.readAsString()) as Map;
      expect(responseBody['bytesWritten'], payload.length);
      final dark = responseBody['dark'] as Map;
      expect(dark['fileExists'], isTrue);
      final onDisk = File(dark['filePath'] as String);
      expect(await onDisk.exists(), isTrue);
      expect(await onDisk.length(), payload.length);
    });

    test('POST upload over content-length cap returns 413', () async {
      final meta = jsonEncode({'exposureDuration': 60.0});
      final response = await translateHandlerErrors(
        handlers.handleUploadDark(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/calibration/darks/upload?meta=${Uri.encodeQueryComponent(meta)}',
            ),
            headers: {
              'content-length': (backupUploadMaxRequestBodyBytes + 1)
                  .toString(),
            },
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.requestEntityTooLarge);
      final responseBody = jsonDecode(await response.readAsString()) as Map;
      expect(responseBody['maxBytes'], backupUploadMaxRequestBodyBytes);
    });

    // DELETE /api/calibration/darks/{id}

    test('DELETE removes row but keeps file by default', () async {
      final f = await writeDarkFile('keep.fits');
      final id = await insertDark(f);

      final response = await translateHandlerErrors(
        handlers.handleDeleteDark(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/calibration/darks/$id'),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['deleted'], isTrue);
      expect(body['fileDeleted'], isFalse);
      expect(await f.exists(), isTrue);
      expect(await db.darkLibraryDao.getEntryById(id), isNull);
    });

    test('DELETE with deleteFile=true also deletes the file', () async {
      final f = await writeDarkFile('wipe.fits');
      final id = await insertDark(f);

      final response = await translateHandlerErrors(
        handlers.handleDeleteDark(
          Request(
            'DELETE',
            Uri.parse(
              'http://localhost/api/calibration/darks/$id?deleteFile=true',
            ),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['deleted'], isTrue);
      expect(body['fileDeleted'], isTrue);
      expect(await f.exists(), isFalse);
    });

    test('DELETE unknown id returns 404', () async {
      final response = await translateHandlerErrors(
        handlers.handleDeleteDark(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/calibration/darks/99999'),
          ),
          '99999',
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
    });

    // POST /api/calibration/darks/find-match

    test('POST find-match returns closest matching dark', () async {
      final f1 = await writeDarkFile('m1.fits');
      final f2 = await writeDarkFile('m2.fits');
      await insertDark(
        f1,
        exposure: 60.0,
        gain: 100,
        offset: 10,
        temperature: -10,
      );
      final wantedId = await insertDark(
        f2,
        exposure: 60.0,
        gain: 100,
        offset: 10,
        temperature: -19.5,
      );

      final response = await translateHandlerErrors(
        handlers.handleFindMatchingDark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/find-match'),
            body: jsonEncode({
              'exposureDuration': 60.0,
              'gain': 100,
              'offset': 10,
              'binX': 1,
              'binY': 1,
              'sensorTempC': -20.0,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['dark'] as Map)['id'], wantedId);
    });

    test('POST find-match returns 404 when nothing matches', () async {
      final response = await translateHandlerErrors(
        handlers.handleFindMatchingDark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/find-match'),
            body: jsonEncode({
              'exposureDuration': 30.0,
              'gain': 999,
              'offset': 0,
              'binX': 1,
              'binY': 1,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.notFound);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'no_matching_dark');
    });

    // POST /api/calibration/darks/backfill-sizes

    test('POST backfill-sizes returns coverage report', () async {
      final f1 = await writeDarkFile('present.fits');
      final f2 = await writeDarkFile('absent.fits');
      await insertDark(f1);
      await insertDark(f2);
      await f2.delete();

      final response = await translateHandlerErrors(
        handlers.handleVerifyDarkSizes(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/backfill-sizes'),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['verified'], 2);
      expect(body['present'], 1);
      expect(body['missing'], 1);
      expect(body['errors'], 0);
      expect(body['totalBytes'], greaterThan(0));
    });

    test('dark settings round-trip through the host settings store', () async {
      final update = await translateHandlerErrors(
        handlers.handleUpdateDarkSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/settings'),
            body: jsonEncode({
              'autoCalibrate': true,
              'temperatureTolerance': 1.5,
            }),
          ),
        ),
      );
      expect(update.statusCode, HttpStatus.ok);

      final response = await handlers.handleGetDarkSettings(
        Request(
          'GET',
          Uri.parse('http://localhost/api/calibration/darks/settings'),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['autoCalibrate'], isTrue);
      expect(body['temperatureTolerance'], 1.5);
    });

    test('complete calibration settings round-trip host paths', () async {
      final flat = await writeDarkFile('master_flat.fits');
      final dark = await writeDarkFile('master_dark.fit');
      final update = await translateHandlerErrors(
        handlers.handleUpdateCalibrationSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/settings'),
            body: jsonEncode({
              'autoCalibrate': true,
              'masterFlatPath': flat.path,
              'masterBiasPath': null,
              'autoDarkFromLibrary': false,
              'manualDarkPath': dark.path,
            }),
          ),
        ),
      );
      expect(update.statusCode, HttpStatus.ok);

      final response = await handlers.handleGetCalibrationSettings(
        Request('GET', Uri.parse('http://localhost/api/calibration/settings')),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['autoCalibrate'], isTrue);
      expect(body['masterFlatPath'], flat.path);
      expect(body['masterBiasPath'], isNull);
      expect(body['autoDarkFromLibrary'], isFalse);
      expect(body['manualDarkPath'], dark.path);
    });

    test('calibration settings reject unusable host paths', () async {
      final relative = await translateHandlerErrors(
        handlers.handleUpdateCalibrationSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/settings'),
            body: jsonEncode({'masterFlatPath': 'relative/master.fits'}),
          ),
        ),
      );
      expect(relative.statusCode, HttpStatus.badRequest);

      final missing = await translateHandlerErrors(
        handlers.handleUpdateCalibrationSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/settings'),
            body: jsonEncode({
              'manualDarkPath': '${tempDir.path}/missing.fits',
            }),
          ),
        ),
      );
      expect(missing.statusCode, HttpStatus.badRequest);
      expect(
        await db.settingsDao.getSetting('calibration.manual_dark_path'),
        isNull,
      );
    });

    test('clean-orphans and group delete mutate the host library', () async {
      final presentA = await writeDarkFile('group-a.fits');
      final presentB = await writeDarkFile('group-b.fits');
      final missing = await writeDarkFile('missing.fits');
      await insertDark(presentA, exposure: 60, gain: 100, offset: 10);
      await insertDark(presentB, exposure: 60, gain: 100, offset: 10);
      await insertDark(missing, exposure: 30, gain: 200, offset: 5);
      await missing.delete();

      final cleaned = await handlers.handleCleanDarkOrphans(
        Request(
          'POST',
          Uri.parse('http://localhost/api/calibration/darks/clean-orphans'),
        ),
      );
      final cleanedBody = jsonDecode(await cleaned.readAsString()) as Map;
      expect(cleanedBody['removed'], 1);

      final deleted = await translateHandlerErrors(
        handlers.handleDeleteDarkGroup(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/delete-group'),
            body: jsonEncode({
              'exposureTime': 60,
              'gain': 100,
              'offset': 10,
              'binX': 1,
              'binY': 1,
              'frameType': 'dark',
              'deleteFiles': true,
            }),
          ),
        ),
      );
      final deletedBody = jsonDecode(await deleted.readAsString()) as Map;
      expect(deletedBody['removed'], 2);
      expect(await presentA.exists(), isFalse);
      expect(await presentB.exists(), isFalse);
      expect(await db.darkLibraryDao.getAllEntries(), isEmpty);
    });

    test(
      'create-master builds from explicit frame paths without registering them',
      () async {
        final a = await writeDarkFile('Dark_DARK_0001.fits');
        final b = await writeDarkFile('Dark_DARK_0002.fits');
        final output = '${tempDir.path}/Masters/MasterDark_90s.fits';
        await Directory('${tempDir.path}/Masters').create();
        final response = await translateHandlerErrors(
          handlers.handleCreateMasterDark(
            Request(
              'POST',
              Uri.parse('http://localhost/api/calibration/darks/create-master'),
              body: jsonEncode({
                'exposureTime': 90,
                'gain': 76,
                'offset': 15,
                'binX': 1,
                'binY': 1,
                'frameType': 'dark',
                'outputPath': output,
                'framePaths': [a.path, b.path],
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['frameCount'], 2);
        expect(builtRequests.single.framePaths, [a.path, b.path]);
        expect(builtRequests.single.kind, 'dark');
        final rows = await db.darkLibraryDao.getAllEntries();
        expect(rows, hasLength(1));
        expect(rows.single.masterDarkPath, output);
        expect(rows.single.masterFrameCount, 2);
        expect(rows.single.gain, 76);
        expect(rows.single.offset, 15);
        expect(rows.single.exposureTime, 90);
        expect(rows.single.temperature, closeTo(-9.9, 1e-9));
      },
    );

    test(
      'create-master from a library group uses the native builder',
      () async {
        final a = await writeDarkFile('a.fits');
        final b = await writeDarkFile('b.fits');
        await insertDark(a);
        await insertDark(b);
        final output = '${tempDir.path}/MasterDark_60s.fits';
        final response = await translateHandlerErrors(
          handlers.handleCreateMasterDark(
            Request(
              'POST',
              Uri.parse('http://localhost/api/calibration/darks/create-master'),
              body: jsonEncode({
                'exposureTime': 60,
                'gain': 100,
                'offset': 10,
                'binX': 1,
                'binY': 1,
                'frameType': 'dark',
                'outputPath': output,
              }),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(builtRequests.single.framePaths.toSet(), {a.path, b.path});
      },
    );

    test('create-master rejects client-relative host paths', () async {
      final response = await translateHandlerErrors(
        handlers.handleCreateMasterDark(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/darks/create-master'),
            body: jsonEncode({
              'exposureTime': 60,
              'gain': 100,
              'offset': 10,
              'binX': 1,
              'binY': 1,
              'frameType': 'dark',
              'outputPath': 'master.fits',
            }),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'outputPath');
    });

    // Flat history endpoints

    test('POST flats then GET returns the row', () async {
      final response = await translateHandlerErrors(
        handlers.handleRecordFlat(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/flats'),
            body: jsonEncode({
              'filter': 'Ha',
              'exposureDuration': 7.5,
              'adu': 30000,
              'histogramTarget': 50.0,
              'gain': 120,
              'binning': 1,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.created);
      final body = jsonDecode(await response.readAsString()) as Map;
      final flat = body['flat'] as Map;
      expect(flat['filter'], 'Ha');
      expect(flat['exposureDuration'], 7.5);

      final listResponse = await translateHandlerErrors(
        handlers.handleListFlats(
          Request(
            'GET',
            Uri.parse('http://localhost/api/calibration/flats?filter=Ha'),
          ),
        ),
      );
      expect(listResponse.statusCode, HttpStatus.ok);
      final listBody = jsonDecode(await listResponse.readAsString()) as Map;
      expect((listBody['flats'] as List), hasLength(1));
    });

    test('DELETE flats removes the row', () async {
      final id = await db.flatHistoryDao.recordCalibration(
        filterName: 'L',
        exposureTime: 3.0,
        histogramTarget: 50.0,
        actualAdu: 25000,
      );
      final response = await translateHandlerErrors(
        handlers.handleDeleteFlat(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/calibration/flats/$id'),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(await db.flatHistoryDao.getById(id), isNull);
    });

    test('GET flat recommendation returns prior matching exposure', () async {
      await db.flatHistoryDao.recordCalibration(
        filterName: 'Ha',
        exposureTime: 8.0,
        histogramTarget: 50.0,
        actualAdu: 30000,
        gain: 120,
      );

      final response = await translateHandlerErrors(
        handlers.handleFlatRecommendation(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/calibration/flats/recommendation?filter=Ha&gain=120',
            ),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      final recommended = body['recommended'] as Map;
      expect(recommended['exposureDuration'], 8.0);
      final basedOn = recommended['basedOn'] as Map;
      expect(basedOn['confidence'], 'high');
    });

    test('GET flat recommendation returns null when no history', () async {
      final response = await translateHandlerErrors(
        handlers.handleFlatRecommendation(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/calibration/flats/recommendation?filter=Ha',
            ),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['recommended'], isNull);
      expect(body['reason'], 'no_matching_history');
    });

    // Defect map endpoints

    test('defect-map status, clear, and sequencer apply run on host', () async {
      const status = DefectMapStatus(
        cameraId: 'native:test:1',
        width: 6248,
        height: 4176,
        temperatureBucket: DefectMapTemperatureBucket(-100),
        defectivePixelCount: 42,
        lastRebuiltUnixSeconds: 1234,
        applyDuringCapture: true,
        storedOnDisk: true,
      );
      when(
        () => defectMapService.getStatus(
          cameraId: 'native:test:1',
          width: 6248,
          height: 4176,
          sensorTemperatureCelsius: -10,
        ),
      ).thenAnswer((_) async => status);
      when(
        () => defectMapService.clear(
          cameraId: 'native:test:1',
          width: 6248,
          height: 4176,
          sensorTemperatureCelsius: -10,
        ),
      ).thenAnswer((_) async {});
      when(
        () => defectMapService.applyToSequencer(
          cameraId: 'native:test:1',
          width: 6248,
          height: 4176,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).thenAnswer((_) async {});

      final statusResponse = await translateHandlerErrors(
        handlers.handleGetDefectMapStatus(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/calibration/defect-maps/status'
              '?cameraId=native%3Atest%3A1&width=6248&height=4176'
              '&sensorTemperatureCelsius=-10',
            ),
          ),
        ),
      );
      expect(statusResponse.statusCode, HttpStatus.ok);
      final statusBody = jsonDecode(await statusResponse.readAsString()) as Map;
      expect((statusBody['status'] as Map)['defectivePixelCount'], 42);

      final clearResponse = await translateHandlerErrors(
        handlers.handleClearDefectMap(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/defect-maps/clear'),
            body: jsonEncode({
              'cameraId': 'native:test:1',
              'width': 6248,
              'height': 4176,
              'sensorTemperatureCelsius': -10,
            }),
          ),
        ),
      );
      expect(clearResponse.statusCode, HttpStatus.ok);

      final applyResponse = await translateHandlerErrors(
        handlers.handleApplyDefectMapToSequencer(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/calibration/defect-maps/sequencer-apply',
            ),
            body: jsonEncode({
              'cameraId': 'native:test:1',
              'width': 6248,
              'height': 4176,
              'sensorTemperatureCelsius': -10,
              'enabled': true,
              'method': 'gaussian',
              'kernelDiameter': 5,
              'saveOriginal': true,
            }),
          ),
        ),
      );
      expect(applyResponse.statusCode, HttpStatus.ok);
      verify(
        () => defectMapService.clear(
          cameraId: 'native:test:1',
          width: 6248,
          height: 4176,
          sensorTemperatureCelsius: -10,
        ),
      ).called(1);
      verify(
        () => defectMapService.applyToSequencer(
          cameraId: 'native:test:1',
          width: 6248,
          height: 4176,
          sensorTemperatureCelsius: -10,
          enabled: true,
          method: DefectMapMethod.gaussian,
          kernel: DefectMapKernelSize.k5,
          saveOriginal: true,
        ),
      ).called(1);
    });

    test('defect-map settings round-trip through the host store', () async {
      final update = await translateHandlerErrors(
        handlers.handleUpdateDefectMapSettings(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/defect-maps/settings'),
            body: jsonEncode({
              'autoApply': true,
              'method': 'mean',
              'kernelDiameter': 7,
              'saveOriginal': true,
            }),
          ),
        ),
      );
      expect(update.statusCode, HttpStatus.ok);

      final response = await handlers.handleGetDefectMapSettings(
        Request(
          'GET',
          Uri.parse('http://localhost/api/calibration/defect-maps/settings'),
        ),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['autoApply'], isTrue);
      expect(body['method'], 'mean');
      expect(body['kernelDiameter'], 7);
      expect(body['saveOriginal'], isTrue);
    });

    test('POST defect-map then GET list excludes bitmap', () async {
      // Bitmap for 16x16 sensor = 16*16/8 = 32 bytes
      final bitmap = Uint8List.fromList(List<int>.generate(32, (i) => i % 256));
      final response = await translateHandlerErrors(
        handlers.handleRegisterDefectMap(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/defect-maps'),
            body: jsonEncode({
              'cameraId': 'native:zwo:test',
              'width': 16,
              'height': 16,
              'temperatureBucketDecicelsius': -200,
              'bitmap': base64Encode(bitmap),
              'defectCount': 4,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.created);

      final listResponse = await translateHandlerErrors(
        handlers.handleListDefectMaps(
          Request(
            'GET',
            Uri.parse('http://localhost/api/calibration/defect-maps'),
          ),
        ),
      );
      expect(listResponse.statusCode, HttpStatus.ok);
      final body = jsonDecode(await listResponse.readAsString()) as Map;
      final maps = body['defectMaps'] as List;
      expect(maps, hasLength(1));
      final m = maps.first as Map;
      expect(m['cameraId'], 'native:zwo:test');
      expect(m.containsKey('bitmap'), isFalse);
      expect(m.containsKey('bitmapBase64'), isFalse);
    });

    test('POST defect-map rejects mismatched bitmap length', () async {
      final response = await translateHandlerErrors(
        handlers.handleRegisterDefectMap(
          Request(
            'POST',
            Uri.parse('http://localhost/api/calibration/defect-maps'),
            body: jsonEncode({
              'cameraId': 'native:zwo:test',
              'width': 16,
              'height': 16,
              'temperatureBucketDecicelsius': -200,
              'bitmap': base64Encode(Uint8List.fromList([1, 2, 3])),
              'defectCount': 1,
            }),
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'bitmap');
    });

    test(
      'GET defect-map binary returns octet-stream with metadata headers',
      () async {
        final bitmap = Uint8List.fromList(List<int>.generate(32, (i) => 0xA5));
        final id = await db
            .into(db.defectMaps)
            .insert(
              DefectMapsCompanion.insert(
                cameraId: 'native:test:1',
                width: 16,
                height: 16,
                temperatureBucketDecicelsius: -200,
                bitmap: bitmap,
                defectivePixelCount: 8,
              ),
            );

        final response = await translateHandlerErrors(
          handlers.handleGetDefectMap(
            Request(
              'GET',
              Uri.parse('http://localhost/api/calibration/defect-maps/$id'),
            ),
            id.toString(),
          ),
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers['content-type'], 'application/octet-stream');
        expect(response.headers['x-defect-map-camera-id'], 'native:test:1');
        expect(response.headers['x-defect-map-width'], '16');
        expect(response.headers['x-defect-map-defective-pixel-count'], '8');
        final body = await response.read().expand((c) => c).toList();
        expect(body, bitmap);
      },
    );

    test('GET defect-map json returns base64 in JSON wrapper', () async {
      final bitmap = Uint8List.fromList(List<int>.generate(32, (i) => 0x42));
      final id = await db
          .into(db.defectMaps)
          .insert(
            DefectMapsCompanion.insert(
              cameraId: 'native:test:2',
              width: 16,
              height: 16,
              temperatureBucketDecicelsius: -200,
              bitmap: bitmap,
              defectivePixelCount: 2,
            ),
          );

      final response = await translateHandlerErrors(
        handlers.handleGetDefectMap(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/calibration/defect-maps/$id?format=json',
            ),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(
        response.headers['content-type']?.toLowerCase(),
        contains('application/json'),
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      final m = body['defectMap'] as Map;
      expect(m['cameraId'], 'native:test:2');
      expect(base64Decode(m['bitmapBase64'] as String), bitmap);
    });

    test('DELETE defect-map removes the row', () async {
      final bitmap = Uint8List.fromList(List<int>.generate(32, (i) => 0));
      final id = await db
          .into(db.defectMaps)
          .insert(
            DefectMapsCompanion.insert(
              cameraId: 'native:test:3',
              width: 16,
              height: 16,
              temperatureBucketDecicelsius: -200,
              bitmap: bitmap,
              defectivePixelCount: 0,
            ),
          );
      final response = await translateHandlerErrors(
        handlers.handleDeleteDefectMap(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/calibration/defect-maps/$id'),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['deleted'], isTrue);
    });

    test('POST regenerate without sourceFilePath returns 409', () async {
      final id = await db
          .into(db.defectMaps)
          .insert(
            DefectMapsCompanion.insert(
              cameraId: 'native:test:4',
              width: 16,
              height: 16,
              temperatureBucketDecicelsius: -200,
              bitmap: Uint8List(32),
              defectivePixelCount: 0,
            ),
          );
      final response = await translateHandlerErrors(
        handlers.handleRegenerateDefectMap(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/calibration/defect-maps/$id/regenerate',
            ),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'defect_map_no_source');
    });

    test('POST regenerate with missing source file returns 409', () async {
      final id = await db
          .into(db.defectMaps)
          .insert(
            DefectMapsCompanion.insert(
              cameraId: 'native:test:5',
              width: 16,
              height: 16,
              temperatureBucketDecicelsius: -200,
              bitmap: Uint8List(32),
              defectivePixelCount: 0,
              filePath: Value('${tempDir.path}/missing.fits'),
            ),
          );
      final response = await translateHandlerErrors(
        handlers.handleRegenerateDefectMap(
          Request(
            'POST',
            Uri.parse(
              'http://localhost/api/calibration/defect-maps/$id/regenerate',
            ),
          ),
          id.toString(),
        ),
      );
      expect(response.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'defect_map_source_missing');
    });
  });

  // Scope assignments — route_metadata

  group('CalibrationHandlers — route metadata scopes', () {
    test('GET calibration endpoints are view scope', () {
      for (final path in const [
        '/api/calibration/darks',
        '/api/calibration/darks/<id>',
        '/api/calibration/darks/<id>/download',
        '/api/calibration/flats',
        '/api/calibration/flats/<id>',
        '/api/calibration/flats/recommendation',
        '/api/calibration/defect-maps',
        '/api/calibration/defect-maps/<id>',
      ]) {
        expect(
          requiredAuthScopeNameForEndpoint(method: 'GET', path: path),
          'view',
          reason: '$path GET must be view scope',
        );
      }
    });

    test('Creation POSTs are control scope', () {
      for (final path in const [
        '/api/calibration/darks',
        '/api/calibration/darks/find-match',
        '/api/calibration/flats',
        '/api/calibration/defect-maps',
      ]) {
        expect(
          requiredAuthScopeNameForEndpoint(method: 'POST', path: path),
          'control',
          reason: '$path POST must be control scope',
        );
      }
    });

    test('Defect-map regenerate is control scope', () {
      expect(
        requiredAuthScopeNameForEndpoint(
          method: 'POST',
          path: '/api/calibration/defect-maps/<id>/regenerate',
        ),
        'control',
      );
    });

    test('Destructive and heavy dark maintenance is admin/high-risk', () {
      const paths = {
        '/api/calibration/darks/upload': 'calibration_dark_upload',
        '/api/calibration/darks/backfill-sizes': 'calibration_backfill',
        '/api/calibration/darks/create-master':
            'calibration_dark_create_master',
        '/api/calibration/darks/clean-orphans':
            'calibration_dark_clean_orphans',
        '/api/calibration/darks/clear': 'calibration_dark_clear',
        '/api/calibration/darks/delete-group': 'calibration_dark_delete_group',
      };
      for (final entry in paths.entries) {
        expect(
          requiredAuthScopeNameForEndpoint(method: 'POST', path: entry.key),
          'admin',
        );
        expect(isHighRiskControlPath(entry.key), isTrue);
        expect(
          highRiskAuditActionFor(method: 'POST', path: entry.key),
          entry.value,
        );
      }
    });

    test('DELETE on calibration is admin scope and audited', () {
      for (final path in const [
        '/api/calibration/darks/<id>',
        '/api/calibration/flats/<id>',
        '/api/calibration/defect-maps/<id>',
      ]) {
        expect(
          requiredAuthScopeNameForEndpoint(method: 'DELETE', path: path),
          'admin',
          reason: '$path DELETE must be admin scope',
        );
      }
      expect(
        highRiskAuditActionFor(
          method: 'DELETE',
          path: '/api/calibration/darks/<id>',
        ),
        'calibration_dark_delete',
      );
      expect(
        highRiskAuditActionFor(
          method: 'DELETE',
          path: '/api/calibration/flats/<id>',
        ),
        'calibration_flat_delete',
      );
      expect(
        highRiskAuditActionFor(
          method: 'DELETE',
          path: '/api/calibration/defect-maps/<id>',
        ),
        'calibration_defect_map_delete',
      );
    });

    test('Upload body limit matches backup upload', () {
      expect(
        requestBodyLimitForPath('/api/calibration/darks/upload'),
        backupUploadMaxRequestBodyBytes,
      );
    });
  });
}
