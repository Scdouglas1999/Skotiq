import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';

/// Test harness that records every event emitted by the manager so
/// assertions can verify the wire-format payload directly.
class _EventRecorder {
  final events = <SkotiqEvent>[];

  void record(SkotiqEvent event) => events.add(event);

  List<SkotiqEvent> ofType(String eventType) =>
      events.where((e) => e.eventType == eventType).toList();

  List<SkotiqEvent> forJob(String jobId) => events
      .where((e) => e.category == EventCategory.job)
      .where((e) => e.data['jobId'] == jobId)
      .toList();
}

class _MutableClock {
  DateTime _now;
  _MutableClock(this._now);
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
  void setTo(DateTime t) => _now = t;
}

/// Run the event loop until [predicate] returns true or [timeout] elapses.
/// Used because work scheduled via `scheduleMicrotask` doesn't run until
/// the current async function yields.
Future<void> _pumpUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('pumpUntil predicate did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('JobManager (lifecycle: queued -> running -> succeeded)', () {
    test('start emits JobStarted and the job is queued initially', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) => completer.future,
      );

      expect(job.state, JobState.queued);
      expect(job.operation, 'test.op');
      expect(job.commandId, job.jobId);
      expect(recorder.events, hasLength(1));
      expect(recorder.events.first.eventType, 'JobStarted');
      expect(recorder.events.first.category, EventCategory.job);
      expect(recorder.events.first.data['jobId'], job.jobId);

      completer.complete({'result': 'ok'});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });

    test('queued -> running transition emits a JobProgress event', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) => completer.future,
      );
      await _pumpUntil(() => manager.get(job.jobId)?.state == JobState.running);

      final progressEvents = recorder.ofType('JobProgress');
      expect(progressEvents, isNotEmpty);
      expect(progressEvents.first.data['state'], 'running');

      completer.complete({'result': 'ok'});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });

    test(
      'successful work transitions to succeeded with result payload',
      () async {
        final recorder = _EventRecorder();
        final manager = JobManager(emitEvent: recorder.record);
        addTearDown(manager.dispose);

        final job = manager.start(
          operation: 'test.op',
          work: (sink, cancellation) async => {'value': 42},
        );
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.succeeded,
        );

        final final_ = manager.get(job.jobId)!;
        expect(final_.state, JobState.succeeded);
        expect(final_.result, {'value': 42});
        expect(final_.progress, 1.0);
        expect(recorder.ofType('JobCompleted'), hasLength(1));
      },
    );

    test('progress sink updates broadcast JobProgress events', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async {
          sink.update(0.25, 'one quarter');
          sink.update(0.5, 'half');
          sink.update(0.75, null);
          return completer.future;
        },
      );

      await _pumpUntil(() {
        final j = manager.get(job.jobId);
        return j != null && j.progress == 0.75;
      });

      // running + 3 explicit progress = 4 JobProgress events.
      final progressEvents = recorder.ofType('JobProgress');
      expect(progressEvents.length, greaterThanOrEqualTo(4));
      final messages = progressEvents
          .map((e) => e.data['message'])
          .whereType<String>()
          .toList();
      expect(messages, containsAll(['one quarter', 'half']));

      completer.complete({'done': true});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });
  });

  group('JobManager (failure path)', () {
    test('work throwing exits to failed with error payload', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async {
          throw StateError('boom');
        },
      );
      await _pumpUntil(() => manager.get(job.jobId)?.state == JobState.failed);

      final failed = manager.get(job.jobId)!;
      expect(failed.state, JobState.failed);
      expect(failed.error, isNotNull);
      expect(failed.error!['code'], 'job_failed');
      expect(failed.error!['message'].toString(), contains('boom'));
      expect(failed.error!['details'], {'exceptionType': 'StateError'});
      expect(failed.error.toString(), isNot(contains('#0')));
      expect(failed.error.toString(), isNot(contains('job_manager_test.dart')));
      expect(recorder.ofType('JobFailed'), hasLength(1));
      expect(recorder.ofType('JobFailed').first.severity, EventSeverity.error);
    });
  });

  group('JobManager (cancellation)', () {
    test(
      'cancel() flips cancellation.isCancelled and work surfaces it',
      () async {
        final recorder = _EventRecorder();
        final manager = JobManager(emitEvent: recorder.record);
        addTearDown(manager.dispose);

        final job = manager.start(
          operation: 'test.op',
          work: (sink, cancellation) async {
            await cancellation.whenCancelled;
            throw const JobCancelledException('client asked');
          },
        );
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.running,
        );

        final cancelled = manager.cancel(job.jobId);
        expect(cancelled, isNotNull);

        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.cancelled,
        );
        final terminal = manager.get(job.jobId)!;
        expect(terminal.state, JobState.cancelled);
        expect(terminal.error!['code'], 'job_cancelled');
        expect(recorder.ofType('JobCancelled'), hasLength(1));
      },
    );

    test(
      'cancel() on a queued job transitions straight to cancelled',
      () async {
        final recorder = _EventRecorder();
        final manager = JobManager(emitEvent: recorder.record);
        addTearDown(manager.dispose);

        // Work that never starts. We cancel synchronously before any
        // scheduleMicrotask gets to flip the state to running.
        final job = manager.start(
          operation: 'test.op',
          work: (sink, cancellation) async => {'never': 'runs'},
        );
        expect(job.state, JobState.queued);
        final result = manager.cancel(job.jobId);
        expect(result, isNotNull);
        expect(result!.state, JobState.cancelled);
        await _pumpUntil(
          () => manager.get(job.jobId)?.state == JobState.cancelled,
        );
      },
    );

    test('cancel() returns null when the job is unknown', () {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      expect(manager.cancel('does-not-exist'), isNull);
    });

    test('cancel() on a terminated job throws StateError', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async => {'done': true},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
      expect(() => manager.cancel(job.jobId), throwsStateError);
    });
  });

  group('JobManager (multiple concurrent jobs)', () {
    test(
      'multiple jobs receive distinct ids and progress independently',
      () async {
        final recorder = _EventRecorder();
        final manager = JobManager(emitEvent: recorder.record);
        addTearDown(manager.dispose);

        final completerA = Completer<Map<String, Object?>>();
        final completerB = Completer<Map<String, Object?>>();
        final jobA = manager.start(
          operation: 'test.a',
          work: (sink, cancellation) => completerA.future,
        );
        final jobB = manager.start(
          operation: 'test.b',
          work: (sink, cancellation) => completerB.future,
        );

        expect(jobA.jobId, isNot(jobB.jobId));
        await _pumpUntil(
          () => manager.get(jobA.jobId)?.state == JobState.running,
        );
        await _pumpUntil(
          () => manager.get(jobB.jobId)?.state == JobState.running,
        );

        completerB.complete({'b': 'done'});
        await _pumpUntil(
          () => manager.get(jobB.jobId)?.state == JobState.succeeded,
        );
        expect(manager.get(jobA.jobId)?.state, JobState.running);

        completerA.complete({'a': 'done'});
        await _pumpUntil(
          () => manager.get(jobA.jobId)?.state == JobState.succeeded,
        );
      },
    );
  });

  group('JobManager (24-hour purge)', () {
    test('evictExpired drops terminal jobs older than retention', () async {
      final clock = _MutableClock(DateTime.utc(2026, 5, 24, 10, 0, 0));
      final recorder = _EventRecorder();
      final manager = JobManager(
        emitEvent: recorder.record,
        now: clock.call,
        retention: const Duration(hours: 24),
      );
      addTearDown(manager.dispose);

      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );

      clock.advance(const Duration(hours: 23));
      manager.evictExpired();
      expect(manager.get(job.jobId), isNotNull);

      clock.advance(const Duration(hours: 2));
      manager.evictExpired();
      expect(manager.get(job.jobId), isNull);
    });

    test('evictExpired does not touch non-terminal jobs', () async {
      final clock = _MutableClock(DateTime.utc(2026, 5, 24, 10, 0, 0));
      final recorder = _EventRecorder();
      final manager = JobManager(
        emitEvent: recorder.record,
        now: clock.call,
        retention: const Duration(hours: 1),
      );
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) => completer.future,
      );
      await _pumpUntil(() => manager.get(job.jobId)?.state == JobState.running);

      clock.advance(const Duration(hours: 10));
      manager.evictExpired();
      expect(manager.get(job.jobId), isNotNull);

      completer.complete({'late': true});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });
  });

  group('JobManager (listing)', () {
    test('list filters by state', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final running = manager.start(
        operation: 'test.a',
        work: (sink, cancellation) => completer.future,
      );
      final done = manager.start(
        operation: 'test.b',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.get(done.jobId)?.state == JobState.succeeded,
      );
      await _pumpUntil(
        () => manager.get(running.jobId)?.state == JobState.running,
      );

      final runningJobs = manager.list(state: JobState.running);
      expect(runningJobs, hasLength(1));
      expect(runningJobs.single.jobId, running.jobId);

      final succeededJobs = manager.list(state: JobState.succeeded);
      expect(succeededJobs, hasLength(1));
      expect(succeededJobs.single.jobId, done.jobId);

      completer.complete({'ok': true});
      await _pumpUntil(
        () => manager.get(running.jobId)?.state == JobState.succeeded,
      );
    });

    test('list filters by operation', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      manager.start(
        operation: 'op.alpha',
        work: (sink, cancellation) async => {'ok': true},
      );
      manager.start(
        operation: 'op.beta',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(() => manager.list(operation: 'op.alpha').isNotEmpty);
      await _pumpUntil(() => manager.list(operation: 'op.beta').isNotEmpty);

      expect(manager.list(operation: 'op.alpha'), hasLength(1));
      expect(manager.list(operation: 'op.beta'), hasLength(1));
      expect(manager.list(operation: 'op.gamma'), isEmpty);
    });

    test('get returns null for unknown jobId', () {
      final manager = JobManager(emitEvent: (_) {});
      addTearDown(manager.dispose);
      expect(manager.get('not-a-real-id'), isNull);
    });
  });

  group('JobManager (purge)', () {
    test('purge removes a terminated job', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) async => {'ok': true},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );

      expect(manager.purge(job.jobId), isTrue);
      expect(manager.get(job.jobId), isNull);
    });

    test('purge throws StateError when called on a live job', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final completer = Completer<Map<String, Object?>>();
      final job = manager.start(
        operation: 'test.op',
        work: (sink, cancellation) => completer.future,
      );
      await _pumpUntil(() => manager.get(job.jobId)?.state == JobState.running);
      expect(() => manager.purge(job.jobId), throwsStateError);
      completer.complete({'done': true});
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );
    });

    test('purge returns false for unknown id', () {
      final manager = JobManager(emitEvent: (_) {});
      addTearDown(manager.dispose);
      expect(manager.purge('not-real'), isFalse);
    });
  });

  group('JobManager (event payload shape)', () {
    test('emitted events carry the canonical wire fields', () async {
      final recorder = _EventRecorder();
      final manager = JobManager(emitEvent: recorder.record);
      addTearDown(manager.dispose);

      final job = manager.start(
        operation: 'plate-solve',
        deviceId: 'camera-1',
        work: (sink, cancellation) async => {'ra': 1.0},
      );
      await _pumpUntil(
        () => manager.get(job.jobId)?.state == JobState.succeeded,
      );

      for (final event in recorder.forJob(job.jobId)) {
        expect(event.category, EventCategory.job);
        expect(event.data['jobId'], job.jobId);
        expect(event.data['operation'], 'plate-solve');
        expect(event.data['deviceId'], 'camera-1');
        expect(event.data['state'], anyOf('queued', 'running', 'succeeded'));
      }

      final completed = recorder.ofType('JobCompleted').single;
      expect(completed.data['result'], {'ra': 1.0});
    });
  });
}
