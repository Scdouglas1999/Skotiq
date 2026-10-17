import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/analytics_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

void main() {
  group('AnalyticsHandlers', () {
    late ProviderContainer container;
    late AnalyticsHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = AnalyticsHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('invalid session ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetSessionById(
          Request('GET', Uri.parse('http://localhost/api/sessions/not-an-id')),
          'not-an-id',
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'update session malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleUpdateSession(
            Request(
              'PUT',
              Uri.parse('http://localhost/api/sessions/1'),
              body: '{',
            ),
            '1',
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test('invalid target statistics ID returns JSON internal error', () async {
      final response = await translateHandlerErrors(
        handlers.handleGetTargetStatistics(
          Request(
            'GET',
            Uri.parse('http://localhost/api/analytics/target/not-an-id'),
          ),
          'not-an-id',
        ),
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
      );
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], isA<String>());
    });

    test(
      'recent-session limit rejects supplied-invalid values before DB work',
      () async {
        final guarded = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith(
              (ref) => throw StateError('database must not be resolved'),
            ),
          ],
        );
        addTearDown(guarded.dispose);
        final guardedHandlers = AnalyticsHandlers(guarded);

        for (final raw in ['abc', '0', '-1', '1001', '1.5']) {
          final response = await translateHandlerErrors(
            guardedHandlers.handleGetRecentSessions(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/sessions/recent?limit='
                  '${Uri.encodeQueryComponent(raw)}',
                ),
              ),
            ),
          );
          expect(response.statusCode, HttpStatus.badRequest, reason: raw);
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['field'], 'limit', reason: raw);
        }
      },
    );

    test('summary and integration endpoints honor their date range', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final rangedContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(rangedContainer.dispose);
      final rangedHandlers = AnalyticsHandlers(rangedContainer);

      Future<void> seed(
        DateTime startTime, {
        required int exposures,
        required double integrationSeconds,
      }) {
        return database
            .into(database.imagingSessions)
            .insert(
              ImagingSessionsCompanion.insert(
                startTime: startTime,
                totalExposures: Value(exposures),
                totalIntegrationSecs: Value(integrationSeconds),
              ),
            )
            .then((_) {});
      }

      await seed(
        DateTime.utc(2026, 6, 15),
        exposures: 10,
        integrationSeconds: 3600,
      );
      await seed(
        DateTime.utc(2026, 7, 15),
        exposures: 20,
        integrationSeconds: 7200,
      );
      await seed(
        DateTime.utc(2026, 8, 15),
        exposures: 30,
        integrationSeconds: 10800,
      );

      final summaryResponse = await rangedHandlers.handleGetAnalyticsSummary(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/analytics/summary?'
            'startDate=2026-07-01T00%3A00%3A00Z&'
            'endDate=2026-07-31T23%3A59%3A59Z',
          ),
        ),
      );
      final summaryBody =
          jsonDecode(await summaryResponse.readAsString()) as Map;
      final summary = summaryBody['summary'] as Map;
      expect(summary['totalSessions'], 1);
      expect(summary['sessionsInRange'], 1);
      expect(summary['totalExposures'], 20);
      expect(summary['totalIntegrationHours'], 2.0);

      // Older companion builds send epoch milliseconds. A one-sided range is
      // still a real range and must not silently become an all-time total.
      final startEpoch = DateTime.utc(2026, 7, 1).millisecondsSinceEpoch;
      final integrationResponse = await rangedHandlers
          .handleGetTotalIntegrationTime(
            Request(
              'GET',
              Uri.parse(
                'http://localhost/api/analytics/integration-time?'
                'startDate=$startEpoch',
              ),
            ),
          );
      final integration =
          jsonDecode(await integrationResponse.readAsString()) as Map;
      expect(integration['totalIntegrationSecs'], 18000.0);
      expect(integration['totalIntegrationHours'], 5.0);
    });

    test('analytics rejects a reversed date range before DB work', () async {
      final guarded = ProviderContainer(
        overrides: [
          databaseProvider.overrideWith(
            (ref) => throw StateError('database must not be resolved'),
          ),
        ],
      );
      addTearDown(guarded.dispose);
      final guardedHandlers = AnalyticsHandlers(guarded);

      final response = await translateHandlerErrors(
        guardedHandlers.handleGetAnalyticsSummary(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/analytics/summary?'
              'startDate=2026-08-01&endDate=2026-07-01',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['field'], 'startDate|endDate');
    });

    test('session stats retain the persisted HFR without image rows', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      final sessionId = await database
          .into(database.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              startTime: DateTime.utc(2026, 7, 24),
              totalExposures: const Value(2),
              avgHfr: const Value(2.2),
            ),
          );

      final response = await testHandlers.handleGetSessionStats(
        Request(
          'GET',
          Uri.parse('http://localhost/api/sessions/$sessionId/stats'),
        ),
        '$sessionId',
      );
      final body = jsonDecode(await response.readAsString()) as Map;
      expect((body['stats'] as Map)['avgHfr'], 2.2);
    });

    test('session stats carry the culling verdict, not just the camera\'s '
        'exposure outcome', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      final sessionId = await database
          .into(database.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              startTime: DateTime.utc(2026, 8, 17),
              totalExposures: const Value(10),
              successfulExposures: const Value(10),
            ),
          );

      Future<void> addFrame({
        required int index,
        required String frameType,
        required bool accepted,
      }) => database
          .into(database.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: '/l/$frameType$index.fits',
              fileName: '$frameType$index.fits',
              frameType: Value(frameType),
              exposureDuration: 300.0,
              capturedAt: DateTime.utc(2026, 8, 17),
              sessionId: Value(sessionId),
              isAccepted: Value(accepted),
            ),
          );

      for (var i = 0; i < 7; i++) {
        await addFrame(index: i, frameType: 'light', accepted: true);
      }
      for (var i = 0; i < 3; i++) {
        await addFrame(index: 10 + i, frameType: 'light', accepted: false);
      }
      // Calibration frames are not graded. Counting them would inflate
      // `acceptedLights` with darks that no one ever culled.
      await addFrame(index: 20, frameType: 'dark', accepted: true);

      final response = await testHandlers.handleGetSessionStats(
        Request(
          'GET',
          Uri.parse('http://localhost/api/sessions/$sessionId/stats'),
        ),
        '$sessionId',
      );
      final stats =
          (jsonDecode(await response.readAsString()) as Map)['stats'] as Map;

      expect(stats['acceptedLights'], 7);
      expect(stats['rejectedLights'], 3);
      expect(
        stats['successfulExposures'],
        10,
        reason:
            'the exposure outcome is a different question from the grading '
            'verdict — a frame can expose perfectly and still be rejected',
      );
      expect((stats['frameBreakdown'] as Map)['light'], 10);
    });

    // The all-rejected night: twelve subs exposed and downloaded perfectly,
    // every one of them culled. `imaging_sessions` records that as
    // `successful 12 / failed 0` — the identical row a fully accepted night
    // writes — so the list surfaces, which served that row alone, told the
    // operator the night worked while `/api/sessions/<id>/stats` said nothing
    // survived. Same night, two answers. Both surfaces now read the frames.
    test('every session surface reports the same grading verdict', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      Future<int> seedSession({required String name, required int targetId}) =>
          database
              .into(database.imagingSessions)
              .insert(
                ImagingSessionsCompanion.insert(
                  name: Value(name),
                  startTime: DateTime.utc(2026, 8, 17),
                  targetId: Value(targetId),
                  totalExposures: const Value(12),
                  successfulExposures: const Value(12),
                ),
              );

      Future<void> addFrame({
        required int sessionId,
        required int index,
        required String frameType,
        required bool accepted,
      }) => database
          .into(database.capturedImages)
          .insert(
            CapturedImagesCompanion.insert(
              filePath: '/l/$sessionId-$frameType$index.fits',
              fileName: '$sessionId-$frameType$index.fits',
              frameType: Value(frameType),
              exposureDuration: 300.0,
              capturedAt: DateTime.utc(2026, 8, 17),
              sessionId: Value(sessionId),
              isAccepted: Value(accepted),
            ),
          );

      await database
          .into(database.targets)
          .insert(TargetsCompanion.insert(name: 'M31', ra: 10.68, dec: 41.27));

      final rejectedNight = await seedSession(
        name: 'all rejected',
        targetId: 1,
      );
      for (var i = 0; i < 12; i++) {
        await addFrame(
          sessionId: rejectedNight,
          index: i,
          frameType: 'light',
          accepted: false,
        );
      }
      // A second night on the same target, kept, so the batched read is proven
      // to attribute counts per session rather than smearing one total across
      // the page.
      final keptNight = await seedSession(name: 'all kept', targetId: 1);
      for (var i = 0; i < 12; i++) {
        await addFrame(
          sessionId: keptNight,
          index: i,
          frameType: 'light',
          accepted: true,
        );
      }
      // Calibration is never graded and must not reach either count.
      await addFrame(
        sessionId: rejectedNight,
        index: 99,
        frameType: 'dark',
        accepted: true,
      );

      Future<Map<String, Object?>> sessionFrom(
        Future<Response> response,
        String envelope, {
        int? pick,
      }) async {
        final body = jsonDecode(await (await response).readAsString()) as Map;
        if (pick == null) {
          return (body[envelope] as Map).cast<String, Object?>();
        }
        final list = (body[envelope] as List).cast<Map<String, Object?>>();
        return list.firstWhere((row) => row['id'] == pick);
      }

      final surfaces = <String, Map<String, Object?>>{
        '/api/sessions': await sessionFrom(
          testHandlers.handleGetAllSessions(
            Request('GET', Uri.parse('http://localhost/api/sessions')),
          ),
          'sessions',
          pick: rejectedNight,
        ),
        '/api/sessions/<id>': await sessionFrom(
          testHandlers.handleGetSessionById(
            Request(
              'GET',
              Uri.parse('http://localhost/api/sessions/$rejectedNight'),
            ),
            '$rejectedNight',
          ),
          'session',
        ),
        '/api/sessions/recent': await sessionFrom(
          testHandlers.handleGetRecentSessions(
            Request('GET', Uri.parse('http://localhost/api/sessions/recent')),
          ),
          'sessions',
          pick: rejectedNight,
        ),
        '/api/analytics/target/<id>/sessions': await sessionFrom(
          testHandlers.handleGetSessionsForTarget(
            Request(
              'GET',
              Uri.parse('http://localhost/api/analytics/target/1/sessions'),
            ),
            '1',
          ),
          'sessions',
          pick: rejectedNight,
        ),
        '/api/sessions/<id>/stats': await sessionFrom(
          testHandlers.handleGetSessionStats(
            Request(
              'GET',
              Uri.parse('http://localhost/api/sessions/$rejectedNight/stats'),
            ),
            '$rejectedNight',
          ),
          'stats',
        ),
      };

      for (final entry in surfaces.entries) {
        expect(
          entry.value['acceptedLights'],
          0,
          reason: '${entry.key} must say nothing survived this night',
        );
        expect(
          entry.value['rejectedLights'],
          12,
          reason: '${entry.key} must name the twelve culled frames',
        );
        expect(
          entry.value['successfulExposures'],
          12,
          reason:
              '${entry.key} still answers the camera question honestly — '
              'twelve exposures did complete',
        );
      }

      final kept = await sessionFrom(
        testHandlers.handleGetAllSessions(
          Request('GET', Uri.parse('http://localhost/api/sessions')),
        ),
        'sessions',
        pick: keptNight,
      );
      expect(kept['acceptedLights'], 12);
      expect(kept['rejectedLights'], 0);
    });

    // D3-DP-1. The same all-rejected night, read four ways at one moment:
    // `/api/sessions`, `/api/sessions/<id>` and the export answered
    // `avgHfr: null` while `/api/sessions/<id>/stats` answered 2.4608, because
    // the stats endpoint recomputed its own mean over every `captured_images`
    // row instead of reading the column the other three ship. One session, one
    // field, two rules. `avgHfr` is now the accepted-frames figure everywhere,
    // it says so, and the all-frames diagnostic keeps its own name.
    test(
      'every session surface answers the HFR question the same way',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final testContainer = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)],
        );
        addTearDown(testContainer.dispose);
        final testHandlers = AnalyticsHandlers(testContainer);

        // A night in which every light was culled: no accepted frame, so the
        // running average was never advanced and the column is NULL — while the
        // rows themselves all carry an HFR.
        final sessionId = await database
            .into(database.imagingSessions)
            .insert(
              ImagingSessionsCompanion.insert(
                name: const Value('all rejected'),
                startTime: DateTime.utc(2026, 8, 31),
                totalExposures: const Value(12),
                successfulExposures: const Value(12),
              ),
            );
        for (var i = 0; i < 12; i++) {
          await database
              .into(database.capturedImages)
              .insert(
                CapturedImagesCompanion.insert(
                  filePath: '/l/rej$i.fits',
                  fileName: 'rej$i.fits',
                  frameType: const Value('light'),
                  exposureDuration: 2.0,
                  capturedAt: DateTime.utc(2026, 8, 31),
                  sessionId: Value(sessionId),
                  isAccepted: const Value(false),
                  hfr: Value(2.4 + i * 0.01),
                ),
              );
        }
        // A dark carrying an HFR: a calibration frame's star measurement is not
        // a focus reading and must not reach either figure.
        await database
            .into(database.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: '/l/dark.fits',
                fileName: 'dark.fits',
                frameType: const Value('dark'),
                exposureDuration: 2.0,
                capturedAt: DateTime.utc(2026, 8, 31),
                sessionId: Value(sessionId),
                isAccepted: const Value(true),
                hfr: const Value(9.9),
              ),
            );

        Future<Map<String, Object?>> read(
          Future<Response> response,
          String envelope, {
          int? pick,
        }) async {
          final body = jsonDecode(await (await response).readAsString()) as Map;
          if (pick == null) {
            return (body[envelope] as Map).cast<String, Object?>();
          }
          return (body[envelope] as List)
              .cast<Map<String, Object?>>()
              .firstWhere((row) => row['id'] == pick);
        }

        final surfaces = <String, Map<String, Object?>>{
          '/api/sessions': await read(
            testHandlers.handleGetAllSessions(
              Request('GET', Uri.parse('http://localhost/api/sessions')),
            ),
            'sessions',
            pick: sessionId,
          ),
          '/api/sessions/<id>': await read(
            testHandlers.handleGetSessionById(
              Request(
                'GET',
                Uri.parse('http://localhost/api/sessions/$sessionId'),
              ),
              '$sessionId',
            ),
            'session',
          ),
          '/api/sessions/<id>/stats': await read(
            testHandlers.handleGetSessionStats(
              Request(
                'GET',
                Uri.parse('http://localhost/api/sessions/$sessionId/stats'),
              ),
              '$sessionId',
            ),
            'stats',
          ),
        };

        for (final entry in surfaces.entries) {
          expect(
            entry.value['avgHfr'],
            isNull,
            reason:
                '${entry.key}: no frame survived, so there is no accepted-frame '
                'HFR — and "null" and "a number" cannot both be right',
          );
          expect(
            entry.value['avgHfrBasis'],
            'accepted-frames',
            reason: '${entry.key} states the rule beside the figure',
          );
        }

        // The diagnostic an all-rejected night actually needs, under its own
        // name: was it focus, or was it cloud?
        final stats = surfaces['/api/sessions/<id>/stats']!;
        expect(
          stats['avgHfrAllLightsCount'],
          12,
          reason: 'the dark is excluded',
        );
        expect(
          (stats['avgHfrAllLights'] as num).toDouble(),
          closeTo(2.455, 0.001),
        );
      },
    );

    test('an accepted night reports one HFR on every surface', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      final sessionId = await database
          .into(database.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              startTime: DateTime.utc(2026, 8, 31),
              totalExposures: const Value(2),
              successfulExposures: const Value(2),
              avgHfr: const Value(2.4882195647459127),
            ),
          );
      for (final hfr in const [2.48, 2.50]) {
        await database
            .into(database.capturedImages)
            .insert(
              CapturedImagesCompanion.insert(
                filePath: '/l/ok$hfr.fits',
                fileName: 'ok$hfr.fits',
                frameType: const Value('light'),
                exposureDuration: 2.0,
                capturedAt: DateTime.utc(2026, 8, 31),
                sessionId: Value(sessionId),
                isAccepted: const Value(true),
                hfr: Value(hfr),
              ),
            );
      }

      final listed =
          ((jsonDecode(
                        await (await testHandlers.handleGetAllSessions(
                          Request(
                            'GET',
                            Uri.parse('http://localhost/api/sessions'),
                          ),
                        )).readAsString(),
                      )
                      as Map)['sessions']
                  as List)
              .cast<Map<String, Object?>>()
              .firstWhere((row) => row['id'] == sessionId);
      final stats =
          (jsonDecode(
                    await (await testHandlers.handleGetSessionStats(
                      Request(
                        'GET',
                        Uri.parse(
                          'http://localhost/api/sessions/$sessionId/stats',
                        ),
                      ),
                      '$sessionId',
                    )).readAsString(),
                  )
                  as Map)['stats']
              as Map;

      expect(
        stats['avgHfr'],
        listed['avgHfr'],
        reason: 'one night, one number, to the last digit',
      );
      expect(stats['avgHfr'], 2.4882195647459127);
    });

    test(
      'a session with no frames on record claims no accepted lights',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final testContainer = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)],
        );
        addTearDown(testContainer.dispose);
        final testHandlers = AnalyticsHandlers(testContainer);

        final sessionId = await database
            .into(database.imagingSessions)
            .insert(
              ImagingSessionsCompanion.insert(
                startTime: DateTime.utc(2026, 8, 17),
                totalExposures: const Value(4),
                successfulExposures: const Value(4),
              ),
            );

        final body =
            jsonDecode(
                  await (await testHandlers.handleGetSessionById(
                    Request(
                      'GET',
                      Uri.parse('http://localhost/api/sessions/$sessionId'),
                    ),
                    '$sessionId',
                  )).readAsString(),
                )
                as Map;
        final session = body['session'] as Map;
        expect(session['acceptedLights'], 0);
        expect(session['rejectedLights'], 0);
      },
    );

    test('session creation rejects empty and unknown payloads', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      for (final payload in const [
        <String, Object?>{},
        <String, Object?>{'unexpected': true},
        <String, Object?>{'name': '   '},
      ]) {
        final response = await translateHandlerErrors(
          testHandlers.handleCreateSession(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sessions'),
              body: jsonEncode(payload),
            ),
          ),
        );
        expect(response.statusCode, HttpStatus.badRequest, reason: '$payload');
      }
      expect(await database.sessionsDao.getAllSessions(), isEmpty);
    });

    test('only one imaging session can be active at a time', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final testContainer = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(testContainer.dispose);
      final testHandlers = AnalyticsHandlers(testContainer);

      Future<Response> create(String name) => translateHandlerErrors(
        testHandlers.handleCreateSession(
          Request(
            'POST',
            Uri.parse('http://localhost/api/sessions'),
            body: jsonEncode({'name': name}),
          ),
        ),
      );

      final first = await create('First');
      expect(first.statusCode, HttpStatus.ok);
      final firstId =
          (jsonDecode(await first.readAsString()) as Map)['id'] as int;

      final second = await create('Second');
      expect(second.statusCode, HttpStatus.conflict);
      final body = jsonDecode(await second.readAsString()) as Map;
      expect(body['error'], 'active_session_exists');
      expect(body['activeSessionId'], firstId);
      expect(await database.sessionsDao.getActiveSessions(), hasLength(1));
    });
  });
}
