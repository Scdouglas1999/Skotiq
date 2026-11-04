import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/night_history_sync.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/runtime_state_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Request _post(Map<String, dynamic> body) => Request(
  'POST',
  Uri.parse('http://localhost/api/runtime/state'),
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);

void main() {
  late ProviderContainer container;
  late List<SkotiqEvent> broadcast;
  late RuntimeStateHandlers handlers;
  var retained = <SkotiqEvent>[];

  setUp(() {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    broadcast = <SkotiqEvent>[];
    container.read(hostMutationEventHubProvider).wsBroadcast = broadcast.add;
    handlers = RuntimeStateHandlers(container, retained: () => retained);
  });

  tearDown(() => container.dispose());

  test('GET serves the latest value of every channel', () async {
    final response = await handlers.handleGetState(
      Request('GET', Uri.parse('http://localhost/api/runtime/state')),
    );
    container
        .read(lastCenteringResultProvider.notifier)
        .state = CenteringResult.success(
      finalOffsetArcsec: 9,
      iterations: 2,
      iterationHistory: const [],
    );
    final after = await handlers.handleGetState(
      Request('GET', Uri.parse('http://localhost/api/runtime/state')),
    );

    expect(response.statusCode, 200);
    final updates = (jsonDecode(await after.readAsString())['updates'] as List)
        .cast<Map<String, dynamic>>();
    final centering = updates.singleWhere(
      (u) => u['channel'] == 'centeringResult',
    );
    expect(centering['value']['finalOffsetArcsec'], 9.0);
    expect(
      updates.map((u) => u['channel']),
      containsAll(['plateSolve', 'currentFrame', 'sequenceRun']),
    );
  });

  test('POST applies a client report to the host and rebroadcasts it under '
      'the reporter', () async {
    final response = await handlers.handleReport(
      _post({
        'channel': 'centeringResult',
        'origin': 'linux-client',
        'value': {'success': false, 'iterations': 5, 'error': 'gave up'},
      }),
    );

    expect(response.statusCode, 200);
    final result = container.read(lastCenteringResultProvider);
    expect(result?.success, isFalse);
    expect(result?.errorMessage, 'gave up');
    final sent = broadcast
        .where((e) => e.eventType == hostRuntimeStateEventType)
        .map((e) => HostRuntimeUpdate.fromJson(e.data)!)
        .where((u) => u.channel == 'centeringResult' && u.value != null);
    expect(sent.single.origin, 'linux-client');
  });

  test('POST refuses a channel only the host produces', () async {
    expect(
      () => handlers.handleReport(
        _post({
          'channel': 'plateSolve',
          'origin': 'linux-client',
          'value': {'isSolving': true},
        }),
      ),
      throwsA(isA<HandlerFailure>().having((f) => f.statusCode, 'status', 404)),
    );
  });

  test('recent events leave out telemetry and sync envelopes', () async {
    SkotiqEvent event(String type, int at) => SkotiqEvent(
      timestamp: at,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: type,
      data: const {},
    );
    retained = [
      event('Started', 1),
      event('ExposureProgress', 2),
      const HostRuntimeUpdate(channel: 'plateSolve', revision: 3).toEvent(),
      event('NodeCompleted', 4),
    ];

    final response = await handlers.handleRecentEvents(
      Request('GET', Uri.parse('http://localhost/api/runtime/recent-events')),
    );

    final events = (jsonDecode(await response.readAsString())['events'] as List)
        .cast<Map<String, dynamic>>();
    expect(events.map((e) => e['eventType']), ['Started', 'NodeCompleted']);
  });

  // SY-15: a client's backfilled log stopped at "Sequence stopped" while the
  // host's went on to the integration steps after it.
  test(
    'recent events keep the newest integration progress of each phase',
    () async {
      SkotiqEvent event(String type, int at, [Map<String, dynamic>? data]) =>
          SkotiqEvent(
            timestamp: at,
            severity: EventSeverity.info,
            category: EventCategory.imaging,
            eventType: type,
            data: data ?? const {},
          );
      retained = [
        event('Stopped', 1),
        event('IntegrationProgress', 2, {
          'phase': 'registering',
          'fraction': .2,
        }),
        event('IntegrationProgress', 3, {
          'phase': 'registering',
          'fraction': .9,
        }),
        event('IntegrationProgress', 4, {
          'phase': 'integrating',
          'fraction': .5,
        }),
        event('IntegrationProgress', 5, {'phase': 'done', 'fraction': 1.0}),
      ];

      final response = await handlers.handleRecentEvents(
        Request('GET', Uri.parse('http://localhost/api/runtime/recent-events')),
      );

      final events =
          (jsonDecode(await response.readAsString())['events'] as List)
              .cast<Map<String, dynamic>>();
      expect(events.map((e) => e['timestamp']), [1, 3, 4, 5]);
    },
  );

  test('night history serves what this host gathered tonight', () async {
    final at = DateTime(2026, 11, 3, 18, 22);
    container
        .read(nightGuideSamplesProvider.notifier)
        .add(NightGuideSample(at, 0.4, -0.3));

    final response = await handlers.handleNightHistory(
      Request('GET', Uri.parse('http://localhost/api/runtime/night-history')),
    );

    final body =
        jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final history = NightHistory.fromJson(body);
    expect(history.guideSamples.single.t, at);
    expect(history.guideSamples.single.decPx, -0.3);
    expect(history.events.autofocusRuns, isEmpty);
    expect(history.solves, isEmpty);
  });
}
