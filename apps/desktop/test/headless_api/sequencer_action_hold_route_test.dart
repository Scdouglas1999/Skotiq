// A manual action holds the run it paused, on whichever client it runs. The
// host's REST routes answer every other resume or skip with a 409 the
// caller can read, never a silent OK; the action's own release and a stop
// go through.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:skotiq_desktop/headless_api/request_context.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

class _StoppedExecutor extends Fake implements SequenceExecutor {
  var stops = 0;

  @override
  Future<void> stop({
    bool preserveCheckpoint = false,
    RunStopOrigin? origin,
  }) async => stops++;
}

const _held = bridge_api.SkotiqError.refused(
  kind: bridge_api.Refusal.runHeldByAction,
  message: 'A manual action holds the run paused.',
);

Request _post(String path, {Object? body, String? identity}) => Request(
  'POST',
  Uri.parse('http://localhost/api/sequencer/$path'),
  body: body == null ? null : jsonEncode(body),
  context: {if (identity != null) authIdentityContextKey: identity},
);

Future<Map<String, Object?>> _bodyOf(Response response) async =>
    (jsonDecode(await response.readAsString()) as Map).cast<String, Object?>();

void main() {
  late _MockSequencerBackend backend;
  late _StoppedExecutor executor;
  late ProviderContainer container;
  late SequencerHandlers handlers;

  void hostReports({required bool held}) =>
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async =>
            SequencerStatus(state: 'paused', progress: 0.2, heldByAction: held),
      );

  setUp(() {
    backend = _MockSequencerBackend();
    executor = _StoppedExecutor();
    when(
      () => backend.sequencerResume(
        releasingHoldOf: any(named: 'releasingHoldOf'),
      ),
    ).thenAnswer((_) async {});
    when(() => backend.sequencerSkip()).thenAnswer((_) async {});
    when(
      () => backend.sequencerHoldForAction(holder: any(named: 'holder')),
    ).thenAnswer((_) async {});
    container = createHeadlessTestContainer(
      overrides: [
        sequencerBackendProvider.overrideWithValue(backend),
        sequenceExecutorProvider.overrideWithValue(executor),
      ],
    );
    handlers = SequencerHandlers(container);
  });

  tearDown(() => container.dispose());

  test('resume and skip of a held run answer 409 and send nothing', () async {
    hostReports(held: true);

    for (final call in [
      (verb: 'resume', run: handlers.handleSequencerResume),
      (verb: 'skip', run: handlers.handleSequencerSkip),
    ]) {
      final response = await translateHandlerErrors(call.run(_post(call.verb)));
      expect(response.statusCode, HttpStatus.conflict, reason: call.verb);
      final body = await _bodyOf(response);
      expect(body['error'], ApiErrorCodes.runHeldByAction);
      expect(body['message'], contains('a manual action holds the run'));
    }
    verifyNever(
      () => backend.sequencerResume(
        releasingHoldOf: any(named: 'releasingHoldOf'),
      ),
    );
    verifyNever(() => backend.sequencerSkip());
  });

  test(
    'a hold taken after the status read is still refused by the run',
    () async {
      hostReports(held: false);
      when(
        () => backend.sequencerResume(
          releasingHoldOf: any(named: 'releasingHoldOf'),
        ),
      ).thenThrow(_held);
      when(() => backend.sequencerSkip()).thenThrow(_held);

      for (final call in [
        (verb: 'resume', run: handlers.handleSequencerResume),
        (verb: 'skip', run: handlers.handleSequencerSkip),
      ]) {
        final response = await translateHandlerErrors(
          call.run(_post(call.verb)),
        );
        expect(response.statusCode, HttpStatus.conflict, reason: call.verb);
        expect(
          (await _bodyOf(response))['error'],
          ApiErrorCodes.runHeldByAction,
        );
      }
    },
  );

  test("the action's release resumes the run in the caller's name", () async {
    hostReports(held: true);

    final response = await translateHandlerErrors(
      handlers.handleSequencerResume(
        _post('resume', body: {'releasesHold': true}, identity: 'phone-token'),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    verify(
      () => backend.sequencerResume(releasingHoldOf: 'phone-token'),
    ).called(1);
  });

  test("a second client's release is refused by the run", () async {
    hostReports(held: true);
    when(
      () => backend.sequencerResume(releasingHoldOf: 'tablet-token'),
    ).thenThrow(_held);

    final response = await translateHandlerErrors(
      handlers.handleSequencerResume(
        _post('resume', body: {'releasesHold': true}, identity: 'tablet-token'),
      ),
    );

    expect(response.statusCode, HttpStatus.conflict);
    expect((await _bodyOf(response))['error'], ApiErrorCodes.runHeldByAction);
  });

  test('a second hold is refused', () async {
    hostReports(held: true);
    when(
      () => backend.sequencerHoldForAction(holder: 'tablet-token'),
    ).thenThrow(_held);

    final response = await translateHandlerErrors(
      handlers.handleSequencerPause(
        _post('pause', body: {'forAction': true}, identity: 'tablet-token'),
      ),
    );

    expect(response.statusCode, HttpStatus.conflict);
    expect((await _bodyOf(response))['error'], ApiErrorCodes.runHeldByAction);
  });

  test(
    'a release whose run another pause took over answers 409 naming it',
    () async {
      hostReports(held: true);
      when(
        () => backend.sequencerResume(releasingHoldOf: 'phone-token'),
      ).thenThrow(const RunStillPaused('Weather turned unsafe'));

      final response = await translateHandlerErrors(
        handlers.handleSequencerResume(
          _post(
            'resume',
            body: {'releasesHold': true},
            identity: 'phone-token',
          ),
        ),
      );

      expect(response.statusCode, HttpStatus.conflict);
      final body = await _bodyOf(response);
      expect(body['error'], ApiErrorCodes.runStillPaused);
      expect(body['message'], contains('Weather turned unsafe'));
    },
  );

  test('a pause names who asked for it', () async {
    hostReports(held: true);
    when(
      () => backend.sequencerPause(origin: any(named: 'origin')),
    ).thenAnswer((_) async {});

    final response = await translateHandlerErrors(
      handlers.handleSequencerPause(
        _post('pause', body: {'origin': 'Weather turned unsafe'}),
      ),
    );

    expect(response.statusCode, HttpStatus.ok);
    verify(
      () => backend.sequencerPause(origin: 'Weather turned unsafe'),
    ).called(1);
  });

  test('a held run still stops', () async {
    hostReports(held: true);

    final response = await translateHandlerErrors(
      handlers.handleSequencerStop(_post('stop')),
    );

    expect(response.statusCode, HttpStatus.ok);
    expect(executor.stops, 1);
  });
}
