// The overnight driver for the delivery retry sweep.
//
// The failure this guards against is a timer that arms twice (two passes over
// one journal, each writing the other's rows) or one that keeps ticking after
// the server it belongs to has stopped. Both are invisible until a destination
// starts receiving the same file twice.
//
// And the failure that made the retry ladder fiction: with one 15-minute tick,
// a row due 60 seconds after a failed attempt waited for the tick. Measured
// against the release bundle, a share that came back 20 seconds after the
// attempt still had nothing written to it 320 seconds past the row's due time.
// The due check is what makes the documented 1 m / 3 m / 9 m real.

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:path/path.dart' as p;

/// A delivery service whose sweep is counted and can be held open.
class _CountingDelivery extends DeliveryService {
  _CountingDelivery(SkotiqDatabase db)
    : super(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (destination, jobId) =>
            throw StateError('no destination is configured in this test'),
      );

  int sweeps = 0;

  /// How many times the short cadence asked whether anything is due.
  int dueChecks = 0;

  /// What the journal says the sweeper's due check should find.
  bool due = false;

  /// Held by a test that needs a pass to still be in flight on the next tick.
  Completer<void>? gate;

  /// Raised by a test that needs the sweep to fail outright.
  Object? failWith;

  /// Raised by a test that needs the journal read behind the due check to fail.
  Object? dueCheckFailsWith;

  @override
  Future<DeliveryRunReport> sweepDueRetries({
    DeliveryCancellation? isCancelled,
  }) async {
    sweeps++;
    final held = gate;
    if (held != null) await held.future;
    final failure = failWith;
    if (failure != null) throw failure;
    return const DeliveryRunReport(jobId: null, destinations: []);
  }

  @override
  Future<bool> hasDueRetries() async {
    dueChecks++;
    final failure = dueCheckFailsWith;
    if (failure != null) throw failure;
    return due;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late _CountingDelivery delivery;
  late LoggingService logger;

  /// Where the cases about published peer files put those files. The peer arm
  /// reads the rig's own disk, so its two states — the file is there, the file
  /// is gone — need a real path either way.
  late Directory tempDir;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    delivery = _CountingDelivery(db);
    logger = LoggingService();
    tempDir = Directory.systemTemp.createTempSync('ns_delivery_sweeper_');
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DeliveryRetrySweeper build({Duration? interval, Duration? dueCheck}) =>
      DeliveryRetrySweeper(
        delivery: delivery,
        logger: logger,
        interval: interval ?? const Duration(milliseconds: 20),
        // Out of reach unless a test asks for it, so the cases about the
        // heartbeat count the heartbeat's passes and nothing else.
        dueCheckInterval: dueCheck ?? const Duration(minutes: 5),
      );

  test('start is idempotent and does not fire immediately', () async {
    final sweeper = build(interval: const Duration(seconds: 30));
    addTearDown(sweeper.stop);

    sweeper.start();
    expect(sweeper.isRunning, isTrue);
    sweeper.start();
    sweeper.start();

    // Nothing is due in the instant after start: the catch-up pass belongs to
    // the bootstraps, not to the timer's first act.
    expect(delivery.sweeps, 0);
  });

  test('a second start does not arm a second timer', () async {
    final sweeper = build(interval: const Duration(milliseconds: 20));
    addTearDown(sweeper.stop);

    sweeper.start();
    sweeper.start();
    await Future<void>.delayed(const Duration(milliseconds: 70));
    sweeper.stop();

    // Two timers over the same interval would roughly double this. Comparing
    // against a ceiling rather than an exact count keeps the assertion honest
    // on a loaded machine.
    expect(delivery.sweeps, greaterThan(0));
    expect(
      delivery.sweeps,
      lessThanOrEqualTo(4),
      reason: 'a doubled timer would sweep about twice as often',
    );
  });

  test('stop is idempotent and ends the ticking', () async {
    final sweeper = build(interval: const Duration(milliseconds: 20));

    sweeper.start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sweeper.stop();
    sweeper.stop();
    expect(sweeper.isRunning, isFalse);

    final after = delivery.sweeps;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(delivery.sweeps, after, reason: 'a stopped sweeper never ticks');
  });

  test('a pass in flight is not overlapped by the next tick', () async {
    final sweeper = build(interval: const Duration(milliseconds: 10));
    addTearDown(sweeper.stop);
    final gate = Completer<void>();
    delivery.gate = gate;

    final first = sweeper.sweepOnce();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // A second caller while the first holds the journal answers null rather
    // than starting a competing pass.
    expect(await sweeper.sweepOnce(), isNull);
    expect(delivery.sweeps, 1);

    gate.complete();
    expect(await first, isNotNull);
    expect(sweeper.isSweeping, isFalse);
  });

  test(
    'a throwing sweep releases the latch and leaves the timer armed',
    () async {
      final sweeper = build(interval: const Duration(seconds: 30));
      addTearDown(sweeper.stop);
      sweeper.start();
      delivery.failWith = StateError('the journal is unreadable');

      expect(await sweeper.sweepOnce(), isNull);
      expect(sweeper.isSweeping, isFalse);
      expect(
        sweeper.isRunning,
        isTrue,
        reason: 'the next tick is the retry; a failure must not disarm it',
      );

      delivery.failWith = null;
      expect(await sweeper.sweepOnce(), isNotNull);
    },
  );

  test(
    'a row that comes due is swept without waiting for the heartbeat',
    () async {
      // The heartbeat is put an hour out of reach, so the only thing that can
      // sweep here is the short cadence noticing the row.
      final sweeper = build(
        interval: const Duration(hours: 1),
        dueCheck: const Duration(milliseconds: 10),
      );
      addTearDown(sweeper.stop);

      sweeper.start();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        delivery.dueChecks,
        greaterThan(0),
        reason: 'the journal is asked on the short cadence',
      );
      expect(
        delivery.sweeps,
        0,
        reason:
            'nothing is due, so nothing re-reads a file or opens a transport',
      );

      delivery.due = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      sweeper.stop();

      expect(
        delivery.sweeps,
        greaterThan(0),
        reason: 'the row was due; waiting out the heartbeat is the defect',
      );
    },
  );

  test(
    'the due check does not start a pass over a pass already running',
    () async {
      final sweeper = build(
        interval: const Duration(hours: 1),
        dueCheck: const Duration(milliseconds: 10),
      );
      addTearDown(sweeper.stop);
      final gate = Completer<void>();
      delivery.gate = gate;
      delivery.due = true;

      final first = sweeper.sweepOnce();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      sweeper.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivery.sweeps, 1, reason: 'the running pass owns those rows');
      expect(
        delivery.dueChecks,
        0,
        reason: 'the journal is not even read while a pass holds it',
      );

      gate.complete();
      expect(await first, isNotNull);
    },
  );

  test('a due check the journal refuses leaves both timers armed', () async {
    final sweeper = build(
      interval: const Duration(hours: 1),
      dueCheck: const Duration(milliseconds: 10),
    );
    addTearDown(sweeper.stop);
    delivery.dueCheckFailsWith = StateError('the journal is unreadable');

    sweeper.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(delivery.dueChecks, greaterThan(1), reason: 'it keeps asking');
    expect(delivery.sweeps, 0);
    expect(sweeper.isRunning, isTrue);
  });

  test(
    'an unpulled peer file does not turn the due check into a sweep loop',
    () async {
      // Driven over the REAL DeliveryService and a real journal, because the
      // defect lived in the answer `hasDueRetries` gives, not in the timer.
      //
      // Measured against the release bundle: one published-but-unpulled peer
      // file made the 30-second due check answer "due" for ever, so a full sweep
      // ran and logged `peer-office: 1 awaiting pull` every 30 seconds — seven
      // identical INFO lines in 3 1/2 minutes, with the row untouched throughout
      // (`attempts` 1, `updated_at` unchanged). That is the ordinary state
      // between the dawn job and the operator's morning.
      //
      // The published file is REALLY on disk here, because that is the case
      // this claim is about: the rig still holds what it published and owes
      // nothing. A published file that has LEFT the rig is the opposite case
      // and the test below it.
      final jobId = await DarkroomJobsDao(db).enqueue();
      final targetId = await DeliveryTargetsDao(db).create(
        name: 'peer-office',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: const {ArtifactContent.draftRender},
      );
      final published = File(p.join(tempDir.path, 'draft.png'))
        ..writeAsStringSync('draft-bytes');
      await DeliveryJournalDao(db).recordAttempt(
        targetId: targetId,
        jobId: jobId,
        filePath: published.path,
        bytes: 1024,
      );

      // Six hours on, so the row is long past every rung of the backoff ladder:
      // what keeps the check quiet has to be the destination's kind, not a
      // retry that has simply not come due yet.
      final real = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) =>
            throw StateError('the due check must not build a transport'),
        clock: () => DateTime.now().toUtc().add(const Duration(hours: 6)),
      );
      final sweeper = DeliveryRetrySweeper(
        delivery: real,
        logger: logger,
        interval: const Duration(hours: 1),
        dueCheckInterval: const Duration(milliseconds: 10),
      );
      addTearDown(sweeper.stop);

      sweeper.start();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      sweeper.stop();

      expect(
        logger
            .getRecentLogs()
            .where((entry) => entry.message.contains('Delivery retry sweep:'))
            .toList(),
        isEmpty,
        reason:
            'this is the log line that arrived every 30 seconds for ever; '
            'the due check must go quiet, not just do less work',
      );
      expect(
        (await DeliveryJournalDao(db).listPendingRetry()).single.state,
        DeliveryAttemptState.retrying,
        reason: 'the row is still pending — it is pending on the peer',
      );
      expect(
        await real.hasDueRetries(),
        isFalse,
        reason:
            'the short cadence has nothing to wake for; the next move is a '
            'pull by the desktop',
      );
    },
  );

  test(
    'a published file that left the rig wakes the check, and only once',
    () async {
      // The other half of the same claim, and the defect the half above it
      // caused: because no peer row could ever be due, the 30-second check
      // never reached the publication arm at all. Measured against the release
      // bundle on port 8143 — a published draft moved off disk stayed
      // `retrying` with a null error for the whole 200 seconds it was polled,
      // while the manifest endpoint was already refusing to serve it
      // (`sourceMissing`) and the download answered 404. Only the 15-minute
      // heartbeat, or a restart, moved it.
      //
      // Once is the whole point. The pass this wakes writes the row `failed`
      // — `sourceMissing` is not retryable — and a failed row is not pending,
      // so it cannot answer "due" again. That is why this is not the permanent
      // loop the case above forbids.
      final jobId = await DarkroomJobsDao(db).enqueue();
      final targetId = await DeliveryTargetsDao(db).create(
        name: 'peer-office',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: const {ArtifactContent.draftRender},
      );
      final published = File(p.join(tempDir.path, 'gone.png'))
        ..writeAsStringSync('draft-bytes');
      await DeliveryJournalDao(db).recordAttempt(
        targetId: targetId,
        jobId: jobId,
        filePath: published.path,
        bytes: 1024,
      );
      published.deleteSync();

      final real = DeliveryService(
        targets: DeliveryTargetsDao(db),
        journal: DeliveryJournalDao(db),
        transportFactory: (_, __) =>
            throw StateError('the peer arm builds no transport'),
      );
      final sweeper = DeliveryRetrySweeper(
        delivery: real,
        logger: logger,
        interval: const Duration(hours: 1),
        dueCheckInterval: const Duration(milliseconds: 10),
      );
      addTearDown(sweeper.stop);

      expect(await real.hasDueRetries(), isTrue);

      sweeper.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      sweeper.stop();

      final row = (await DeliveryJournalDao(db).listForJob(jobId)).single;
      expect(row.state, DeliveryAttemptState.failed);
      expect(row.lastError, contains('sourceMissing'));
      expect(
        row.lastError,
        contains('never pulled it'),
        reason: 'the sentence names whose fact this is: the file left the rig',
      );
      expect(
        row.attempts,
        1,
        reason: 'reading the rig\'s own disk is not a publication attempt',
      );

      expect(
        await real.hasDueRetries(),
        isFalse,
        reason: 'a terminal row is not pending, so it cannot ask again',
      );
      final passes = logger
          .getRecentLogs()
          .where((entry) => entry.message.contains('Delivery retry sweep:'))
          .toList();
      expect(
        passes,
        hasLength(1),
        reason: 'twelve ticks in that window, and exactly one pass to run',
      );
    },
  );

  // Settings > Delivery, left open, kept stating a failure the sweep had
  // already fixed: the row healed at 04:01:04 and the page still read
  // "destinationUnreachable ... will retry (1 file owed)" at 04:01:58, and
  // after leaving the section and coming back. Nothing in the process told the
  // page the journal had moved. `passes` is that telling, so it has to carry
  // every pass that ran and nothing that did not.
  test('a completed pass is announced on passes', () async {
    final sweeper = build(interval: const Duration(hours: 1));
    addTearDown(sweeper.dispose);

    final heard = <DeliveryRunReport>[];
    final subscription = sweeper.passes.listen(heard.add);
    addTearDown(subscription.cancel);

    await sweeper.sweepOnce();
    await pumpEventQueue();

    expect(delivery.sweeps, 1);
    expect(
      heard,
      hasLength(1),
      reason: 'a page reading the journal has no other way to learn it moved',
    );
  });

  test('a pass folded into one already in flight announces nothing', () async {
    final sweeper = build(interval: const Duration(hours: 1));
    addTearDown(sweeper.dispose);

    final heard = <DeliveryRunReport>[];
    final subscription = sweeper.passes.listen(heard.add);
    addTearDown(subscription.cancel);

    final gate = Completer<void>();
    delivery.gate = gate;
    final first = sweeper.sweepOnce();
    await pumpEventQueue();

    // Folded: it did no work of its own and has no report to state.
    expect(await sweeper.sweepOnce(), isNull);

    delivery.gate = null;
    gate.complete();
    await first;
    await pumpEventQueue();

    expect(
      heard,
      hasLength(1),
      reason: 'one pass ran, so the journal moved once',
    );
  });

  test('a pass that failed outright announces nothing', () async {
    final sweeper = build(interval: const Duration(hours: 1));
    addTearDown(sweeper.dispose);

    final heard = <DeliveryRunReport>[];
    final subscription = sweeper.passes.listen(heard.add);
    addTearDown(subscription.cancel);

    delivery.failWith = StateError('the journal would not open');
    expect(await sweeper.sweepOnce(), isNull);
    await pumpEventQueue();

    expect(
      heard,
      isEmpty,
      reason: 'there is no report to state, and the next tick is the retry',
    );
  });

  test('stop ends the due check as well as the heartbeat', () async {
    final sweeper = build(
      interval: const Duration(hours: 1),
      dueCheck: const Duration(milliseconds: 10),
    );

    sweeper.start();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    sweeper.stop();
    final asked = delivery.dueChecks;
    expect(asked, greaterThan(0));

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      delivery.dueChecks,
      asked,
      reason: 'a stopped sweeper reads nothing, on either timer',
    );
  });
}
