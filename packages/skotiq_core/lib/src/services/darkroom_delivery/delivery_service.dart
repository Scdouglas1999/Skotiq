/// Delivers a finished dawn job's artifacts to every enabled destination, and
/// keeps trying overnight for the ones that did not land.
///
/// Three invariants govern everything here:
///
/// * **Delivery never fails the pipeline.** The master row commits before any
///   of this runs. A NAS that is unplugged at 06:00 is a fact about the
///   network, so every failure is caught at this boundary, written to the
///   journal, and returned in the report. [deliverJobArtifacts] and
///   [sweepDueRetries] do not throw.
/// * **The journal is the only state.** Retries are decided from
///   `delivery_journal` rows — `attempts` and `updated_at` — never from
///   anything held in memory, so a rig that reboots at 04:00 resumes exactly
///   the schedule the dead process was on.
/// * **Skotiq copies, it does not move.** No source file is renamed,
///   deleted, or truncated by delivery, on any transport, on any outcome.
library;

import 'dart:async';

import 'package:path/path.dart' as p;

import '../../database/daos/delivery_journal_dao.dart';
import '../../database/daos/delivery_targets_dao.dart';
import '../../models/darkroom/delivery.dart';
import '../logging_service.dart';
import 'artifact_transport.dart';
import 'delivery_artifact.dart';
import 'delivery_failure.dart';
import 'delivery_retry_policy.dart';
import 'delivery_transport_factory.dart';

/// Whether the caller has asked to stop. Checked between files, because a
/// transport that is mid-upload owns its own timeout.
typedef DeliveryCancellation = bool Function();

/// Whether [isCancelled] says to stop.
///
/// A caller that passed none has not asked to stop; that reading is stated
/// here once rather than as a fallback at each call site.
bool _stopRequested(DeliveryCancellation? isCancelled) =>
    isCancelled != null && isCancelled();

/// What happened to one destination on one pass.
class DeliveryDestinationReport {
  /// The destination row's id, or null for a destination that has no database
  /// row — nothing about which can be journalled, and which therefore has no
  /// id to state.
  final int? targetId;

  /// The destination's operator-facing name, as the morning report prints it.
  final String name;

  /// The transport it delivers over.
  final ArtifactDestinationKind kind;

  /// Files that arrived and verified on this pass.
  final int delivered;

  /// Files an earlier pass already delivered, which this pass left alone.
  ///
  /// Kept apart from [delivered]: that count is work this pass did, and this
  /// one is work it found already done. A job whose row is re-queued after a
  /// power cut runs its whole delivery pass again over the same artifacts, and
  /// the files that already arrived are not sent again, not counted as an
  /// attempt, and — for a paired desktop that acknowledged its pull — not
  /// offered back to it.
  final int alreadyDelivered;

  /// Files published for a paired desktop that has not pulled them yet.
  final int awaitingPull;

  /// Files that did not land and are due another attempt.
  final int retrying;

  /// Files nothing was tried for because the pass was stopped before it
  /// reached them.
  ///
  /// Kept apart from [retrying]: those are files an attempt was spent on, and
  /// these are files the operator's stop reached first. Their journal rows are
  /// left owed with their attempt counts untouched, so the sweep resumes them
  /// — which is what makes this number a statement of work outstanding rather
  /// than of work lost.
  final int stoppedPending;

  /// Files whose attempts are spent, or whose failure no retry can change.
  final int failed;

  /// Files nothing was attempted for because the destination is switched off.
  ///
  /// Kept apart from every other count, and especially from [awaitingPull]: a
  /// switched-off peer destination is refused by the manifest endpoint —
  /// `PeerManifestService` resolves peers through `readEnabled` — so its
  /// published rows are not waiting on a desktop that could collect them.
  /// They are waiting on the operator's own switch, and nothing on the rig
  /// will touch them until it moves.
  final int suspended;

  /// Files whose journal row could not be written.
  ///
  /// These are neither retrying nor failed: the journal is the ONLY state the
  /// sweep reads, so a file with no row is one nothing will ever pick up
  /// again. Counting it as `retrying` promises an attempt that cannot happen.
  final int unjournalled;

  /// Why this destination was handed no files at all, when it was handed none.
  /// Null whenever [attempted] is greater than zero.
  final String? nothingToSend;

  /// One sentence per problem, each naming the mechanism.
  final List<String> problems;

  const DeliveryDestinationReport({
    required this.targetId,
    required this.name,
    required this.kind,
    required this.delivered,
    required this.awaitingPull,
    required this.retrying,
    required this.failed,
    required this.problems,
    this.alreadyDelivered = 0,
    this.stoppedPending = 0,
    this.suspended = 0,
    this.unjournalled = 0,
    this.nothingToSend,
  });

  /// Total files this destination was asked to take on this pass.
  int get attempted =>
      delivered +
      alreadyDelivered +
      awaitingPull +
      retrying +
      stoppedPending +
      suspended +
      failed +
      unjournalled;

  /// The morning report's line for this destination.
  String get summary {
    if (attempted == 0) {
      return '$name: ${nothingToSend ?? 'nothing selected'}';
    }
    final parts = <String>[
      if (delivered > 0) '$delivered delivered',
      if (alreadyDelivered > 0)
        '$alreadyDelivered already delivered before this pass',
      if (awaitingPull > 0) '$awaitingPull awaiting pull',
      if (retrying > 0) '$retrying retrying',
      if (stoppedPending > 0)
        'stopped during delivery, $stoppedPending file'
            '${stoppedPending == 1 ? '' : 's'} pending',
      if (suspended > 0) '$suspended suspended while $name is switched off',
      if (failed > 0) '$failed failed',
      if (unjournalled > 0) '$unjournalled not journalled',
    ];
    return '$name: ${parts.join(', ')}';
  }
}

/// What happened on one delivery pass.
class DeliveryRunReport {
  /// The job the pass was for, or null for a sweep spanning jobs.
  final int? jobId;

  /// One entry per destination the pass touched.
  final List<DeliveryDestinationReport> destinations;

  /// Problems that belong to the pass rather than to a destination it could
  /// visit: the destination list being unreadable, and each individual row
  /// that would not decode into a destination. They are what stops an empty
  /// [destinations] from being read as "nothing is configured", and what
  /// keeps an undecodable row visible when the readable ones delivered fine.
  final List<String> problems;

  const DeliveryRunReport({
    required this.jobId,
    required this.destinations,
    this.problems = const [],
  });

  /// Files that arrived and verified.
  int get delivered => destinations.fold<int>(0, (sum, d) => sum + d.delivered);

  /// Files an earlier pass had already delivered.
  int get alreadyDelivered =>
      destinations.fold<int>(0, (sum, d) => sum + d.alreadyDelivered);

  /// Files published for a peer that has not pulled them yet.
  int get awaitingPull =>
      destinations.fold<int>(0, (sum, d) => sum + d.awaitingPull);

  /// Files due another attempt.
  int get retrying => destinations.fold<int>(0, (sum, d) => sum + d.retrying);

  /// Files the stop reached before delivery did, still owed in the journal.
  int get stoppedPending =>
      destinations.fold<int>(0, (sum, d) => sum + d.stoppedPending);

  /// Files sitting at a destination the operator has switched off.
  int get suspended => destinations.fold<int>(0, (sum, d) => sum + d.suspended);

  /// True when a stop ended this pass before it had sent everything.
  bool get wasStopped => stoppedPending > 0;

  /// Files that will not be attempted again.
  int get failed => destinations.fold<int>(0, (sum, d) => sum + d.failed);

  /// Files nothing was recorded for, so nothing will pick them up again.
  int get unjournalled =>
      destinations.fold<int>(0, (sum, d) => sum + d.unjournalled);

  /// True when every file this pass touched reached a destination.
  bool get everythingLanded =>
      problems.isEmpty &&
      retrying == 0 &&
      stoppedPending == 0 &&
      suspended == 0 &&
      failed == 0 &&
      unjournalled == 0;

  /// The morning report's paragraph.
  ///
  /// "No delivery destination is enabled" is a claim about the destination
  /// table, so it is stated only when the table was read and was empty of
  /// enabled rows — never when the read failed, and never when a destination
  /// was skipped for taking none of this job's files.
  String get summary {
    if (destinations.isNotEmpty) {
      return destinations.map((d) => d.summary).join('; ');
    }
    if (problems.isNotEmpty) return problems.join('; ');
    return 'No delivery destination is enabled';
  }
}

/// Runs deliveries and owns the journal that records them.
class DeliveryService {
  final DeliveryTargetsDao _targets;
  final DeliveryJournalDao _journal;
  final ArtifactTransportFactory _transportFactory;
  final DeliveryRetryPolicy _policy;
  final LoggingService? _logger;
  final DateTime Function() _clock;

  /// How many times one journal write is asked before the pass gives up on
  /// recording it. The dawn pipeline writes the same database, so a write can
  /// lose a lock to work that is about to finish; asking again a bounded
  /// number of times costs nothing and saves the row.
  final int _journalWriteAttempts;

  /// Wait between journal-write attempts.
  final Duration _journalWriteBackoff;

  DeliveryService({
    required DeliveryTargetsDao targets,
    required DeliveryJournalDao journal,
    required ArtifactTransportFactory transportFactory,
    DeliveryRetryPolicy policy = DeliveryRetryPolicy.standard,
    LoggingService? logger,
    DateTime Function()? clock,
    int journalWriteAttempts = 3,
    Duration journalWriteBackoff = const Duration(milliseconds: 200),
  }) : _targets = targets,
       _journal = journal,
       _transportFactory = transportFactory,
       _policy = policy,
       _logger = logger,
       _clock = clock ?? DateTime.now,
       _journalWriteAttempts = journalWriteAttempts,
       _journalWriteBackoff = journalWriteBackoff;

  /// Deliver [set] to every enabled destination that selected each artifact.
  ///
  /// Returns what happened. Never throws: a destination that fails is a line
  /// in the report and a row in the journal.
  Future<DeliveryRunReport> deliverJobArtifacts(
    DeliveryArtifactSet set, {
    DeliveryCancellation? isCancelled,
  }) async {
    final DeliveryTargetsRead read;
    try {
      read = await _targets.readEnabled();
    } catch (error, stack) {
      // The destination list is unreadable, so nothing can be delivered and
      // nothing can be journalled. The pipeline still finishes: this is
      // reported, not raised — and it is reported as the read failing, which
      // is not the same fact as no destination being configured.
      _logger?.error(
        'Delivery could not read its destination list: $error',
        source: 'DeliveryService',
        fields: {'stack': stack.toString()},
      );
      return DeliveryRunReport(
        jobId: set.jobId,
        destinations: const [],
        problems: [
          'The delivery destination list could not be read ($error), so '
              'nothing was sent and nothing was journalled',
        ],
      );
    }

    final problems = _undecodableProblems(read.undecodable);
    final reports = <DeliveryDestinationReport>[];
    for (final destination in read.destinations) {
      final selected = set.selectedFor(destination);
      if (selected.isEmpty) {
        reports.add(_nothingToSend(destination));
        continue;
      }
      reports.add(
        await _runDestination(
          destination: destination,
          jobId: set.jobId,
          files: selected,
          isCancelled: isCancelled,
        ),
      );
    }
    return DeliveryRunReport(
      jobId: set.jobId,
      destinations: reports,
      problems: problems,
    );
  }

  /// One sentence per row that would not decode into a destination.
  ///
  /// Logged as well as reported: the row is a database fact the operator will
  /// have to repair, and the morning report is read once while the log keeps.
  List<String> _undecodableProblems(List<UndecodableDeliveryTarget> rows) {
    final problems = <String>[];
    for (final row in rows) {
      final sentence =
          '${row.label} was skipped because ${row.reason}. Nothing was sent '
          'there and nothing was journalled for it; every other destination '
          'ran normally. Open Settings > Delivery to correct or remove it';
      _logger?.error(
        'A delivery destination row could not be decoded and was skipped: '
        '$sentence',
        source: 'DeliveryService',
      );
      problems.add(sentence);
    }
    return problems;
  }

  /// When the earliest still-owed row becomes due, or null when the journal
  /// owes nothing.
  ///
  /// [DeliveryRetrySweeper] asks this on its short cadence so its next sweep
  /// lands on the rung [DeliveryRetryPolicy] documents — 1 m, 3 m, 9 m — rather
  /// than on whatever tick happens next. Reading it is one indexed SELECT over
  /// the `retrying` rows and no filesystem or transport work at all, which is
  /// what makes it cheap enough to ask far more often than a sweep runs.
  ///
  /// Unlike [sweepDueRetries] this throws what the journal or the destination
  /// read throws. The sweep answers with a report because a destination being
  /// offline at 4am must not kill the timer; an unreadable database is a
  /// different fact, and answering "nothing is due" to it would silence the
  /// very sweep the ladder depends on. The caller reports it and keeps its
  /// timer.
  ///
  /// **A row the sweep would not touch is not a due row.** Two kinds sit in
  /// `retrying` without ever being owed an attempt, and both are excluded here
  /// for the same reason.
  ///
  /// A PEER destination's files are published and waiting for the paired
  /// desktop to pull them. [_sweepPublications] re-checks that the rig still
  /// holds them but re-attempts nothing: the next move belongs to the peer,
  /// not to this rig, and it arrives as a pull rather than as a retry. That is
  /// the NORMAL state between the dawn job and the operator's morning, so
  /// counting it made [hasDueRetries] permanently true — one unpulled file
  /// drove a full sweep and an INFO report every 30 seconds, for as long as
  /// nobody woke the desktop up. The one thing that arm CAN change is asked
  /// separately, by [hasLostPublication].
  ///
  /// A switched-off destination's files stay `retrying` for as long as the
  /// switch is off — the sweep states them and skips them without touching the
  /// row.
  ///
  /// Counting either would answer "due" on every single check and turn the
  /// short cadence into a permanent sweep loop for every OTHER destination too.
  /// Both are read by the heartbeat pass, which is what keeps the suspended and
  /// awaiting-pull counts arriving on the cadence an operator can recognise.
  /// The same goes for a row this build cannot decode: the sweep logs it and
  /// moves on, so waking for it changes nothing.
  Future<DateTime?> earliestRetryDueAt() async {
    final pending = await _journal.listPendingRetry();
    if (pending.isEmpty) return null;
    final retryable = <int>{
      for (final destination in (await _targets.readEnabled()).destinations)
        if (destination.id != null &&
            destination.kind != ArtifactDestinationKind.peer)
          destination.id!,
    };
    DateTime? earliest;
    for (final entry in pending) {
      if (!retryable.contains(entry.targetId)) continue;
      final due = _policy.nextEligibleAt(entry);
      if (earliest == null || due.isBefore(earliest)) earliest = due;
    }
    return earliest;
  }

  /// Whether a published peer artifact is no longer on the rig.
  ///
  /// The peer arm's other question, and the reason the sweeper's short cadence
  /// reaches [_sweepPublications] at all. [earliestRetryDueAt] is about the
  /// retry ladder and stays one indexed SELECT; this one asks the rig's own
  /// disk, because "the file left the rig" is a filesystem fact and no journal
  /// column carries it. It is the SAME question the sweep arm asks —
  /// [DeliveryFile.confirmOnRig] — so a row that answers "due" here is a row
  /// that pass will actually move.
  ///
  /// **This cannot become the permanent sweep loop wave 14 removed.** That
  /// loop was an unpulled-but-present file answering "due" on every check for
  /// ever, because the pass it woke left the row exactly as it found it. The
  /// only outcome this question wakes a pass for is a source the rig has lost,
  /// and [confirmOnRig] can only fail with `sourceMissing` or
  /// `permissionDenied` — both non-retryable, so [_recordJournalOutcome] writes
  /// the row `failed` on that first pass. A failed row is not in
  /// [DeliveryJournalDao.listPendingRetry], so the same file cannot answer
  /// "due" twice. A file that is still there answers false, at the cost of one
  /// `stat`.
  ///
  /// Cost is bounded by the rows a peer is actually owed, and the first miss
  /// ends the walk: the answer is already yes. Suspended destinations are
  /// excluded for the same reason [earliestRetryDueAt] excludes them — the
  /// sweep returns before the peer arm on a destination whose switch is off,
  /// so waking for one changes nothing.
  ///
  /// Throws what the journal or the destination read throws, exactly as
  /// [earliestRetryDueAt] does. A filesystem answer is never a throw: it is
  /// the answer.
  Future<bool> hasLostPublication() async {
    final pending = await _journal.listPendingRetry();
    if (pending.isEmpty) return false;
    final peers = <int>{
      for (final destination in (await _targets.readEnabled()).destinations)
        if (destination.id != null &&
            destination.kind == ArtifactDestinationKind.peer)
          destination.id!,
    };
    if (peers.isEmpty) return false;
    for (final entry in pending) {
      if (!peers.contains(entry.targetId)) continue;
      try {
        await DeliveryFile.confirmOnRig(entry.filePath);
      } on DeliveryFailure {
        return true;
      }
    }
    return false;
  }

  /// Whether the sweep has work to do right now: a journal row whose retry is
  /// due, or a published peer artifact the rig has lost.
  ///
  /// The question [DeliveryRetrySweeper]'s short cadence actually asks; see
  /// [earliestRetryDueAt] for why it throws rather than reporting.
  ///
  /// The ladder is asked first because it is the cheaper question — one
  /// indexed SELECT — and an already-due row makes the peer walk's `stat`s
  /// unnecessary.
  Future<bool> hasDueRetries() async {
    final due = await earliestRetryDueAt();
    if (due != null && !_clock().toUtc().isBefore(due)) return true;
    return hasLostPublication();
  }

  /// Re-attempt every journal row that is due, across every job.
  ///
  /// This is the overnight sweep. It reads its whole work list out of the
  /// journal, so it makes the same decisions after a restart that the process
  /// that died would have made, and it re-reads each source file from disk
  /// because the journal records the path, not the bytes.
  Future<DeliveryRunReport> sweepDueRetries({
    DeliveryCancellation? isCancelled,
  }) async {
    final now = _clock().toUtc();
    final List<DeliveryJournalEntry> pending;
    try {
      pending = await _journal.listPendingRetry();
    } catch (error, stack) {
      _logger?.error(
        'The delivery retry sweep could not read the journal: $error',
        source: 'DeliveryService',
        fields: {'stack': stack.toString()},
      );
      return const DeliveryRunReport(jobId: null, destinations: []);
    }

    final byTarget = <int, List<DeliveryJournalEntry>>{};
    for (final entry in pending) {
      byTarget.putIfAbsent(entry.targetId, () => []).add(entry);
    }

    final reports = <DeliveryDestinationReport>[];
    final problems = <String>[];
    for (final targetId in byTarget.keys) {
      final ArtifactDestination? destination;
      try {
        destination = await _targets.getById(targetId);
      } on Object catch (error, stack) {
        // The row is there but does not decode. Its own files stay in the
        // journal exactly as they are — a later build that understands the row
        // resumes them — and the destinations either side of it are still
        // swept.
        _logger?.error(
          'The delivery retry sweep skipped destination $targetId: its row '
          'could not be decoded ($error)',
          source: 'DeliveryService',
          fields: {'stack': stack.toString()},
        );
        final owed = byTarget[targetId]!.length;
        problems.add(
          'Delivery destination #$targetId was skipped by the retry sweep '
          'because its row could not be read ($error); its '
          '$owed pending file${owed == 1 ? '' : 's'} '
          '${owed == 1 ? 'was' : 'were'} left owed',
        );
        continue;
      }
      if (destination == null) continue;
      final rows = byTarget[targetId]!;
      reports.add(
        await _sweepDestination(
          destination: destination,
          rows: rows,
          now: now,
          isCancelled: isCancelled,
        ),
      );
    }
    return DeliveryRunReport(
      jobId: null,
      destinations: reports,
      problems: problems,
    );
  }

  /// The report entry for a destination this job handed no files to.
  ///
  /// Two different facts share this shape and the sentence says which: a
  /// destination that selects no class of artifact takes nothing NEW on any
  /// night, while one that selects a class this job did not produce is
  /// correctly configured and simply had nothing to take. Skipping the
  /// destination entirely made both read as "no delivery destination is
  /// enabled" in the morning report.
  ///
  /// "No new file" rather than "no file": the selection picks destinations at
  /// job time only, so rows this destination was already owed when the
  /// selection was cleared are still on the sweep's work list and still go.
  /// The flat claim contradicted the sweeper's own log on the same launch —
  /// `empty-selection: 1 delivered`.
  DeliveryDestinationReport _nothingToSend(ArtifactDestination destination) {
    final selection = destination.content;
    final reason = selection.isEmpty
        ? 'nothing selected, so no new file goes there'
        : 'the job produced none of the '
              '${selection.map((c) => c.wire).join(', ')} it takes';
    return DeliveryDestinationReport(
      targetId: destination.id,
      name: destination.name,
      kind: destination.kind,
      delivered: 0,
      awaitingPull: 0,
      retrying: 0,
      failed: 0,
      problems: const [],
      nothingToSend: reason,
    );
  }

  Future<DeliveryDestinationReport> _runDestination({
    required ArtifactDestination destination,
    required int jobId,
    required List<DeliveryFile> files,
    required DeliveryCancellation? isCancelled,
  }) async {
    final targetId = destination.id;
    if (targetId == null) {
      return DeliveryDestinationReport(
        targetId: null,
        name: destination.name,
        kind: destination.kind,
        delivered: 0,
        awaitingPull: 0,
        retrying: 0,
        failed: files.length,
        problems: const [
          'This destination has no database row, so nothing about it can be '
              'journalled',
        ],
      );
    }

    final tally = _Tally(destination, targetId);
    final transport = _transportFactory(destination, jobId);
    try {
      await transport.open(files);
    } catch (error, stack) {
      final failure = _asFailure(error, destination);
      _log(failure, destination, stack);
      await _destinationRefused(
        targetId: targetId,
        jobId: jobId,
        files: files,
        failure: failure,
        tally: tally,
      );
      await _closeQuietly(transport, tally);
      return tally.build();
    }

    for (final file in files) {
      if (_stopRequested(isCancelled)) {
        await _recordStillOwed(
          targetId: targetId,
          jobId: jobId,
          filePath: file.sourcePath,
          bytes: file.bytes,
          tally: tally,
        );
        continue;
      }
      await _deliverOne(
        transport: transport,
        targetId: targetId,
        jobId: jobId,
        file: file,
        destination: destination,
        tally: tally,
      );
    }

    await _closeQuietly(transport, tally);
    return tally.build();
  }

  Future<DeliveryDestinationReport> _sweepDestination({
    required ArtifactDestination destination,
    required List<DeliveryJournalEntry> rows,
    required DateTime now,
    required DeliveryCancellation? isCancelled,
  }) async {
    final targetId = destination.id ?? rows.first.targetId;
    final tally = _Tally(destination, targetId);

    // The switch is read before the kind, for every transport. A peer's rows
    // used to take the awaiting-pull branch above this check and be reported
    // as waiting for a desktop to collect them — while `PeerManifestService`
    // resolves peers through `readEnabled`, so the manifest endpoint answered
    // that same peer with `unknown_delivery_peer` and nothing could ever pull
    // them. Off is off on every transport, and it is what the row says.
    if (!destination.enabled) {
      tally.suspended += rows.length;
      final consequence = destination.kind == ArtifactDestinationKind.peer
          ? 'no paired desktop can pull them while it is off'
          : 'no attempt was made and no attempt was spent';
      tally.problems.add(
        '${rows.length} file${rows.length == 1 ? '' : 's'} '
        '${rows.length == 1 ? 'is' : 'are'} suspended: ${destination.name} is '
        'switched off, so $consequence',
      );
      return tally.build();
    }
    if (destination.kind == ArtifactDestinationKind.peer) {
      await _sweepPublications(
        destination: destination,
        targetId: targetId,
        rows: rows,
        isCancelled: isCancelled,
        tally: tally,
      );
      return tally.build();
    }

    final due = rows.where((row) => _policy.isDue(row, now)).toList();
    tally.retrying += rows.length - due.length;
    if (due.isEmpty) return tally.build();

    // One transport per JOB, not one per destination. A transport is built
    // with a job id and the atomic write derives its staged name from it
    // (`.<name>.<jobId>.nsdelivery-part`), so a sweep spanning two nights that
    // opened a single transport on the first due row staged the second night's
    // masters under the first night's job. Two nights whose masters share a
    // delivered name then collided on one staged path, and the litter a kill
    // leaves behind named a job that never touched the file. Each row now goes
    // out under its own job id, which is also the id its journal row carries.
    final byJob = <int, List<DeliveryJournalEntry>>{};
    for (final row in due) {
      byJob.putIfAbsent(row.jobId, () => []).add(row);
    }
    for (final entry in byJob.entries) {
      await _sweepJob(
        destination: destination,
        targetId: targetId,
        jobId: entry.key,
        rows: entry.value,
        isCancelled: isCancelled,
        tally: tally,
      );
    }
    return tally.build();
  }

  /// Check what a peer destination published against the rig's own disk, and
  /// count each row as what it is.
  ///
  /// A peer row moves no bytes — publication IS the journal row, and the next
  /// act belongs to the desktop — so there is no attempt to re-make here and
  /// no transport to open. What the rig still owns is the source file, and
  /// that is the one thing this arm can be wrong about: a published artifact
  /// deleted from the rig used to be counted straight into `awaitingPull` with
  /// no read of any kind, so the row said "waiting for office-pc to pull"
  /// for ever, with no error and its attempt count untouched, while the
  /// manifest endpoint was already refusing to serve it as `sourceMissing`.
  ///
  /// The rig losing the file is the RIG's fact, not the desktop's debt. The
  /// row goes terminal here exactly as it does on every other transport, which
  /// takes it out of the manifest's entries, out of the awaiting-pull count,
  /// and into the never-arrived count the operator reads.
  Future<void> _sweepPublications({
    required ArtifactDestination destination,
    required int targetId,
    required List<DeliveryJournalEntry> rows,
    required DeliveryCancellation? isCancelled,
    required _Tally tally,
  }) async {
    for (final row in rows) {
      if (_stopRequested(isCancelled)) {
        // Nothing was read for this row, so nothing about it is restated. It
        // stays published and owed with its attempts where they were, and the
        // next pass checks it.
        tally.stoppedPending++;
        continue;
      }
      try {
        await DeliveryFile.confirmOnRig(row.filePath);
      } on DeliveryFailure catch (failure, stack) {
        final lost = DeliveryFailure(
          failure.kind,
          '${failure.message}, and ${destination.name} never pulled it: the '
          'file left the rig before the paired desktop collected it',
          cause: failure.cause,
        );
        _log(lost, destination, stack);
        // No attempt is counted. Reading the rig's own disk is not a
        // publication, and the row's `attempts` is what the operator's Retry
        // control resets — charging it here would misreport how many times
        // this file was actually offered.
        await _recordJournalOutcome(
          targetId: targetId,
          jobId: row.jobId,
          filePath: row.filePath,
          attempts: row.attempts,
          failure: lost,
          tally: tally,
        );
        continue;
      }
      tally.awaitingPull++;
    }
  }

  /// Re-attempt one job's due rows on one destination, over a transport built
  /// for that job.
  Future<void> _sweepJob({
    required ArtifactDestination destination,
    required int targetId,
    required int jobId,
    required List<DeliveryJournalEntry> rows,
    required DeliveryCancellation? isCancelled,
    required _Tally tally,
  }) async {
    if (_stopRequested(isCancelled)) {
      // Every row here is already `retrying` in the journal — they came off
      // `listPendingRetry` — so their true state needs no write and their
      // attempt counts stay where the schedule left them. No transport is
      // opened for a job the stop already reached.
      tally.stoppedPending += rows.length;
      return;
    }

    final files = <DeliveryFile>[];
    for (final row in rows) {
      try {
        files.add(await DeliveryFile.describe(row.filePath));
      } catch (error, stack) {
        final failure = _asFailure(error, destination);
        _log(failure, destination, stack);
        await _recordOutcome(
          targetId: targetId,
          jobId: row.jobId,
          filePath: row.filePath,
          bytes: row.bytes,
          failure: failure,
          tally: tally,
        );
      }
    }
    if (files.isEmpty) return;

    final transport = _transportFactory(destination, jobId);
    try {
      await transport.open(files);
    } catch (error, stack) {
      final failure = _asFailure(error, destination);
      _log(failure, destination, stack);
      await _destinationRefused(
        targetId: targetId,
        jobId: jobId,
        files: files,
        failure: failure,
        tally: tally,
      );
      await _closeQuietly(transport, tally);
      return;
    }

    for (final file in files) {
      if (_stopRequested(isCancelled)) {
        tally.stoppedPending++;
        continue;
      }
      await _deliverOne(
        transport: transport,
        targetId: targetId,
        jobId: jobId,
        file: file,
        destination: destination,
        tally: tally,
      );
    }

    await _closeQuietly(transport, tally);
  }

  Future<void> _deliverOne({
    required ArtifactTransport transport,
    required int targetId,
    required int jobId,
    required DeliveryFile file,
    required ArtifactDestination destination,
    required _Tally tally,
  }) async {
    // The attempt is recorded BEFORE the bytes move. A process killed
    // mid-transfer therefore leaves a row that the sweep re-picks, rather than
    // a file nothing remembers trying.
    final DeliveryJournalEntry attempt;
    try {
      attempt = await _journalWrite(
        () => _journal.recordAttempt(
          targetId: targetId,
          jobId: jobId,
          filePath: file.sourcePath,
          bytes: file.bytes,
          now: _clock(),
        ),
      );
    } catch (error, stack) {
      _journalWriteRefused(
        what: 'the attempt row for ${file.fileName}',
        filePath: file.sourcePath,
        detail: 'The file was not sent',
        error: error,
        stack: stack,
        tally: tally,
      );
      return;
    }

    // This file already arrived, so this pass does not send it again. The
    // journal refused to start an attempt on the row and handed it back as it
    // stands; a re-queued job runs its whole pass over the same artifacts, and
    // a paired desktop can acknowledge its pull at any moment — including
    // between the moment this pass selected the file and this write.
    if (attempt.state == DeliveryAttemptState.delivered) {
      tally.alreadyDelivered++;
      return;
    }

    final TransportDeliveryOutcome outcome;
    try {
      outcome = await transport.deliver(file);
    } catch (error, stack) {
      final failure = _asFailure(error, destination);
      _log(failure, destination, stack);
      await _recordJournalOutcome(
        targetId: targetId,
        jobId: jobId,
        filePath: file.sourcePath,
        attempts: attempt.attempts,
        failure: failure,
        tally: tally,
      );
      return;
    }

    if (outcome.disposition == DeliveryDisposition.awaitingPull) {
      tally.awaitingPull++;
      return;
    }

    // The bytes are on the destination from here on. A journal write that
    // fails now is a bookkeeping failure, not a transport one — calling it a
    // transport failure would schedule a retry of a file that already arrived.
    try {
      await _journalWrite(
        () => _journal.markDelivered(
          targetId: targetId,
          jobId: jobId,
          filePath: file.sourcePath,
          checksum: outcome.checksum,
          bytes: file.bytes,
          now: _clock(),
        ),
      );
      tally.delivered++;
    } catch (error, stack) {
      _journalWriteRefused(
        what: 'the delivered row for ${file.fileName}',
        filePath: file.sourcePath,
        detail:
            'The file DID reach ${outcome.destinationDescription}, but no row '
            'records that',
        error: error,
        stack: stack,
        tally: tally,
      );
    }
  }

  /// Leave one file owed because the pass was stopped before it was sent.
  ///
  /// No attempt is counted and no terminal state is written: the operator
  /// stopping a pass is not the file failing. The row goes in `retrying` with
  /// `attempts` untouched, which is what puts the file on the next sweep's
  /// work list — including the sweep the next boot runs.
  Future<void> _recordStillOwed({
    required int targetId,
    required int jobId,
    required String filePath,
    required int bytes,
    required _Tally tally,
  }) async {
    try {
      final owed = await _journalWrite(
        () => _journal.recordStillOwed(
          targetId: targetId,
          jobId: jobId,
          filePath: filePath,
          bytes: bytes,
          reason:
              'Delivery was stopped before this file was sent; it is '
              'still owed and the next retry sweep takes it',
          now: _clock(),
        ),
      );
      // A file that already arrived is not owed one. The journal left the row
      // alone, so this pass counts it for what it is rather than adding it to
      // the work the stop left outstanding.
      if (owed.state == DeliveryAttemptState.delivered) {
        tally.alreadyDelivered++;
        return;
      }
      tally.stoppedPending++;
    } catch (error, stack) {
      _journalWriteRefused(
        what: 'the still-owed row for ${p.basename(filePath)}',
        filePath: filePath,
        detail: 'Delivery was stopped before this file was sent',
        error: error,
        stack: stack,
        tally: tally,
      );
    }
  }

  /// Record a destination-level refusal against every file it stopped, and
  /// state the cause once.
  ///
  /// The transport would not open, so this is ONE fact about the destination
  /// rather than one fact per file. Every file still gets its own journal row —
  /// that is what the sweep works from — but the sentence goes in the report a
  /// single time, naming how many files it held up. Fanned out per file it
  /// wrote the same words into the morning report once per artifact — nine
  /// byte-identical lines for one unopenable folder on a four-master night,
  /// and more than that on a real one. Per-file causes are unaffected: they
  /// name their own file and still list one by one.
  Future<void> _destinationRefused({
    required int targetId,
    required int jobId,
    required List<DeliveryFile> files,
    required DeliveryFailure failure,
    required _Tally tally,
  }) async {
    var stopped = 0;
    for (final file in files) {
      final recorded = await _recordOutcome(
        targetId: targetId,
        jobId: jobId,
        filePath: file.sourcePath,
        bytes: file.bytes,
        failure: failure,
        tally: tally,
        stateProblem: false,
      );
      if (recorded) stopped++;
    }
    // Nothing was held up: every file this destination was handed had already
    // arrived on an earlier pass, and a file that is already there was not
    // stopped by a transport that would not open.
    if (stopped == 0) return;
    tally.problems.add(
      '$stopped file${stopped == 1 ? '' : 's'} '
      '${stopped == 1 ? 'was' : 'were'} not sent to ${tally.destination.name}: '
      '${failure.journalText}',
    );
  }

  /// Count an attempt for one file and record why it failed. Returns whether
  /// an outcome was recorded for it.
  ///
  /// The attempt is counted even when the whole destination failed to open:
  /// the budget is per file per destination, and a file whose attempts never
  /// increment is a file that retries until the end of time.
  ///
  /// False for a file that already arrived — the journal refuses to start an
  /// attempt on a delivered row, and writing a failure over it would take a
  /// file the operator has back off them — and for a file whose journal write
  /// was refused, which [_journalWriteRefused] has already stated.
  ///
  /// [stateProblem] false leaves the sentence to the caller, which is how a
  /// destination-level cause is stated once for the destination rather than
  /// once per file.
  Future<bool> _recordOutcome({
    required int targetId,
    required int jobId,
    required String filePath,
    required int bytes,
    required DeliveryFailure failure,
    required _Tally tally,
    bool stateProblem = true,
  }) async {
    final DeliveryJournalEntry attempt;
    try {
      attempt = await _journalWrite(
        () => _journal.recordAttempt(
          targetId: targetId,
          jobId: jobId,
          filePath: filePath,
          bytes: bytes,
          now: _clock(),
        ),
      );
    } catch (error, stack) {
      _journalWriteRefused(
        what: 'the attempt row for ${p.basename(filePath)}',
        filePath: filePath,
        detail: 'The outcome it would have carried was ${failure.journalText}',
        error: error,
        stack: stack,
        tally: tally,
      );
      return false;
    }
    if (attempt.state == DeliveryAttemptState.delivered) {
      tally.alreadyDelivered++;
      return false;
    }
    await _recordJournalOutcome(
      targetId: targetId,
      jobId: jobId,
      filePath: filePath,
      attempts: attempt.attempts,
      failure: failure,
      tally: tally,
      stateProblem: stateProblem,
    );
    return true;
  }

  Future<void> _recordJournalOutcome({
    required int targetId,
    required int jobId,
    required String filePath,
    required int attempts,
    required DeliveryFailure failure,
    required _Tally tally,
    bool stateProblem = true,
  }) async {
    final exhausted = _policy.isExhausted(attempts);
    final terminal = !failure.retryable || exhausted;
    final text = exhausted && failure.retryable
        ? '${failure.journalText} (after $attempts attempts)'
        : failure.journalText;
    try {
      // The journal refuses to move a row the desktop already acknowledged, and
      // hands back the row as it stands. That is not a failed write: the file
      // arrived while this attempt was in flight, which is exactly what the
      // acknowledgement means. Count it for what happened, and say nothing
      // about a problem that resolved itself.
      final DeliveryJournalEntry recorded;
      if (terminal) {
        recorded = await _journalWrite(
          () => _journal.markFailed(
            targetId: targetId,
            jobId: jobId,
            filePath: filePath,
            error: text,
            now: _clock(),
          ),
        );
      } else {
        recorded = await _journalWrite(
          () => _journal.markRetrying(
            targetId: targetId,
            jobId: jobId,
            filePath: filePath,
            error: text,
            now: _clock(),
          ),
        );
      }
      if (recorded.state == DeliveryAttemptState.delivered) {
        tally.alreadyDelivered++;
        return;
      }
      if (terminal) {
        tally.failed++;
      } else {
        tally.retrying++;
      }
    } catch (error, stack) {
      _journalWriteRefused(
        what:
            'the ${terminal ? 'failed' : 'retrying'} row for '
            '${p.basename(filePath)}',
        filePath: filePath,
        detail: 'The attempt was spent and its outcome is unrecorded',
        error: error,
        stack: stack,
        tally: tally,
      );
    }
    if (stateProblem) tally.problems.add(text);
  }

  /// Perform one journal write, asking again a bounded number of times.
  ///
  /// Throws the LAST refusal when the budget is spent, so the caller writes
  /// the honest sentence rather than this deciding what the failure means.
  Future<T> _journalWrite<T>(Future<T> Function() write) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await write();
      } on Object {
        if (attempt >= _journalWriteAttempts) rethrow;
        await Future<void>.delayed(_journalWriteBackoff);
      }
    }
  }

  /// State that a journal write was refused, and count the file as one nothing
  /// recorded.
  ///
  /// Never counted as retrying: the sweep's whole work list comes from
  /// `delivery_journal`, so a file with no row is a file no later pass can
  /// find. Reporting it as retrying is the promise of an attempt that will
  /// never be made.
  void _journalWriteRefused({
    required String what,
    required String filePath,
    required String detail,
    required Object error,
    required StackTrace stack,
    required _Tally tally,
  }) {
    _logger?.error(
      'The delivery journal refused $what for $filePath after '
      '$_journalWriteAttempts attempts: $error',
      source: 'DeliveryService',
      fields: {'stack': stack.toString()},
    );
    tally.unjournalled++;
    tally.problems.add(
      'The delivery journal refused $what after $_journalWriteAttempts '
      'attempts ($error). $detail. No retry sweep can pick this file up, '
      'because the sweep reads its work list out of the journal',
    );
  }

  Future<void> _closeQuietly(ArtifactTransport transport, _Tally tally) async {
    try {
      await transport.close();
    } catch (error, stack) {
      // Releasing the transport failed after the deliveries were already
      // decided. The outcomes above stand; this is recorded so a leaked key
      // file or connection is visible in the report.
      _logger?.warning(
        'Closing the ${tally.destination.kind.wire} transport for '
        '${tally.destination.name} failed: $error',
        source: 'DeliveryService',
        fields: {'stack': stack.toString()},
      );
      tally.problems.add(
        'Releasing the connection to ${tally.destination.name} failed: $error',
      );
    }
  }

  DeliveryFailure _asFailure(Object error, ArtifactDestination destination) {
    if (error is DeliveryFailure) return error;
    return DeliveryFailure(
      DeliveryFailureKind.transportFailure,
      'Delivery to ${destination.name} raised $error',
      cause: error,
    );
  }

  void _log(
    DeliveryFailure failure,
    ArtifactDestination destination,
    StackTrace stack,
  ) {
    final message =
        'Delivery to ${destination.name} (${destination.kind.wire}): '
        '${failure.journalText}';
    if (failure.retryable) {
      _logger?.warning(message, source: 'DeliveryService');
    } else {
      _logger?.error(
        message,
        source: 'DeliveryService',
        fields: {'stack': stack.toString()},
      );
    }
  }
}

/// Running counts for one destination on one pass.
class _Tally {
  final ArtifactDestination destination;

  /// The row id every journal write in this pass uses, resolved by the caller
  /// before any file is touched.
  final int targetId;

  int delivered = 0;
  int alreadyDelivered = 0;
  int awaitingPull = 0;
  int retrying = 0;
  int stoppedPending = 0;
  int suspended = 0;
  int failed = 0;
  int unjournalled = 0;
  final List<String> problems = [];

  _Tally(this.destination, this.targetId);

  DeliveryDestinationReport build() => DeliveryDestinationReport(
    targetId: targetId,
    name: destination.name,
    kind: destination.kind,
    delivered: delivered,
    alreadyDelivered: alreadyDelivered,
    awaitingPull: awaitingPull,
    retrying: retrying,
    stoppedPending: stoppedPending,
    suspended: suspended,
    failed: failed,
    unjournalled: unjournalled,
    problems: List<String>.unmodifiable(problems),
  );
}
