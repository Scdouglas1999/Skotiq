import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/autofocus_preview_feeder.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';

AutofocusOverlayState _running(int point) =>
    AutofocusOverlayState(isRunning: true, currentPoint: point, totalPoints: 9);

void main() {
  // Owner, live night 2026-10-17: AF frames never appeared in the Imaging
  // preview while autofocus ran.
  test(
    'every new autofocus point fetches the frame it was measured on',
    () async {
      var fetches = 0;
      final feeder = AutofocusPreviewFeeder(() async => fetches++);

      feeder.onOverlayChanged(null, _running(1));
      await pumpEventQueue();
      feeder.onOverlayChanged(_running(1), _running(1)); // same point, new HFR
      await pumpEventQueue();
      feeder.onOverlayChanged(_running(1), _running(2));
      await pumpEventQueue();

      expect(fetches, 2);
    },
  );

  test('an idle or finished overlay fetches nothing', () async {
    var fetches = 0;
    final feeder = AutofocusPreviewFeeder(() async => fetches++);

    feeder.onOverlayChanged(null, const AutofocusOverlayState());
    feeder.onOverlayChanged(
      _running(9),
      const AutofocusOverlayState(isRunning: false, currentPoint: 9),
    );
    await pumpEventQueue();

    expect(fetches, 0);
  });

  test(
    'points that arrive during a slow fetch queue one more, not many',
    () async {
      var fetches = 0;
      final gate = Completer<void>();
      final feeder = AutofocusPreviewFeeder(() async {
        fetches++;
        if (fetches == 1) await gate.future;
      });

      feeder.onOverlayChanged(null, _running(1));
      feeder.onOverlayChanged(_running(1), _running(2));
      feeder.onOverlayChanged(_running(2), _running(3));
      feeder.onOverlayChanged(_running(3), _running(4));
      gate.complete();
      await pumpEventQueue();

      expect(fetches, 2);
    },
  );

  test('a failed fetch does not stop the next point being shown', () async {
    var calls = 0;
    final feeder = AutofocusPreviewFeeder(() async {
      calls++;
      if (calls == 1) throw StateError('camera busy');
    });

    feeder.onOverlayChanged(null, _running(1));
    await pumpEventQueue();
    feeder.onOverlayChanged(_running(1), _running(2));
    await pumpEventQueue();

    expect(calls, 2);
  });
}
