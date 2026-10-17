// POST /api/sequencer/quality-policy carries a remote client's "Stop the run
// for quality problems" setting to the host executor, as the FFI backend
// carries the desktop's.

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
      () => backend.sequencerSetStopOnQualityProblems(any()),
    ).thenAnswer((_) async {});
    container = createHeadlessTestContainer(
      overrides: [sequencerBackendProvider.overrideWithValue(backend)],
    );
    addTearDown(container.dispose);
    handlers = SequencerHandlers(container);
  });

  Future<Response> post(Object body) => translateHandlerErrors(
    handlers.handleSequencerSetQualityPolicy(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sequencer/quality-policy'),
        body: jsonEncode(body),
      ),
    ),
  );

  test('forwards the setting to the executor', () async {
    final response = await post({'stopOnQualityProblems': true});

    expect(response.statusCode, 200);
    verify(() => backend.sequencerSetStopOnQualityProblems(true)).called(1);
  });

  test(
    'refuses a payload without the setting rather than guessing it',
    () async {
      final response = await post({});

      expect(response.statusCode, 400);
      verifyNever(() => backend.sequencerSetStopOnQualityProblems(any()));
    },
  );
}
