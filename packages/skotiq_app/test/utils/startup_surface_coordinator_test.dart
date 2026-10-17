import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/startup_surface_coordinator.dart';

void main() {
  test('startup surfaces run one at a time in request order', () async {
    final coordinator = StartupSurfaceCoordinator();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = coordinator.run(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
    });
    final second = coordinator.run(() async {
      events.add('second');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second']);
  });

  test('a failed surface releases the next queued surface', () async {
    final coordinator = StartupSurfaceCoordinator();
    var secondRan = false;

    final first = coordinator.run<void>(() async {
      throw StateError('dialog failed');
    });
    final second = coordinator.run(() async {
      secondRan = true;
    });

    await expectLater(first, throwsStateError);
    await second;
    expect(secondRan, isTrue);
  });
}
