import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/scheduler_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _SchedulerSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> parkForEndOfNight() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
}

SchedulerEngine _testEngine() => SchedulerEngine(
  site: const SchedulerSite(
    latitudeDegrees: 40,
    longitudeDegrees: -75,
    localOffset: Duration(hours: -5),
  ),
  sequenceSink: _SchedulerSink(),
  candidateLoader: () async => <SchedulerCandidate>[
    SchedulerCandidate(
      targetId: 1,
      name: 'M42',
      raHours: 5.5,
      decDegrees: -5.4,
      userPriority: 5,
      goals: const [],
      capturedCounts: const [],
      constraints: const [],
      horizonProfiles: const {},
      availableFilters: const [],
    ),
  ],
  clock: () => DateTime.utc(2026, 7, 13, 4),
);

SchedulerEngine _emptyTestEngine() => SchedulerEngine(
  site: const SchedulerSite(
    latitudeDegrees: 40,
    longitudeDegrees: -75,
    localOffset: Duration(hours: -5),
  ),
  sequenceSink: _SchedulerSink(),
  candidateLoader: () async => const <SchedulerCandidate>[],
  clock: () => DateTime.utc(2026, 7, 13, 4),
);

const _healthySchedulerReadiness = SchedulerStartReadiness(
  issues: <SchedulerReadinessIssue>[],
  available: true,
  solverRequired: true,
);

const _blockedSchedulerReadiness = SchedulerStartReadiness(
  issues: [
    SchedulerReadinessIssue(
      id: SchedulerReadinessIssueId.camera,
      severity: SchedulerReadinessSeverity.blocker,
      title: 'Camera',
      detail: 'Camera is not connected.',
    ),
  ],
  available: true,
  solverRequired: true,
);

const _warningSchedulerReadiness = SchedulerStartReadiness(
  issues: [
    SchedulerReadinessIssue(
      id: SchedulerReadinessIssueId.weather,
      severity: SchedulerReadinessSeverity.warning,
      title: 'Weather monitoring',
      detail: 'Weather monitoring is disabled.',
    ),
  ],
  available: true,
  solverRequired: true,
);

void main() {
  group('SchedulerHandlers', () {
    late ProviderContainer container;
    late SchedulerHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = SchedulerHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test('altitude missing coordinates returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalculateAltitude(
          Request('GET', Uri.parse('http://localhost/api/scheduler/altitude')),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Missing required parameters: ra and dec');
    });

    test('altitude invalid time returns JSON bad request', () async {
      final response = await translateHandlerErrors(
        handlers.handleCalculateAltitude(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/scheduler/altitude?ra=12.5&dec=45&time=nope',
            ),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.headers['content-type'], 'application/json');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(
        body['error'],
        'Invalid time format. Use ISO8601 or epoch milliseconds.',
      );
    });

    test(
      'optimize targets malformed payload returns JSON internal error',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleOptimizeTargets(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/optimize-targets'),
              body: '{',
            ),
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

    test(
      'priority optimization puts higher values first and keeps ties stable',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        final scoped = ProviderContainer(
          overrides: [databaseProvider.overrideWithValue(database)],
        );
        addTearDown(() async {
          scoped.dispose();
          await database.close();
        });
        await database.settingsDao.setObserverLatitude(40);
        await database.settingsDao.setObserverLongitude(-74);

        Future<int> addTarget(String name, int priority) {
          return database.targetsDao.createTarget(
            TargetsCompanion.insert(
              name: name,
              ra: 5,
              dec: 20,
              priority: Value(priority),
            ),
          );
        }

        final lowId = await addTarget('Low', 2);
        final highFirstId = await addTarget('High first', 9);
        final highSecondId = await addTarget('High second', 9);
        final scopedHandlers = SchedulerHandlers(scoped);
        final response = await translateHandlerErrors(
          scopedHandlers.handleOptimizeTargets(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/optimize-targets'),
              body: jsonEncode({
                'targetIds': [lowId, highFirstId, highSecondId],
                'strategy': 'priority',
              }),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        final body = jsonDecode(await response.readAsString()) as Map;
        final optimized = body['optimizedTargets'] as List;
        expect(optimized.map((target) => (target as Map)['targetName']), [
          'High first',
          'High second',
          'Low',
        ]);
      },
    );

    test(
      'rise/set and hours-above reject invalid sky queries before DB work',
      () async {
        final guarded = ProviderContainer(
          overrides: [
            databaseProvider.overrideWith(
              (ref) => throw StateError('database must not be resolved'),
            ),
          ],
        );
        addTearDown(guarded.dispose);
        final guardedHandlers = SchedulerHandlers(guarded);
        final cases = <String>[
          'ra=NaN&dec=0',
          'ra=-0.01&dec=0',
          'ra=24.01&dec=0',
          'ra=12&dec=Infinity',
          'ra=12&dec=-90.01',
          'ra=12&dec=90.01',
          'ra=12&dec=0&minAltitude=nope',
          'ra=12&dec=0&minAltitude=-90.01',
          'ra=12&dec=0&minAltitude=90.01',
        ];

        for (final endpoint in ['rise-set', 'hours-above-horizon']) {
          for (final query in cases) {
            final request = Request(
              'GET',
              Uri.parse('http://localhost/api/scheduler/$endpoint?$query'),
            );
            final response = await translateHandlerErrors(
              endpoint == 'rise-set'
                  ? guardedHandlers.handleCalculateRiseSet(request)
                  : guardedHandlers.handleCalculateHoursAbove(request),
            );
            expect(
              response.statusCode,
              HttpStatus.badRequest,
              reason: '$endpoint?$query',
            );
          }
        }
      },
    );

    test(
      'state and control endpoints expose the host scheduler lifecycle',
      () async {
        final engine = _testEngine();
        final scoped = ProviderContainer(
          overrides: [
            schedulerEngineProvider.overrideWithValue(engine),
            schedulerEngineReadyProvider.overrideWith((ref) async => engine),
            schedulerStartReadinessProvider.overrideWithValue(
              _healthySchedulerReadiness,
            ),
          ],
        );
        addTearDown(() async {
          scoped.dispose();
          await engine.dispose();
        });
        final scopedHandlers = SchedulerHandlers(scoped);

        final initial = await scopedHandlers.handleGetState(
          Request('GET', Uri.parse('http://localhost/api/scheduler/state')),
        );
        expect(initial.statusCode, HttpStatus.ok);
        final initialBody = jsonDecode(await initial.readAsString()) as Map;
        expect((initialBody['status'] as Map)['state'], 'idle');

        final started = await translateHandlerErrors(
          scopedHandlers.handleControl(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/control'),
              body: jsonEncode({'action': 'start'}),
            ),
          ),
        );
        expect(started.statusCode, HttpStatus.ok);
        final startedBody = jsonDecode(await started.readAsString()) as Map;
        expect((startedBody['status'] as Map)['state'], 'running');
        expect(engine.status.state, SchedulerState.running);
      },
    );

    test(
      'scheduler control rejects unknown actions before touching the engine',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleControl(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/control'),
              body: jsonEncode({'action': 'launch'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
      },
    );

    test(
      'scheduler start rejects an empty target set and remains idle',
      () async {
        final engine = _emptyTestEngine();
        final scoped = ProviderContainer(
          overrides: [
            schedulerEngineProvider.overrideWithValue(engine),
            schedulerEngineReadyProvider.overrideWith((ref) async => engine),
            schedulerStartReadinessProvider.overrideWithValue(
              _healthySchedulerReadiness,
            ),
          ],
        );
        addTearDown(() async {
          scoped.dispose();
          await engine.dispose();
        });
        final scopedHandlers = SchedulerHandlers(scoped);

        final response = await translateHandlerErrors(
          scopedHandlers.handleControl(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/control'),
              body: jsonEncode({'action': 'start'}),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.badRequest);
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], contains('Add at least one target'));
        expect(engine.status.state, SchedulerState.idle);
      },
    );

    test('scheduler start blocks at the host command boundary', () async {
      final engine = _testEngine();
      final scoped = ProviderContainer(
        overrides: [
          schedulerEngineProvider.overrideWithValue(engine),
          schedulerEngineReadyProvider.overrideWith((ref) async => engine),
          schedulerStartReadinessProvider.overrideWithValue(
            _blockedSchedulerReadiness,
          ),
        ],
      );
      addTearDown(() async {
        scoped.dispose();
        await engine.dispose();
      });

      final response = await translateHandlerErrors(
        SchedulerHandlers(scoped).handleControl(
          Request(
            'POST',
            Uri.parse('http://localhost/api/scheduler/control'),
            body: jsonEncode({'action': 'start'}),
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(engine.status.state, SchedulerState.idle);
    });

    test(
      'scheduler warning requires confirmation and accepts it explicitly',
      () async {
        final engine = _testEngine();
        final scoped = ProviderContainer(
          overrides: [
            schedulerEngineProvider.overrideWithValue(engine),
            schedulerEngineReadyProvider.overrideWith((ref) async => engine),
            schedulerStartReadinessProvider.overrideWithValue(
              _warningSchedulerReadiness,
            ),
          ],
        );
        addTearDown(() async {
          scoped.dispose();
          await engine.dispose();
        });
        final handlers = SchedulerHandlers(scoped);

        final denied = await translateHandlerErrors(
          handlers.handleControl(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/control'),
              body: jsonEncode({'action': 'start'}),
            ),
          ),
        );
        expect(denied.statusCode, HttpStatus.badRequest);
        expect(engine.status.state, SchedulerState.idle);

        final accepted = await translateHandlerErrors(
          handlers.handleControl(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/control'),
              body: jsonEncode({'action': 'start', 'confirmWarnings': true}),
            ),
          ),
        );
        expect(accepted.statusCode, HttpStatus.ok);
        expect(engine.status.state, SchedulerState.running);
      },
    );

    test(
      'scheduler config validates ranges, persists, then updates the engine',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        final engine = _testEngine();
        final scoped = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(database),
            schedulerEngineProvider.overrideWithValue(engine),
          ],
        );
        addTearDown(() async {
          scoped.dispose();
          await engine.dispose();
          await database.close();
        });
        final scopedHandlers = SchedulerHandlers(scoped);
        final config = SchedulerConfig.defaults.copyWith(
          minAltitudeDegrees: 34,
          hysteresisRatio: 1.4,
          weights: SchedulerWeights.defaults.copyWith(altitude: 2.2),
        );

        final response = await translateHandlerErrors(
          scopedHandlers.handleUpdateConfig(
            Request(
              'POST',
              Uri.parse('http://localhost/api/scheduler/config'),
              body: jsonEncode(config.toStorageJson()),
            ),
          ),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(engine.config.minAltitudeDegrees, 34);
        expect(engine.config.weights.altitude, 2.2);
        expect(await scoped.read(schedulerConfigStoreProvider).load(), config);
      },
    );
  });
}
