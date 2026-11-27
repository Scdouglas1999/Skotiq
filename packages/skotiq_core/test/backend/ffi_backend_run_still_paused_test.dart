// A manual action's release finds the run taken over by another pause: the
// refusal the native resume raises reaches the app as RunStillPaused naming
// that pause once, in the words its origin gave.

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';

import '../harness/reply_fixture.dart';

/// The refusal as the native release raises it
/// (`test_fixtures/ffi_replies/run_still_paused.json`, written by the
/// bridge's `still_paused` test).
final _refusal = bridge.SkotiqError.runStillPaused(
  pausedBy: replyFixtureObject('run_still_paused')['pausedBy'] as String,
);

class _Native extends Mock implements bridge.RustLibApi {
  @override
  Future<void> crateApiSequencerLifecycleApiSequencerResume({
    String? releasesHoldOf,
  }) async => throw _refusal;
}

void main() {
  setUpAll(() => bridge.NativeBridge.initMock(_Native()));
  tearDownAll(bridge.NativeBridge.disposeMock);

  test('the release names the pause that keeps the run paused once', () async {
    final error = await FfiBackend()
        .sequencerResume(releasingHoldOf: hostActionHolder)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<RunStillPaused>());
    final stillPaused = error! as RunStillPaused;
    expect(stillPaused.pausedBy, 'weather turned unsafe');
    expect('still paused'.allMatches('$stillPaused').length, 1);
  });
}
