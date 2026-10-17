// POST /api/sequencer/device-retries carries a remote client's camera and
// filter-wheel retry counts to the host executor, as the FFI backend carries
// the desktop's.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

void main() {
  late ProviderContainer container;
  late _MockSequencerBackend backend;
  late SequencerHandlers handlers;

  setUp(() {
    backend = _MockSequencerBackend();
    when(
      () => backend.sequencerSetDeviceRetries(
        cameraRetries: any(named: 'cameraRetries'),
        filterWheelRetries: any(named: 'filterWheelRetries'),
      ),
    ).thenAnswer((_) async {});
    container = createHeadlessTestContainer(
      overrides: [sequencerBackendProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    handlers = SequencerHandlers(container);
  });

  Future<Response> post(Object body) => translateHandlerErrors(
    handlers.handleSequencerSetDeviceRetries(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sequencer/device-retries'),
        body: jsonEncode(body),
      ),
    ),
  );

  void expectNoPush() => verifyNever(
    () => backend.sequencerSetDeviceRetries(
      cameraRetries: any(named: 'cameraRetries'),
      filterWheelRetries: any(named: 'filterWheelRetries'),
    ),
  );

  test('forwards both counts to the executor', () async {
    final response = await post({'cameraRetries': 0, 'filterWheelRetries': 5});

    expect(response.statusCode, 200);
    verify(
      () => backend.sequencerSetDeviceRetries(
        cameraRetries: 0,
        filterWheelRetries: 5,
      ),
    ).called(1);
  });

  test('refuses a payload missing a count rather than guessing it', () async {
    final response = await post({'cameraRetries': 3});

    expect(response.statusCode, 400);
    expectNoPush();
  });

  test('refuses a count above the maximum', () async {
    final response = await post({
      'cameraRetries': kMaxDeviceRetries + 1,
      'filterWheelRetries': 3,
    });

    expect(response.statusCode, 400);
    expectNoPush();
  });
}
