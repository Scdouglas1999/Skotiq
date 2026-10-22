import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
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
    handlers = RuntimeStateHandlers(container);
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
}
