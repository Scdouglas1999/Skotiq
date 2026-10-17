import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockSequencerBackend extends Mock implements SequencerBackend {}

SequencerStatus _status(String state) => SequencerStatus(
  state: state,
  currentNodeId: 'root',
  currentNodeName: 'D4 root',
  progress: 0.125,
  message: 'Cancelled: D4 root',
);

Request _post(String path) =>
    Request('POST', Uri.parse('http://localhost/api/sequencer/$path'));

Future<Map<String, Object?>> _bodyOf(Response response) async =>
    (jsonDecode(await response.readAsString()) as Map).cast<String, Object?>();

/// What the pause / resume / skip contract is measured against.
///
/// Every state the executor can report while a run has ENDED or was never
/// started. Measured live against the release bundle on the cancelled leg:
///
/// ```
/// POST /api/sequencer/stop   -> {"status":"stopped","wasRunning":true}
/// GET  /api/sequencer/status -> {"state":"cancelled", ...}
/// POST /api/sequencer/pause  -> 200 {"status":"paused"}          <- the lie
/// GET  /api/sequencer/status -> {"state":"cancelled", ...}       <- unchanged
/// GET  /api/run-watch/snapshot
///        -> sequencer.state=cancelled, sequencer.progress.state=paused
/// ```
///
/// The pause reached the executor, its `paused` landed in the host's
/// `SequenceProgress`, and the phone rendered a paused night that survived
/// every reload. A resume posted the same way made it `running`.
const _endedStates = [
  'idle',
  'completed',
  'failed',
  'cancelled',
  'stopped',
  'error',
];

void main() {
  late _MockSequencerBackend backend;
  late ProviderContainer container;
  late SequencerHandlers handlers;

  setUp(() {
    backend = _MockSequencerBackend();
    when(() => backend.sequencerPause()).thenAnswer((_) async {});
    when(() => backend.sequencerResume()).thenAnswer((_) async {});
    when(() => backend.sequencerSkip()).thenAnswer((_) async {});
    container = createHeadlessTestContainer(
      overrides: [sequencerBackendProvider.overrideWithValue(backend)],
    );
    handlers = SequencerHandlers(container);
  });

  tearDown(() => container.dispose());

  group('pause/resume/skip refuse a run that is not in flight', () {
    for (final state in _endedStates) {
      test('$state refuses all three with a typed 409', () async {
        when(
          () => backend.sequencerGetStatus(),
        ).thenAnswer((_) async => _status(state));

        for (final call in [
          (verb: 'pause', run: handlers.handleSequencerPause),
          (verb: 'resume', run: handlers.handleSequencerResume),
          (verb: 'skip', run: handlers.handleSequencerSkip),
        ]) {
          final response = await translateHandlerErrors(
            call.run(_post(call.verb)),
          );
          expect(
            response.statusCode,
            HttpStatus.conflict,
            reason: '${call.verb} on a $state sequencer must refuse',
          );
          final body = await _bodyOf(response);
          expect(body['error'], 'sequencer_not_running');
          expect(
            body['message'],
            'No sequence is running; nothing to '
            '${call.verb}.',
          );
          // The did-anything-happen verdict stop already carries, so one
          // client check covers every control.
          expect(body['wasRunning'], isFalse);
          expect(body['state'], state);
        }

        // And the command never reached the executor, so nothing could have
        // overwritten the state of a run that had already ended.
        verifyNever(() => backend.sequencerPause());
        verifyNever(() => backend.sequencerResume());
        verifyNever(() => backend.sequencerSkip());
      });
    }
  });

  group('a run in flight still takes all three', () {
    // The deny-list direction matters: `stopping` and `recovering` are runs
    // very much in flight — a sequence retrying after unsafe weather is
    // exactly what an operator reaches for Pause over — and an allow-list of
    // {running, paused} would refuse them.
    for (final state in ['running', 'paused', 'recovering', 'stopping']) {
      test('$state admits pause, resume and skip', () async {
        when(
          () => backend.sequencerGetStatus(),
        ).thenAnswer((_) async => _status(state));

        final pause = await translateHandlerErrors(
          handlers.handleSequencerPause(_post('pause')),
        );
        expect(pause.statusCode, HttpStatus.ok);
        final pauseBody = await _bodyOf(pause);
        expect(pauseBody['status'], 'paused');
        expect(pauseBody['wasRunning'], isTrue);

        final resume = await translateHandlerErrors(
          handlers.handleSequencerResume(_post('resume')),
        );
        expect(resume.statusCode, HttpStatus.ok);
        expect((await _bodyOf(resume))['wasRunning'], isTrue);

        final skip = await translateHandlerErrors(
          handlers.handleSequencerSkip(_post('skip')),
        );
        expect(skip.statusCode, HttpStatus.ok);
        expect((await _bodyOf(skip))['wasRunning'], isTrue);

        verify(() => backend.sequencerPause()).called(1);
        verify(() => backend.sequencerResume()).called(1);
        verify(() => backend.sequencerSkip()).called(1);
      });
    }
  });

  test('a state this host cannot read refuses rather than guessing', () async {
    when(
      () => backend.sequencerGetStatus(),
    ).thenThrow(StateError('bridge channel closed'));

    final response = await translateHandlerErrors(
      handlers.handleSequencerPause(_post('pause')),
    );
    expect(response.statusCode, HttpStatus.serviceUnavailable);
    final body = await _bodyOf(response);
    expect(body['error'], 'sequencer_state_unreadable');
    expect(body['message'], contains('could not be read'));
    // No verdict is offered, because this host has not earned one: stating
    // wasRunning either way would be a claim about a rig nobody can see.
    expect(body.containsKey('wasRunning'), isFalse);
    verifyNever(() => backend.sequencerPause());
  });

  group('GET /api/sequencer/status carries the run\'s target', () {
    test('the target the executor named reaches the payload', () async {
      when(
        () => backend.sequencerGetStatus(),
      ).thenAnswer((_) async => _status('running'));
      container
          .read(sequenceProgressProvider.notifier)
          .updateProgress(currentTarget: 'M Long Field');

      final response = await handlers.handleSequencerStatus(
        Request('GET', Uri.parse('http://localhost/api/sequencer/status')),
      );
      expect(response.statusCode, HttpStatus.ok);
      final body = await _bodyOf(response);
      // The web dashboard's "Current target" reads this payload. Without the
      // field it fell back to the imaging session's name — the SEQUENCE's name
      // on a headless run — and then to the root node's, so it read
      // "M long night" mid-run and "Live root" once the run ended.
      expect(body['currentTarget'], 'M Long Field');
      expect(
        body['currentNodeName'],
        'D4 root',
        reason: 'the node keeps its own field',
      );
    });

    test(
      'a run that has named no target reports null, not a stand-in',
      () async {
        when(
          () => backend.sequencerGetStatus(),
        ).thenAnswer((_) async => _status('running'));

        final response = await handlers.handleSequencerStatus(
          Request('GET', Uri.parse('http://localhost/api/sequencer/status')),
        );
        final body = await _bodyOf(response);
        expect(body.containsKey('currentTarget'), isTrue);
        expect(body['currentTarget'], isNull);
      },
    );
  });
}
