import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/tours/tour.dart';
import 'package:skotiq_app/tours/tour_runner.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FailingDao extends TutorialProgressDao {
  _FailingDao(super.db);

  bool fail = false;

  @override
  Future<void> saveProgress(String category, int stepIndex) {
    if (fail) throw StateError('write failed');
    return super.saveProgress(category, stepIndex);
  }

  @override
  Future<void> markCompleted(String category) {
    if (fail) throw StateError('write failed');
    return super.markCompleted(category);
  }

  @override
  Future<void> markDismissed(String category) {
    if (fail) throw StateError('write failed');
    return super.markDismissed(category);
  }

  @override
  Future<void> restartProgress(String category) {
    if (fail) throw StateError('write failed');
    return super.restartProgress(category);
  }
}

void main() {
  late SkotiqDatabase db;

  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// A runner as a fresh launch of the app would build it, on the same
  /// database.
  Future<TourRunner> launch() async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final runner = container.read(tourRunnerProvider.notifier);
    await runner.ready;
    return runner;
  }

  for (final tour in Tour.values) {
    test('${tour.name} runs from its first step to its last and completes',
        () async {
      final runner = await launch();
      await runner.start(tour);
      expect(runner.state.active, tour);
      expect(runner.state.isFirstStep, isTrue);

      for (var i = 0; i < tour.steps.length - 1; i++) {
        expect(runner.state.step, tour.steps[i]);
        await runner.next();
      }
      expect(runner.state.isLastStep, isTrue);
      await runner.next();

      expect(runner.state.active, isNull);
      expect(runner.state.isCompleted(tour), isTrue);
      expect(runner.state.stepsDone(tour), tour.steps.length);
      expect((await launch()).state.isCompleted(tour), isTrue);
    });
  }

  test('Back steps back and stops at the first step', () async {
    final runner = await launch();
    await runner.start(Tour.imaging);
    await runner.next();
    await runner.next();
    await runner.back();
    expect(runner.state.stepIndex, 1);
    await runner.back();
    await runner.back();
    expect(runner.state.stepIndex, 0);
    expect(runner.state.active, Tour.imaging);
  });

  test('progress survives a restart and Resume picks it up', () async {
    final first = await launch();
    await first.start(Tour.automatedImaging);
    await first.next();
    await first.next();

    final second = await launch();
    expect(second.state.active, isNull, reason: 'a tour never opens itself');
    expect(second.state.stepsDone(Tour.automatedImaging), 2);
    await second.resume(Tour.automatedImaging);
    expect(second.state.active, Tour.automatedImaging);
    expect(second.state.stepIndex, 2);
  });

  test('the walkthrough resumes on its step like any other tour', () async {
    final first = await launch();
    await first.start(Tour.firstNight);
    await first.next();
    await first.next();
    await first.next();
    first.close();
    expect(first.state.active, isNull);

    final second = await launch();
    await second.resume(Tour.firstNight);
    expect(second.state.stepIndex, 3);
    expect(second.state.step!.id, 'fn_cool_and_focus');
  });

  test('Skip ends the tour, keeps the step and is remembered', () async {
    final runner = await launch();
    await runner.start(Tour.equipment);
    await runner.next();
    await runner.skip();
    expect(runner.state.active, isNull);
    expect(runner.state.progress[Tour.equipment]!.skipped, isTrue);
    expect(runner.state.isCompleted(Tour.equipment), isFalse);

    final relaunched = await launch();
    expect(relaunched.state.progress[Tour.equipment]!.skipped, isTrue);
    await relaunched.resume(Tour.equipment);
    expect(relaunched.state.stepIndex, 1);
  });

  test('Start begins again, whatever was saved', () async {
    final runner = await launch();
    await runner.start(Tour.weather);
    await runner.finish();
    expect(runner.state.isCompleted(Tour.weather), isTrue);

    await runner.start(Tour.weather);
    expect(runner.state.stepIndex, 0);
    expect(runner.state.isCompleted(Tour.weather), isFalse);
    expect((await launch()).state.isCompleted(Tour.weather), isFalse);
  });

  test('resuming a finished tour starts it again', () async {
    final runner = await launch();
    await runner.start(Tour.weather);
    await runner.finish();
    await runner.resume(Tour.weather);
    expect(runner.state.active, Tour.weather);
    expect(runner.state.stepIndex, 0);
  });

  test('a walkthrough parks and comes back on the same step', () async {
    final runner = await launch();
    await runner.start(Tour.firstNight);
    await runner.next();
    runner.park();
    expect(runner.state.parked, isTrue);
    expect(runner.state.active, Tour.firstNight);
    runner.unpark();
    expect(runner.state.parked, isFalse);
    expect(runner.state.stepIndex, 1);
  });

  test('each tour keeps its own progress', () async {
    final runner = await launch();
    await runner.start(Tour.imaging);
    await runner.next();
    await runner.start(Tour.guiding);
    expect(runner.state.stepsDone(Tour.imaging), 1);
    expect(runner.state.stepsDone(Tour.guiding), 0);
  });

  test('reset forgets everything and takes the tour off screen', () async {
    final runner = await launch();
    await runner.start(Tour.imaging);
    await runner.finish();
    await runner.start(Tour.guiding);
    await runner.resetAll();
    expect(runner.state.active, isNull);
    expect(runner.state.progress, isEmpty);
    expect((await launch()).state.progress, isEmpty);
  });

  test('goTo refuses a step the tour does not have', () async {
    final runner = await launch();
    await runner.start(Tour.calibrationFrames);
    await expectLater(runner.goTo(99), throwsRangeError);
    expect(runner.state.stepIndex, 0);
  });

  test('a failed write leaves the tour where it was and reports it', () async {
    final dao = _FailingDao(db);
    final runner = TourRunner(dao);
    addTearDown(runner.dispose);
    await runner.start(Tour.equipmentSetup);
    await runner.next();

    dao.fail = true;
    await expectLater(runner.next(), throwsStateError);
    await expectLater(runner.back(), throwsStateError);
    await expectLater(runner.skip(), throwsStateError);
    await expectLater(runner.finish(), throwsStateError);
    await expectLater(runner.start(Tour.imaging), throwsStateError);
    expect(runner.state.active, Tour.equipmentSetup);
    expect(runner.state.stepIndex, 1);

    dao.fail = false;
    await runner.next();
    expect(runner.state.stepIndex, 2);
  });

  test('rows of other features in the table are left alone', () async {
    await db.tutorialProgressDao.dismissPromptForScreen('next_use.autofocus');
    final runner = await launch();
    expect(runner.state.progress, isEmpty);
    await runner.start(Tour.imaging);
    expect(runner.state.progress.keys, [Tour.imaging]);
  });
}
