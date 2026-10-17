import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Mock implementation of http.Client
class MockHttpClient extends Mock implements http.Client {}

/// Mock implementation of LoggingService
class MockLoggingService extends Mock implements LoggingService {}

/// Fake Uri for mocktail registration
class FakeUri extends Fake implements Uri {}

void main() {
  setUpAll(() {
    registerFallbackValue(FakeUri());
  });

  group('TransientAlertService', () {
    late TransientAlertService service;
    late MockHttpClient mockHttpClient;
    late MockLoggingService mockLogger;

    setUp(() {
      mockHttpClient = MockHttpClient();
      mockLogger = MockLoggingService();
      service = TransientAlertService(
        httpClient: mockHttpClient,
        logger: mockLogger,
      );
    });

    tearDown(() {
      service.dispose();
    });

    /// Drive the TNS Search -> Get Object pair from a list of object payloads.
    ///
    /// TNS is the only feed the service fetches, so it is also the vehicle for
    /// the caching, filtering and coordinate-parsing tests below. An AAVSO
    /// fixture would not carry a response shape VSX produces.
    void stubTns(List<Map<String, dynamic>> objects) {
      when(
        () => mockHttpClient.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((invocation) async {
        final uri = invocation.positionalArguments.first as Uri;
        if (uri.path.endsWith('/get/search')) {
          return http.Response(
            jsonEncode({
              'data': {
                'reply': [
                  for (final object in objects) {'objname': object['objname']},
                ],
              },
            }),
            200,
          );
        }
        final body = invocation.namedArguments[#body] as Map<String, String>;
        final wanted =
            (jsonDecode(body['data']!) as Map<String, dynamic>)['objname'];
        final object = objects.firstWhere((o) => o['objname'] == wanted);
        return http.Response(
          jsonEncode({
            'data': {'reply': object},
          }),
          200,
        );
      });
    }

    /// A TNS Get Object reply, in the wire shape the real API returns.
    Map<String, dynamic> tnsObject({
      String objname = '2026abc',
      String prefix = 'SN',
      String ra = '20:24:03.83',
      String dec = '+33:52:02.2',
      String type = 'SN Ia',
      double? discoveryMag = 11.0,
      String objid = '12345',
    }) {
      return {
        'objid': objid,
        'objname': objname,
        'name_prefix': prefix,
        'ra': ra,
        'dec': dec,
        'discoverydate': '2026-07-10 03:04:05.000',
        'lastmodified': '2026-07-11 05:00:00.000',
        'discoverymag': discoveryMag,
        'object_type': {'id': 3, 'name': type},
      };
    }

    /// Settings whose only enabled feed is a fully configured TNS.
    const tnsSettings = TransientAlertSettings(
      enabledSources: {TransientSource.tns},
      tnsApiKey: 'secret',
    );

    Future<List<TransientAlert>> fetchAll([
      TransientAlertSettings settings = tnsSettings,
    ]) =>
        service.getAllAlerts(settings, tnsBotId: 42, tnsBotName: 'Skotiq Bot');

    group('caching behavior', () {
      test('cache is invalid when empty', () {
        expect(service.isCacheValid, isFalse);
      });

      test('getAllAlerts uses cache on second call', () async {
        stubTns([tnsObject(objname: 'Test Star')]);

        final alerts1 = await fetchAll();
        expect(alerts1, hasLength(1));

        final alerts2 = await fetchAll();

        expect(alerts2.length, equals(alerts1.length));
        expect(service.isCacheValid, isTrue);
        // Two Search+Get pairs would be four calls; the cache means two.
        verify(
          () => mockHttpClient.post(
            any(),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
          ),
        ).called(2);
      });

      test('clearCache invalidates cache', () async {
        stubTns([tnsObject(objname: 'Test Star')]);

        await fetchAll();
        expect(service.isCacheValid, isTrue);

        service.clearCache();
        expect(service.isCacheValid, isFalse);
      });

      group('getAllAlerts filtering', () {
        test('filters by type', () async {
          stubTns([
            tnsObject(objname: 'Nova', type: 'Nova'),
            tnsObject(objname: 'Supernova', objid: '2', type: 'SN Ia'),
          ]);

          final alerts = await fetchAll(
            const TransientAlertSettings(
              typesToMonitor: {TransientType.nova},
              enabledSources: {TransientSource.tns},
              tnsApiKey: 'secret',
            ),
          );

          expect(alerts, isNotEmpty);
          for (final alert in alerts) {
            expect(alert.type, equals(TransientType.nova));
          }
        });

        test('filters by magnitude threshold', () async {
          stubTns([
            tnsObject(objname: 'Bright', discoveryMag: 10.0),
            tnsObject(objname: 'Faint', objid: '2', discoveryMag: 18.0),
          ]);

          final alerts = await fetchAll(
            const TransientAlertSettings(
              magnitudeThreshold: 12.0,
              enabledSources: {TransientSource.tns},
              tnsApiKey: 'secret',
            ),
          );

          expect(alerts.map((alert) => alert.name), ['SNBright']);
        });

        test('an AAVSO source that is enabled is never fetched', () async {
          // VSX's api.list is a positional catalog search, so an AAVSO alert
          // feed built on it can only answer with an empty set — a dead feed
          // that reads as a quiet sky. It is not dispatched, so a stored
          // profile that still enables it must produce no upstream traffic and
          // no alerts.
          final alerts = await service.getAllAlerts(
            const TransientAlertSettings(
              enabledSources: {TransientSource.aavso, TransientSource.manual},
            ),
          );

          expect(alerts, isEmpty);
          verifyNever(() => mockHttpClient.get(any()));
          verifyNever(
            () => mockHttpClient.post(
              any(),
              headers: any(named: 'headers'),
              body: any(named: 'body'),
            ),
          );
        });

        test(
          'the shipped default enables only feeds that are fetched',
          () async {
            // A default that enables a source the service never queries has a
            // fresh install reporting it monitors feeds it does not.
            const defaults = TransientAlertSettings();
            final advertised = defaults.enabledSources
                .where((source) => source != TransientSource.manual)
                .toSet();
            expect(advertised.difference(kFetchableTransientSources), isEmpty);
          },
        );

        test('sorts alerts by priority then discovery time', () async {
          stubTns([
            tnsObject(objname: 'LowPriority', type: 'Other'),
            tnsObject(objname: 'HighPriority', objid: '2', type: 'SN Ia'),
          ]);

          final alerts = await fetchAll();

          expect(alerts, hasLength(2));
          for (int i = 0; i < alerts.length - 1; i++) {
            expect(
              alerts[i].priority,
              lessThanOrEqualTo(alerts[i + 1].priority),
            );
          }
        });
      });

      group('shouldNotify', () {
        test('returns true for monitored type and magnitude', () {
          final alert = TransientAlert(
            id: 'test1',
            name: 'Test Nova',
            type: TransientType.nova,
            raHours: 12.0,
            decDegrees: 45.0,
            magnitude: 10.0,
            discoveryTime: DateTime.now(),
            lastUpdated: DateTime.now(),
            source: TransientSource.aavso,
            priority: 3,
          );

          const settings = TransientAlertSettings(
            typesToMonitor: {TransientType.nova},
            enabledSources: {TransientSource.aavso},
            magnitudeThreshold: 15.0,
            notifyOnNew: true,
          );

          expect(service.shouldNotify(alert, settings), isTrue);
        });

        test('returns false for unmonitored type', () {
          final alert = TransientAlert(
            id: 'test1',
            name: 'Test Star',
            type: TransientType.variableStar,
            raHours: 12.0,
            decDegrees: 45.0,
            discoveryTime: DateTime.now(),
            lastUpdated: DateTime.now(),
            source: TransientSource.aavso,
            priority: 5,
          );

          const settings = TransientAlertSettings(
            typesToMonitor: {
              TransientType.nova,
              TransientType.supernova,
            }, // Not variableStar
            enabledSources: {TransientSource.aavso},
          );

          expect(service.shouldNotify(alert, settings), isFalse);
        });

        test('returns false for disabled source', () {
          final alert = TransientAlert(
            id: 'test1',
            name: 'Test Nova',
            type: TransientType.nova,
            raHours: 12.0,
            decDegrees: 45.0,
            discoveryTime: DateTime.now(),
            lastUpdated: DateTime.now(),
            source: TransientSource.aavso,
            priority: 3,
          );

          const settings = TransientAlertSettings(
            typesToMonitor: {TransientType.nova},
            enabledSources: {TransientSource.tns}, // AAVSO not enabled
          );

          expect(service.shouldNotify(alert, settings), isFalse);
        });

        test('returns false for alert fainter than threshold', () {
          final alert = TransientAlert(
            id: 'test1',
            name: 'Faint Nova',
            type: TransientType.nova,
            raHours: 12.0,
            decDegrees: 45.0,
            magnitude: 18.0, // Fainter than threshold
            discoveryTime: DateTime.now(),
            lastUpdated: DateTime.now(),
            source: TransientSource.aavso,
            priority: 3,
          );

          const settings = TransientAlertSettings(
            typesToMonitor: {TransientType.nova},
            enabledSources: {TransientSource.aavso},
            magnitudeThreshold: 15.0, // Only alerts brighter than 15
          );

          expect(service.shouldNotify(alert, settings), isFalse);
        });

        test(
          'returns false when notifyOnNew is false and not auto-queue eligible',
          () {
            final alert = TransientAlert(
              id: 'test1',
              name: 'Test Nova',
              type: TransientType.nova,
              raHours: 12.0,
              decDegrees: 45.0,
              magnitude: 12.0, // Not bright enough for auto-queue
              discoveryTime: DateTime.now(),
              lastUpdated: DateTime.now(),
              source: TransientSource.aavso,
              priority: 3,
            );

            const settings = TransientAlertSettings(
              typesToMonitor: {TransientType.nova},
              enabledSources: {TransientSource.aavso},
              magnitudeThreshold: 15.0,
              notifyOnNew: false,
              autoQueueBright: true,
              autoQueueMagnitude: 10.0, // Alert is not bright enough
            );

            expect(service.shouldNotify(alert, settings), isFalse);
          },
        );

        test(
          'returns true for bright transient when autoQueueBright is enabled',
          () {
            final alert = TransientAlert(
              id: 'test1',
              name: 'Bright Nova',
              type: TransientType.nova,
              raHours: 12.0,
              decDegrees: 45.0,
              magnitude: 8.0, // Very bright
              discoveryTime: DateTime.now(),
              lastUpdated: DateTime.now(),
              source: TransientSource.aavso,
              priority: 2,
            );

            const settings = TransientAlertSettings(
              typesToMonitor: {TransientType.nova},
              enabledSources: {TransientSource.aavso},
              magnitudeThreshold: 15.0,
              notifyOnNew: false, // Even with this false
              autoQueueBright: true,
              autoQueueMagnitude: 10.0, // 8.0 is brighter than 10.0
            );

            expect(service.shouldNotify(alert, settings), isTrue);
          },
        );

        test('handles alert with null magnitude', () {
          final alert = TransientAlert(
            id: 'test1',
            name: 'Unknown Mag',
            type: TransientType.nova,
            raHours: 12.0,
            decDegrees: 45.0,
            magnitude: null, // Unknown magnitude
            discoveryTime: DateTime.now(),
            lastUpdated: DateTime.now(),
            source: TransientSource.aavso,
            priority: 3,
          );

          const settings = TransientAlertSettings(
            typesToMonitor: {TransientType.nova},
            enabledSources: {TransientSource.aavso},
            magnitudeThreshold: 15.0,
            notifyOnNew: true,
          );

          // Should pass magnitude check (null magnitude not filtered)
          expect(service.shouldNotify(alert, settings), isTrue);
        });
      });

      group('coordinate parsing', () {
        test('parses RA in HMS format', () async {
          stubTns([tnsObject(ra: '12:30:45.67')]);

          final alerts = await fetchAll();

          expect(alerts, hasLength(1));
          // 12h 30m 45.67s = 12 + 30/60 + 45.67/3600 hours
          expect(alerts[0].raHours, closeTo(12.5127, 0.001));
        });

        test('parses Dec in DMS format with positive sign', () async {
          stubTns([tnsObject(dec: '+45:30:00.0')]);

          final alerts = await fetchAll();

          expect(alerts, hasLength(1));
          // +45 30' 00" = 45.5 degrees
          expect(alerts[0].decDegrees, closeTo(45.5, 0.01));
        });

        test('parses Dec in DMS format with negative sign', () async {
          stubTns([tnsObject(dec: '-30:15:30.0')]);

          final alerts = await fetchAll();

          expect(alerts, hasLength(1));
          // -30 15' 30" = -30.2583 degrees
          expect(alerts[0].decDegrees, closeTo(-30.2583, 0.01));
        });
      });

      group('fetchTnsAlerts', () {
        test('returns empty list when no API key provided', () async {
          final alerts = await service.fetchTnsAlerts();

          // Should return empty list without API key
          expect(alerts, isEmpty);
        });

        test('returns empty list when API key is empty string', () async {
          final alerts = await service.fetchTnsAlerts(apiKey: '');

          // Should return empty list with empty API key
          expect(alerts, isEmpty);
        });

        test(
          'partial TNS credentials still fail as incomplete configuration',
          () async {
            await expectLater(
              service.fetchTnsAlerts(apiKey: 'secret'),
              throwsA(isA<TransientAlertFetchException>()),
            );
          },
        );

        test(
          'throws when an authenticated search response is malformed',
          () async {
            final client = MockClient(
              (_) async => http.Response(jsonEncode({'data': {}}), 200),
            );
            final realService = TransientAlertService(
              httpClient: client,
              logger: mockLogger,
            );
            addTearDown(realService.dispose);

            await expectLater(
              realService.fetchTnsAlerts(
                apiKey: 'secret',
                botId: 42,
                botName: 'Skotiq Bot',
              ),
              throwsA(isA<TransientAlertFetchException>()),
            );
          },
        );

        test(
          'an enabled TNS-only feed without credentials is empty setup state',
          () async {
            const unconfigured = TransientAlertSettings(
              enabledSources: {TransientSource.tns},
            );
            final empty = await service.getAllAlerts(
              unconfigured,
              tnsBotId: 42,
              tnsBotName: 'Skotiq Bot',
            );

            expect(empty, isEmpty);
            expect(service.isCacheValid, isTrue);

            // Changing the credential is part of the fetch signature, so a
            // later configured refresh must not reuse the setup-state result.
            stubTns([tnsObject(objname: 'Configured Alert')]);
            final configured = await fetchAll();

            expect(configured, hasLength(1));
            verify(
              () => mockHttpClient.post(
                any(),
                headers: any(named: 'headers'),
                body: any(named: 'body'),
              ),
            ).called(2);
          },
        );
      });

      test('uses the official Search then Get Object wire contract', () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/get/search')) {
            return http.Response(
              jsonEncode({
                'id_code': 200,
                'data': {
                  'reply': [
                    {'objname': '2026abc', 'prefix': 'SN', 'objid': 91},
                  ],
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/get/object')) {
            return http.Response(
              jsonEncode({
                'id_code': 200,
                'data': {
                  'reply': {
                    'objid': 91,
                    'objname': '2026abc',
                    'name_prefix': 'SN',
                    'ra': '12:30:00.0',
                    'dec': '-20:15:00.0',
                    'discoverydate': '2026-07-10 03:04:05.000',
                    'lastmodified': '2026-07-11 05:00:00.000',
                    'discoverymag': 13.4,
                    'object_type': {'id': 3, 'name': 'SN Ia'},
                  },
                },
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        });
        final realService = TransientAlertService(
          httpClient: client,
          logger: mockLogger,
        );
        addTearDown(realService.dispose);

        final alerts = await realService.fetchTnsAlerts(
          apiKey: 'secret',
          botId: 42,
          botName: 'Skotiq Bot',
        );

        expect(alerts, hasLength(1));
        expect(alerts.single.id, 'tns_91');
        expect(alerts.single.name, 'SN2026abc');
        expect(alerts.single.type, TransientType.supernova);
        expect(alerts.single.raHours, 12.5);
        expect(alerts.single.decDegrees, -20.25);
        expect(requests, hasLength(2));
        expect(
          requests.first.headers['user-agent'],
          contains('tns_marker{"tns_id":42'),
        );
        final searchData =
            jsonDecode(requests.first.bodyFields['data']!)
                as Map<String, dynamic>;
        expect(searchData['discovered_period_value'], '30');
        final objectData =
            jsonDecode(requests.last.bodyFields['data']!)
                as Map<String, dynamic>;
        expect(objectData['objname'], '2026abc');
      });

      test(
        'changing the TNS bot identity does not reuse the old cache',
        () async {
          var searchCalls = 0;
          final client = MockClient((request) async {
            if (request.url.path.endsWith('/get/search')) {
              searchCalls++;
              return http.Response(
                jsonEncode({
                  'id_code': 200,
                  'data': {'reply': []},
                }),
                200,
              );
            }
            return http.Response('not found', 404);
          });
          final realService = TransientAlertService(
            httpClient: client,
            logger: mockLogger,
          );
          addTearDown(realService.dispose);

          const settings = TransientAlertSettings(
            enabledSources: {TransientSource.tns},
            tnsApiKey: 'secret',
          );
          await realService.getAllAlerts(
            settings,
            tnsBotId: 42,
            tnsBotName: 'Skotiq Bot',
          );
          // A different bot must not be served data authenticated as the first.
          await realService.getAllAlerts(
            settings,
            tnsBotId: 43,
            tnsBotName: 'Other Bot',
          );

          expect(searchCalls, 2);
        },
      );
    });
  });
}
