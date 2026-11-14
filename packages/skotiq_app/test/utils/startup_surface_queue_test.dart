import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/startup_surface_queue.dart';

void main() {
  test('prompts outside the start-up order show one at a time', () async {
    final queue = StartupSurfaceQueue();
    final releaseFirst = Completer<void>();
    final events = <String>[];

    final first = queue.run(() async {
      events.add('first-start');
      await releaseFirst.future;
      events.add('first-end');
    });
    final second = queue.run(() async {
      events.add('second');
    });

    await Future<void>.delayed(Duration.zero);
    expect(events, ['first-start']);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(events, ['first-start', 'first-end', 'second']);
  });

  test('a failed prompt releases the next one', () async {
    final queue = StartupSurfaceQueue();
    var secondRan = false;

    final first = queue.run<void>(() async {
      throw StateError('dialog failed');
    });
    final second = queue.run(() async {
      secondRan = true;
    });

    await expectLater(first, throwsStateError);
    await second;
    expect(secondRan, isTrue);
  });

  test('a later surface that is ready first waits for the earlier one',
      () async {
    final queue = StartupSurfaceQueue()
      ..expect(StartupSurface.databaseRecovery)
      ..expect(StartupSurface.quickStart);
    final events = <String>[];
    final dismissRecovery = Completer<void>();

    // Quick Start finishes its check first.
    final quickStart = queue.turn(StartupSurface.quickStart, () async {
      events.add('quick start');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    final recovery = queue.turn(StartupSurface.databaseRecovery, () async {
      events.add('recovery shown');
      await dismissRecovery.future;
      events.add('recovery dismissed');
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, ['recovery shown']);

    dismissRecovery.complete();
    await Future.wait([recovery, quickStart]);
    expect(events, ['recovery shown', 'recovery dismissed', 'quick start']);
  });

  test('a surface that passes lets the later ones through', () async {
    final queue = StartupSurfaceQueue()
      ..expect(StartupSurface.checkpointRecovery)
      ..expect(StartupSurface.equipmentOnboarding);
    var onboarded = false;

    final onboarding = queue.turn(
      StartupSurface.equipmentOnboarding,
      () async => onboarded = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(onboarded, isFalse);

    queue.pass(StartupSurface.checkpointRecovery);
    await onboarding;
    expect(onboarded, isTrue);
  });

  test('a surface nobody expected does not hold the others', () async {
    final queue = StartupSurfaceQueue()
      ..expect(StartupSurface.yourSkyOffNotice);
    var shown = false;
    await queue.turn(StartupSurface.yourSkyOffNotice, () async => shown = true);
    expect(shown, isTrue);
  });

  test('an event prompt waits for every start-up surface', () async {
    final queue = StartupSurfaceQueue()..expect(StartupSurface.quickStart);
    final events = <String>[];

    final siteCard = queue.run(() async => events.add('site card'));
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);

    await queue.turn(
      StartupSurface.quickStart,
      () async => events.add('quick start'),
    );
    await siteCard;
    expect(events, ['quick start', 'site card']);
  });

  test('a surface that fails while showing still lets the next one through',
      () async {
    final queue = StartupSurfaceQueue()
      ..expect(StartupSurface.interruptedSession)
      ..expect(StartupSurface.quickStart);

    final failing = queue.turn<void>(
      StartupSurface.interruptedSession,
      () async => throw StateError('no navigator'),
    );
    var shown = false;
    final next =
        queue.turn(StartupSurface.quickStart, () async => shown = true);

    await expectLater(failing, throwsStateError);
    await next;
    expect(shown, isTrue);
  });

  group('surfaces that ask the same question', () {
    test('Quick Start is the checkpoint prompt asked again', () {
      expect(StartupSurface.quickStart.sameQuestionAs, {
        StartupSurface.checkpointRecovery,
      });
      for (final surface in StartupSurface.values) {
        for (final earlier in surface.sameQuestionAs) {
          expect(earlier.index, lessThan(surface.index), reason: surface.name);
        }
      }
    });

    test(
        'an answered checkpoint prompt settles Quick Start; one that was '
        'only shown, or passed, does not', () async {
      final queue = StartupSurfaceQueue()
        ..expect(StartupSurface.checkpointRecovery)
        ..expect(StartupSurface.quickStart);
      expect(queue.alreadyAnswered(StartupSurface.quickStart), isFalse);

      // Shown, but left for later (a failed restore, a linked client).
      await queue.turn<void>(StartupSurface.checkpointRecovery, () async {});
      expect(queue.alreadyAnswered(StartupSurface.quickStart), isFalse);

      final later = StartupSurfaceQueue()
        ..expect(StartupSurface.checkpointRecovery)
        ..expect(StartupSurface.quickStart);
      var quickStartSawAnswer = false;
      final quickStart = later.turn<void>(StartupSurface.quickStart, () async {
        quickStartSawAnswer = later.alreadyAnswered(StartupSurface.quickStart);
      });
      await later.turn<void>(StartupSurface.checkpointRecovery, () async {
        later.answered(StartupSurface.checkpointRecovery);
      });
      await quickStart;
      expect(quickStartSawAnswer, isTrue);
      // Nothing else is settled by it.
      expect(
          later.alreadyAnswered(StartupSurface.equipmentOnboarding), isFalse);
    });
  });
}
