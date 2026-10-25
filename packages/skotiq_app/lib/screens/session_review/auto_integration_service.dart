import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

/// App-settings key controlling whether the post-session integration runs
/// automatically when a sequence run completes. Off by default — the user opts
/// in from Settings so an unattended night "just has the master ready" in the
/// morning.
const String kAutoIntegrateSettingKey = NightEndAutomationSettings.buildKey;

/// App-settings key controlling whether the dawn autopilot's Darkroom pass runs
/// after the masters exist: compose a first-draft recipe per master, render the
/// draft, write the night report, deliver it, and send the morning message.
///
/// **Absent means whatever [kAutoIntegrateSettingKey] is set to.** The draft is
/// the half of the integration opt-in the operator actually looks at in the
/// morning, so a rig that integrates all night and then declines to draft would
/// be the surprising behaviour — but a FRESH install has not opted in, and a
/// plain "absent means on" put the master switch on the Darkroom autopilot page
/// in the `[ON]` position on a machine whose own next row read "Auto-integrate
/// has to be on for any of this to run … It is currently off". A headline
/// feature cannot ship armed on a rig where its stated prerequisite ships off.
///
/// The prerequisite is what stays off — automatic integration writes masters
/// and burns an hour of CPU at the end of every run, which is the operator's
/// call to make, not a default to flip on their behalf. So the switch is the
/// one that follows: off until there is something for it to act on, on the
/// moment there is.
///
/// Only the value of an ABSENT row is coupled. An explicit `true` or `false` is
/// the operator's own decision and is read back exactly, so nothing they set
/// here is quietly overridden by a setting on another page — and an install
/// that has been drafting on the old default keeps drafting, because it is
/// drafting precisely when auto-integration is on.
const String kDarkroomAutoDraftSettingKey = 'darkroom.auto_draft';

/// Result of an auto-integration attempt, surfaced to the run-completion host so
/// it can toast / notify the user.
class AutoIntegrationResult {
  /// True when an integration / accumulation actually ran.
  final bool ran;

  /// Human-readable summary for the toast / notification body.
  final String message;

  /// The new master id when a fresh batch integration produced one, else null.
  final int? masterId;

  /// True when the feature was enabled but processing failed.
  final bool failed;

  /// What the Darkroom pass did with the masters this run produced, or null
  /// when it did not run (the setting is off, or the integration produced
  /// nothing to draft over).
  final DawnJobOutcome? darkroom;

  /// Why the Darkroom pass did not run, or null when it did. Stated so a run
  /// that produced masters and no draft explains itself instead of looking
  /// half-finished.
  final String? darkroomSkippedReason;

  const AutoIntegrationResult({
    required this.ran,
    required this.message,
    this.masterId,
    this.failed = false,
    this.darkroom,
    this.darkroomSkippedReason,
  });

  static const AutoIntegrationResult disabled =
      AutoIntegrationResult(ran: false, message: 'Auto-integration disabled.');
}

/// What an operator-requested Darkroom pass did.
///
/// Distinct from [AutoIntegrationResult] because a manual pass integrates
/// nothing: the masters already exist and this only re-interprets them.
class ManualDarkroomRun {
  /// The job's ending, or null when the pass could not be started at all.
  final DawnJobOutcome? outcome;

  /// Why the pass could not be started, or null when it ran. A job that ran
  /// and failed reports through [outcome] — this is only for a pass that never
  /// got a row.
  final String? failure;

  /// True when the refusal was "one is already live over this session", so the
  /// surface can go on showing that pass rather than treating the press as an
  /// error.
  final bool alreadyRunning;

  /// Whether finished runs also draft themselves. Carried so the surface can
  /// say that this draft is a one-off, rather than leaving the operator to
  /// assume the automatic pass they switched off has come back.
  final bool autoDraftEnabled;

  const ManualDarkroomRun({
    required this.outcome,
    required this.failure,
    required this.autoDraftEnabled,
    this.alreadyRunning = false,
  });

  /// The sentence the surface shows when the pass returns.
  String get message {
    final started = failure;
    if (started != null) return started;
    final result = outcome;
    if (result == null) {
      return 'The Darkroom pass returned nothing to report.';
    }
    switch (result.state) {
      case DarkroomJobState.done:
        final drafts = result.report?.draftsRendered ?? 0;
        return drafts > 0
            ? 'Darkroom pass finished — $drafts draft'
                '${drafts == 1 ? '' : 's'} ready.'
            : 'Darkroom pass finished without a draft; the night report says '
                'why.';
      case DarkroomJobState.cancelled:
        return result.failure ?? 'The Darkroom pass was stopped.';
      case DarkroomJobState.queued:
      case DarkroomJobState.running:
      case DarkroomJobState.failed:
        return result.failure ?? 'The Darkroom pass did not finish.';
    }
  }

  /// True when the pass ran to the end.
  bool get succeeded => outcome?.succeeded ?? false;
}

/// Where the "an integration is in flight" marker is written — the directory
/// that holds the database, so the marker travels with the profile it
/// describes and is found by the same connection that opens it.
///
/// Resolves to null when there is no such path: a platform with no documents
/// directory and no `SKOTIQ_DATABASE_DIR`. The integration still runs.
/// Refusing to integrate a finished night because a warning file could not be
/// placed would trade a real master for a diagnostic — but the cost is stated
/// in the log rather than left to be discovered at the next crash.
final integrationMarkerDirectoryProvider = FutureProvider<Directory?>((
  ref,
) async {
  try {
    return (await resolveDefaultDatabaseFile()).parent;
  } catch (error) {
    ref.read(loggingServiceProvider).warning(
      'The integration crash marker has nowhere to live; an interrupted '
      'integration will not be reported at the next launch',
      source: 'AutoIntegrationService',
      fields: {'error': '$error'},
    );
    return null;
  }
});

/// Host-authoritative setting used by both the local rig and remote clients.
final autoIntegrationEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.getAutoIntegrationEnabled();
  }
  final raw =
      await ref.watch(settingsDaoProvider).getSetting(kAutoIntegrateSettingKey);
  return raw == 'true';
});

final autoIntegrationSettingsActionsProvider = Provider((ref) {
  final backend = ref.watch(backendProvider);
  return AutoIntegrationSettingsActions(
    ref,
    remote: backend is NetworkBackend ? backend : null,
    local: backend is NetworkBackend ? null : ref.read(settingsDaoProvider),
  );
});

class AutoIntegrationSettingsActions {
  AutoIntegrationSettingsActions(
    this._ref, {
    required NetworkBackend? remote,
    required SettingsDao? local,
  })  : _remote = remote,
        _local = local;

  final Ref _ref;
  final NetworkBackend? _remote;
  final SettingsDao? _local;

  Future<void> setEnabled(bool enabled) async {
    final remote = _remote;
    if (remote != null) {
      await remote.setAutoIntegrationEnabled(enabled);
    } else {
      await _local!.setSetting(kAutoIntegrateSettingKey, enabled.toString());
    }
    _ref.invalidate(autoIntegrationEnabledProvider);
  }
}

/// Runs the post-session integration automatically at the end of a sequence run
/// when the opt-in setting is enabled (the "wake up to a finished image" hook).
///
/// For each target+filter group captured in the just-completed session it:
///  - folds the accepted subs into the target's active *accumulating* master
///    when one exists (multi-night growth), else
///  - runs a one-shot batch integration to produce a fresh linear master.
///
/// It never blocks the UI — the run-completion listener fires-and-forgets
/// [maybeRunForSession]; failures are returned, not thrown, so a botched
/// auto-run never crashes the app.
class AutoIntegrationService {
  AutoIntegrationService(this._ref);

  final Ref _ref;

  /// The cancellation handle the native post-session pipeline knows this
  /// session's integration by.
  ///
  /// Derived from the session id alone, so a handle raised from anywhere —
  /// safing, a headless endpoint, another process's restart — names the same
  /// run without holding a reference to this object. A run started without one
  /// is not cancellable and the native side says so, which is why every
  /// integrate and fold on this path carries it.
  static String integrationRunIdFor(int sessionId) => 'post-session-$sessionId';

  /// Run auto-integration for [sessionId] when enabled. Returns
  /// [AutoIntegrationResult.disabled] when the setting is off or there is
  /// nothing to integrate; otherwise a summary of what ran.
  Future<AutoIntegrationResult> maybeRunForSession(int sessionId) async {
    try {
      return await _maybeRunForSession(sessionId);
    } catch (error) {
      _ref.read(loggingServiceProvider).error(
        'Automatic post-session integration failed',
        source: 'AutoIntegrationService',
        fields: {'sessionId': sessionId, 'error': '$error'},
      );
      return AutoIntegrationResult(
        ran: false,
        failed: true,
        message: 'Auto-integration failed: $error',
      );
    }
  }

  Future<AutoIntegrationResult> _maybeRunForSession(int sessionId) async {
    final enabled = await _isEnabled();
    if (!enabled) return AutoIntegrationResult.disabled;

    final images =
        await _ref.read(imagesDaoProvider).getImagesForSession(sessionId);
    final accepted = images
        .where((i) => i.frameType == 'light' && i.isAccepted)
        .toList(growable: false);
    if (accepted.isEmpty) {
      return const AutoIntegrationResult(
        ran: false,
        message: 'No accepted subs to integrate.',
      );
    }

    // Resolved only now that there is real work to guard: a night with the
    // setting off or nothing to integrate has no window to crash in, and
    // asking for the path anyway would log its failure at the end of every
    // run instead of the ones it applies to.
    final markerDir = await _markerDirectory();
    // Read BEFORE the integrate, not after it. The answer decides what the
    // marker records the moment the masters are finished, and a settings read
    // sitting between "the last master is registered" and "the Darkroom job
    // row exists" is time inside the one window neither record covers. Reading
    // it here also fixes the decision to when the pass started, which is the
    // run the operator's setting was about.
    final autoDraft = await isDarkroomAutoDraftEnabled();
    try {
      return await _integrate(sessionId, accepted, markerDir, autoDraft);
    } finally {
      // Cleared on EVERY ending the integration can reach — the success, the
      // early returns, and the caught failures it reports as a result. Only a
      // process that never gets here leaves the marker behind, which is
      // exactly the interruption it exists to record.
      if (markerDir != null) await clearIntegrationMarker(markerDir);
    }
  }

  Future<AutoIntegrationResult> _integrate(
    int sessionId,
    List<DbCapturedImage> accepted,
    Directory? markerDir,
    bool autoDraft,
  ) async {
    final settings = await _loadDefaultSettings();
    final targetId = accepted
        .map((i) => i.targetId)
        .firstWhere((id) => id != null, orElse: () => null);
    final targetName = targetId != null
        ? (await _ref.read(targetsDaoProvider).getTargetById(targetId))?.name
        : null;

    // Multi-night + multi-filter: split tonight's accepted subs by filter and
    // route EACH bucket independently — fold into that filter's active
    // accumulating master when one exists (multi-night growth), else collect it
    // for a fresh batch integration. An LRGB / SHO night must never silently
    // drop the subs of any non-dominant filter: every bucket is either folded or
    // batch-integrated, and the toast reports the total across all of them.
    final byFilter = _groupByFilter(accepted);

    // Buckets without an accumulating master are batch-integrated together (the
    // integrate service fans out per filter itself); buckets with one are folded.
    final batchSubs = <DbCapturedImage>[];
    var accumulatedSubs = 0;
    var accumulatedRejected = 0;
    var accumulatedSeconds = 0.0;
    final accumulatedInto = <String>[];

    // The window opens here, at the first fold, not at the batch integrate
    // below: a kill during `addNight` strands the night just as completely.
    // No paths yet — a fold writes into a master that already exists, so
    // there is no half-created file to warn about until the batch phase
    // rewrites this marker with the paths it is about to create.
    var marker = InterruptedIntegration(
      sessionId: sessionId,
      targetName: targetName,
      startedAtUtc: DateTime.now().toUtc(),
      intendedMasterPaths: const [],
    );
    if (markerDir != null) await markIntegrationStarted(markerDir, marker);

    try {
      for (final bucket in byFilter.entries) {
        final filter = bucket.key.isEmpty ? null : bucket.key;
        final group = bucket.value;

        final master = targetId == null
            ? null
            : await _ref
                .read(integratedMastersDaoProvider)
                .getAccumulatingForTargetFilter(
                    targetId: targetId, filter: filter);
        if (master == null) {
          // No accumulating master for this filter — batch-integrate it.
          batchSubs.addAll(group);
          continue;
        }

        final result =
            await _ref.read(masterAccumulationServiceProvider).addNight(
                  masterId: master.id,
                  subs: group,
                  label: DateTime.now().toIso8601String().split('T').first,
                  settings: settings,
                  runId: integrationRunIdFor(sessionId),
                );
        accumulatedSubs += result.framesAdded;
        accumulatedRejected += result.rejected;
        accumulatedSeconds += result.totalIntegrationSec;
        accumulatedInto.add(master.name);
      }
    } catch (e) {
      return AutoIntegrationResult(
        ran: false,
        failed: true,
        message: 'Auto-accumulate failed: $e',
      );
    }

    // One-shot batch integration of every filter bucket that had no accumulating
    // master to grow.
    var batchSubsIntegrated = 0;
    var batchRejected = 0;
    var batchSeconds = 0.0;
    var batchMasters = 0;
    int? firstBatchMasterId;
    if (batchSubs.isNotEmpty) {
      try {
        final outDir = await _outputDir();
        // One stamp for the whole run, so every master of one night shares it
        // AND every path is known before the first byte is written. The
        // marker below names those paths; a per-bucket `DateTime.now()` inside
        // the builder would make them unknowable until after the write that
        // the marker exists to warn about.
        final stamp = DateTime.now().millisecondsSinceEpoch;
        // The integrate service buckets `batchSubs` by the same rule this
        // service used to build `byFilter` (trim, empty and null together), so
        // the buckets it will produce are exactly these.
        final intendedPaths = batchSubs
            .map((sub) => _filterBucketOf(sub.filter))
            .toSet()
            .map(
              (bucket) => _masterPath(
                outDir: outDir,
                targetName: targetName,
                stamp: stamp,
                filterBucket: bucket,
              ),
            )
            .toList(growable: false);
        marker = InterruptedIntegration(
          sessionId: sessionId,
          targetName: targetName,
          startedAtUtc: DateTime.now().toUtc(),
          intendedMasterPaths: intendedPaths,
        );
        if (markerDir != null) await markIntegrationStarted(markerDir, marker);
        final outcomes =
            await _ref.read(postSessionIntegrationServiceProvider).integrate(
                  subs: batchSubs,
                  settings: settings,
                  targetId: targetId,
                  targetName: targetName,
                  runId: integrationRunIdFor(sessionId),
                  sessionId: sessionId,
                  // The drafts that follow belong to the same pass, which the
                  // Darkroom pass below ends.
                  plannedDrafts: autoDraft
                      ? batchSubs
                          .map((sub) => _filterBucketOf(sub.filter))
                          .toSet()
                          .length
                      : 0,
                  closePass: !autoDraft,
                  outputFitsPathBuilder: (filterBucket) => _masterPath(
                    outDir: outDir,
                    targetName: targetName,
                    stamp: stamp,
                    filterBucket: filterBucket,
                  ),
                );
        batchSubsIntegrated =
            outcomes.fold<int>(0, (a, o) => a + o.result.framesIntegrated);
        batchRejected =
            outcomes.fold<int>(0, (a, o) => a + o.result.framesRejected);
        batchSeconds = outcomes.fold<double>(
            0, (a, o) => a + o.result.totalIntegrationSec);
        batchMasters = outcomes.length;
        firstBatchMasterId =
            outcomes.isNotEmpty ? outcomes.first.masterId : null;
      } catch (e) {
        return AutoIntegrationResult(
          ran: false,
          failed: true,
          message: 'Auto-integrate failed: $e',
        );
      }
    }

    final totalKept = accumulatedSubs + batchSubsIntegrated;
    final totalRejected = accumulatedRejected + batchRejected;
    if (totalKept == 0 && accumulatedInto.isEmpty) {
      return const AutoIntegrationResult(
        ran: false,
        message: 'Integration produced no master.',
      );
    }

    // THE SEAM. Every master this pass set out to write is on disk and carries
    // a library row; the Darkroom job row that owes the drafts, the night
    // report, the delivery and the morning message does not exist yet. The two
    // cannot be committed together from here — the masters are finalized inside
    // `PostSessionIntegrationService`, one transaction per filter bucket, and
    // this service is only handed the outcomes once each has already committed
    // — so what is durable at this instant is the marker, and it is advanced
    // before anything else happens.
    //
    // A kill after this line is read at the next open as the pass that is owed,
    // and the owed pass is queued there; a kill before it is still the
    // interrupted integrate it always was. What no longer exists is a kill that
    // is reported as an interrupted integrate while the masters sit finished on
    // disk — the night that was told to run the integration it had just
    // completed.
    if (markerDir != null) {
      await markPassReached(
        markerDir,
        marker,
        autoDraft
            ? PostSessionPassStage.darkroomPassOwed
            : PostSessionPassStage.mastersOnly,
      );
    }

    // The Darkroom pass owns the morning message when it runs: it knows what
    // was drafted, what the calibration did and where the artifacts went, so a
    // separate "master ready" push minutes earlier would be the same night
    // announced twice.
    final darkroom = await _runDarkroom(sessionId, autoDraft: autoDraft);
    if (autoDraft && batchMasters > 0) {
      final failure = darkroom.outcome?.failure ?? darkroom.skippedReason;
      _ref.read(passReporterProvider).reportForSession(
        sessionId,
        PassKinds.passEnded,
        <String, dynamic>{
          'ok': failure == null,
          if (failure != null) 'error': failure,
        },
      );
    }

    await _afterSuccess(
      sessionId: sessionId,
      targetId: targetId,
      targetName: targetName,
      integrationSeconds: accumulatedSeconds + batchSeconds,
      framesKept: totalKept,
      framesRejected: totalRejected,
      announce: darkroom.outcome == null,
    );

    return AutoIntegrationResult(
      ran: true,
      masterId: firstBatchMasterId,
      darkroom: darkroom.outcome,
      darkroomSkippedReason: darkroom.skippedReason,
      message: _summaryMessage(
        totalKept: totalKept,
        batchMasters: batchMasters,
        accumulatedInto: accumulatedInto,
        darkroom: darkroom.outcome,
      ),
    );
  }

  /// Run the Darkroom pass for [sessionId], or state why it did not run.
  ///
  /// The pass never throws out of here: its own job row records every ending,
  /// and a draft that could not be made must not undo masters that already
  /// exist on disk.
  ///
  /// [autoDraft] is decided by the caller BEFORE the integrate starts — see
  /// [_maybeRunForSession] — so the only thing standing between the finished
  /// masters and the durable `darkroom_jobs` row is the insert itself.
  Future<({DawnJobOutcome? outcome, String? skippedReason})> _runDarkroom(
    int sessionId, {
    required bool autoDraft,
  }) async {
    if (!autoDraft) {
      return (
        outcome: null,
        skippedReason:
            'The automatic Darkroom draft is switched off, so tonight\'s '
            'masters were integrated without one.',
      );
    }
    try {
      final outcome =
          await _ref.read(dawnAutopilotServiceProvider).runDawnForSession(
                sessionId,
              );
      return (outcome: outcome, skippedReason: null);
    } on DarkroomSessionBusyException catch (busy) {
      // The night already has a pass — an operator's "Process now", or a
      // re-queued row the crash recovery picked up. A second one would fight it
      // for the render cache, so this run states which pass has the night
      // rather than adding one.
      return (
        outcome: null,
        skippedReason:
            'The masters were integrated without a new draft: ${busy.message}',
      );
    } catch (error) {
      _ref.read(loggingServiceProvider).error(
        'The Darkroom pass could not be started',
        source: 'AutoIntegrationService',
        fields: {'sessionId': sessionId, 'error': '$error'},
      );
      return (
        outcome: null,
        skippedReason:
            'The Darkroom pass could not be started, so the masters exist '
            'without a draft: $error',
      );
    }
  }

  /// Run the Darkroom pass for [sessionId] because the operator asked — the
  /// "process tonight now" action.
  ///
  /// Same conventions as [_runDarkroom]: it never throws, because the job row
  /// records every ending and a draft that could not be made must not read as
  /// an app failure. The job is `manual`, so it produces the same drafts, the
  /// same report and the same delivery, and sends NO morning notification —
  /// the operator is standing at the machine.
  ///
  /// The [kDarkroomAutoDraftSettingKey] opt-out is REPORTED, not enforced: it
  /// governs whether a finished run drafts itself unattended, and a press is
  /// the operator asking for exactly this one. Refusing here would leave the
  /// only way to make a draft behind a settings toggle they turned off for a
  /// different reason. [ManualDarkroomRun.autoDraftEnabled] carries the state
  /// so the surface can say that nights are not drafting themselves.
  Future<ManualDarkroomRun> runDarkroomNow(int sessionId) async {
    final autoDraft = await isDarkroomAutoDraftEnabled();
    try {
      final outcome = await _ref
          .read(dawnAutopilotServiceProvider)
          .processSessionNow(sessionId);
      return ManualDarkroomRun(
        outcome: outcome,
        failure: null,
        autoDraftEnabled: autoDraft,
      );
    } on DarkroomSessionBusyException catch (busy) {
      // Not an error: a pass over this session is already under way, and the
      // press is a second one. Say which pass holds it rather than reporting
      // a failure the operator cannot act on.
      _ref.read(loggingServiceProvider).info(
        'A second Darkroom pass over this session was refused; one is already '
        'live',
        source: 'AutoIntegrationService',
        fields: {
          'sessionId': sessionId,
          'liveJobId': busy.jobId,
          'liveJobState': busy.state.wire,
        },
      );
      return ManualDarkroomRun(
        outcome: null,
        failure: busy.message,
        autoDraftEnabled: autoDraft,
        alreadyRunning: true,
      );
    } catch (error) {
      _ref.read(loggingServiceProvider).error(
        'The requested Darkroom pass could not be started',
        source: 'AutoIntegrationService',
        fields: {'sessionId': sessionId, 'error': '$error'},
      );
      return ManualDarkroomRun(
        outcome: null,
        failure: 'The Darkroom pass could not be started: $error',
        autoDraftEnabled: autoDraft,
      );
    }
  }

  /// Whether a Darkroom pass is queued or running over [sessionId] right now.
  ///
  /// The durable answer, read from `darkroom_jobs`. Session Review polls it so
  /// the header offers "Process now" or "Stop" according to what is actually
  /// live, rather than according to what this instance of the screen happens to
  /// have started — a screen that was popped and re-pushed knows nothing.
  Future<bool> isDarkroomPassLiveForSession(int sessionId) async {
    final live = await _ref
        .read(dawnAutopilotServiceProvider)
        .liveJobsForSession(sessionId);
    return live.isNotEmpty;
  }

  /// Whether a finished run drafts itself.
  ///
  /// An explicit value is the operator's own and is read back as written; an
  /// ABSENT row follows [kAutoIntegrateSettingKey], which is the setting that
  /// decides whether there will be a master to draft at all. A fresh install
  /// therefore reports this off, because that is what the pass will do there.
  ///
  /// A settings store that cannot be read at all reports ON, because that is
  /// what the pass itself will do with the same unreadable row — the switch
  /// must not show `off` for a feature that is about to run — with the storage
  /// failure logged so the answer is never a quiet guess.
  Future<bool> isDarkroomAutoDraftEnabled() async {
    try {
      final raw = await _ref
          .read(settingsDaoProvider)
          .getSetting(kDarkroomAutoDraftSettingKey);
      if (raw == 'false') return false;
      if (raw == 'true') return true;
      return _isEnabled();
    } catch (error) {
      _ref.read(loggingServiceProvider).warning(
        'The Darkroom auto-draft setting could not be read; reporting it as on',
        source: 'AutoIntegrationService',
        fields: {'key': kDarkroomAutoDraftSettingKey, 'error': '$error'},
      );
      return true;
    }
  }

  /// Ask the Darkroom job [jobId] to stop.
  ///
  /// Exposed here because the run-completion host is where an operator's
  /// "stop" reaches the dawn pipeline; the flag it raises is the engine's own
  /// plus the autopilot's, so a render already inside Rust stops at its next
  /// poll and the pipeline stops before the next master.
  Future<void> cancelDarkroomJob(int jobId, {String? reason}) {
    return _ref
        .read(dawnAutopilotServiceProvider)
        .requestCancel(jobId, reason: reason);
  }

  /// Ask every Darkroom pass live over [sessionId] to stop, and report which
  /// jobs those were.
  ///
  /// [runDarkroomNow] only hands its job id back when the pass has already
  /// finished, so an operator standing in front of a pass that is minutes into
  /// rendering has nothing to name. The durable rows do.
  ///
  /// **Every live row, not the newest one.** This used to stop at the first
  /// non-terminal job it found, which was written when one pass per session was
  /// assumed rather than enforced. It was not: a re-pushed Session Review
  /// offered "Process now" over a session that was already being processed, and
  /// a Stop then cancelled the newer pass while the older one ran on to done,
  /// delivery included. The enqueue seam now refuses the second pass, and this
  /// covers the rows a build without that guard already left behind.
  ///
  /// Returns the jobs asked to stop, oldest first, or an empty list when the
  /// session has no live job — the press landed in the gap between the enqueue
  /// and the row, or the pass finished on its own. The caller states which
  /// happened rather than reporting a stop that did not occur.
  Future<List<int>> cancelDarkroomPassForSession(
    int sessionId, {
    String? reason,
  }) async {
    final live = await _ref
        .read(dawnAutopilotServiceProvider)
        .liveJobsForSession(sessionId);
    final stopped = <int>[];
    for (final job in live) {
      await cancelDarkroomJob(job.id!, reason: reason);
      stopped.add(job.id!);
    }
    return stopped;
  }

  /// Build the run-completion toast covering BOTH paths: subs folded into
  /// existing accumulating masters and subs freshly batch-integrated. Reports
  /// the total subs across every filter so a multi-filter night never
  /// under-reports.
  static String _summaryMessage({
    required int totalKept,
    required int batchMasters,
    required List<String> accumulatedInto,
    DawnJobOutcome? darkroom,
  }) {
    final drafts = darkroom?.report?.draftsRendered;
    if (drafts != null && drafts > 0) {
      return 'Your image is ready — integrated $totalKept subs, '
          '$drafts draft${drafts == 1 ? '' : 's'} ready in the Darkroom.';
    }
    final parts = <String>[];
    if (batchMasters > 0) {
      parts.add('$batchMasters master${batchMasters == 1 ? '' : 's'}');
    }
    if (accumulatedInto.isNotEmpty) {
      parts.add(accumulatedInto.length == 1
          ? '${accumulatedInto.single} (grown)'
          : '${accumulatedInto.length} accumulating masters (grown)');
    }
    final into = parts.isEmpty ? 'your library' : parts.join(' + ');
    return 'Your image is ready — integrated $totalKept subs into $into.';
  }

  /// Split accepted subs into filter buckets keyed by their trimmed filter name
  /// (empty string for the no-filter bucket). The trim mirrors the
  /// case-sensitive whitespace handling so a whitespace-padded filter name never
  /// fragments a bucket or silently drops its subs.
  Map<String, List<DbCapturedImage>> _groupByFilter(
      List<DbCapturedImage> subs) {
    final out = <String, List<DbCapturedImage>>{};
    for (final s in subs) {
      final key = (s.filter ?? '').trim();
      out.putIfAbsent(key, () => <DbCapturedImage>[]).add(s);
    }
    return out;
  }

  /// Fail-soft post-success hook fired after a master grows (accumulate) or is
  /// freshly integrated (batch). Two side effects, both individually guarded so
  /// neither can break the run-completion path:
  ///
  ///  (a) compute + persist the Night Doctor report for [sessionId]
  ///      ([NightAnalysisService.computeReport]), and
  ///  (b) enqueue a "master ready" phone push
  ///      (`Your TARGET master is ready — Hh Mm, +x% from culling`), only when
  ///      [announce] is true.
  ///
  /// [announce] is false when the Darkroom pass ran: that pass sends the
  /// morning message, which states everything this push does and adds what was
  /// drafted, what the calibration did, and where the files went. Two messages
  /// for one night is how an operator learns to ignore both.
  ///
  /// Any failure in either is swallowed (logged via the result is not possible
  /// here — this runs after the result is decided) so an unattended morning
  /// still has its master even if reporting / push fails.
  Future<void> _afterSuccess({
    required int sessionId,
    int? targetId,
    String? targetName,
    required double integrationSeconds,
    required int framesKept,
    required int framesRejected,
    required bool announce,
  }) async {
    // (a) Night Doctor report. Best-effort: a reporting failure must never
    // sink the integration run.
    try {
      await _ref.read(nightAnalysisServiceProvider).computeReport(
            sessionId: sessionId,
            targetId: targetId,
          );
    } catch (_) {
      // Swallow — the master is already produced; a missing report is benign.
    }

    // (b) "Master ready" push. Independently guarded from (a).
    if (!announce) return;
    try {
      final body = _masterReadyBody(
        targetName: targetName,
        integrationSeconds: integrationSeconds,
        framesKept: framesKept,
        framesRejected: framesRejected,
      );
      _ref.read(pushNotificationServiceProvider).enqueue(
            PushNotification(
              title: 'Master ready',
              body: body,
              priority: PushNotificationPriority.normal,
              eventType: 'PostSessionMasterReady',
              category: EventCategory.imaging,
              timestamp: DateTime.now(),
            ),
          );
    } catch (_) {
      // Swallow — push is a courtesy, not part of the integration contract.
    }
  }

  /// Build the "master ready" push body, of the form
  /// `Your TARGET master is ready — Hh Mm, +x% from culling`.
  ///
  /// The "+x% from culling" is the predicted SNR uplift from dropping the
  /// rejected subs, approximated by the rejected-frame fraction (a conservative
  /// stand-in for the optimizer's gain until the marginal-SNR curve is wired
  /// through this path). It is omitted when nothing was culled.
  static String _masterReadyBody({
    required String? targetName,
    required double integrationSeconds,
    required int framesKept,
    required int framesRejected,
  }) {
    final who = (targetName != null && targetName.trim().isNotEmpty)
        ? '${targetName.trim()} '
        : '';
    final time = _formatIntegration(integrationSeconds);
    final total = framesKept + framesRejected;
    final buffer = StringBuffer('Your ${who}master is ready — $time');
    if (framesRejected > 0 && total > 0) {
      final pct = (framesRejected / total * 100).round();
      if (pct > 0) buffer.write(', +$pct% from culling');
    }
    return buffer.toString();
  }

  /// Format integration seconds as `Hh Mm` (e.g. `3h 12m`), or `Mm` when under
  /// an hour (e.g. `42m`), or `0m` when there is nothing to show.
  static String _formatIntegration(double seconds) {
    if (seconds <= 0) return '0m';
    final totalMinutes = (seconds / 60).round();
    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  Future<bool> _isEnabled() async {
    final raw = await _ref
        .read(settingsDaoProvider)
        .getSetting(kAutoIntegrateSettingKey);
    return raw == 'true';
  }

  Future<IntegrationSettings> _loadDefaultSettings() async {
    final raw = await _ref
        .read(settingsDaoProvider)
        .getSetting('post_session.default_settings');
    return IntegrationSettings.fromJsonStringOrDefault(raw);
  }

  Future<String> _outputDir() async {
    final configured =
        await _ref.read(settingsDaoProvider).getImageOutputDirectory();
    if (configured.trim().isNotEmpty) {
      return p.join(configured.trim(), 'masters');
    }
    return p.join('.', 'masters');
  }

  Future<Directory?> _markerDirectory() =>
      _ref.read(integrationMarkerDirectoryProvider.future);

  /// The bucket name [PostSessionIntegrationService] will file a sub under.
  ///
  /// Kept identical to that service's own rule (null and blank both collapse
  /// to the no-filter bucket, everything else trims) so the master paths
  /// predicted for the crash marker are the paths it actually writes.
  static String _filterBucketOf(String? filter) {
    final trimmed = (filter ?? '').trim();
    return trimmed.isEmpty
        ? PostSessionIntegrationService.noFilterBucket
        : trimmed;
  }

  /// The master FITS path for one filter bucket of one integration run.
  ///
  /// The single source of both the predicted paths written to the crash marker
  /// and the paths handed to the integrate service, so the two cannot drift
  /// apart and name a file that was never written.
  static String _masterPath({
    required String outDir,
    required String? targetName,
    required int stamp,
    required String filterBucket,
  }) {
    final base = _safeName(targetName ?? 'session');
    final tag = filterBucket == PostSessionIntegrationService.noFilterBucket
        ? ''
        : '_${_safeName(filterBucket)}';
    return p.join(outDir, '$base${tag}_master_$stamp.fits');
  }

  static String _safeName(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'[^A-Za-z0-9_\- ]'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '_');
    return cleaned.isEmpty ? 'session' : cleaned;
  }
}

/// Provider for the [AutoIntegrationService].
final autoIntegrationServiceProvider = Provider<AutoIntegrationService>(
  (ref) => AutoIntegrationService(ref),
);

class AutoIntegrationCompletion {
  const AutoIntegrationCompletion({
    required this.generation,
    required this.result,
  });

  final int generation;
  final AutoIntegrationResult result;
}

/// Latest user-visible completion from the background coordinator.
final autoIntegrationCompletionProvider =
    StateProvider<AutoIntegrationCompletion?>((ref) => null);

/// How long to wait for the end-of-night coordinator to classify a finished
/// run before falling back to the run's own status.
const _nightDecisionTimeout = Duration(seconds: 30);

/// Always-on host lifecycle for the night-end automation.
///
/// It deliberately activates only for [FfiBackend]. A remote UI mirrors the
/// host's terminal state and image catalog, but must never process its own
/// client-side database or paths. Nights are handled one at a time.
///
/// A night is handled when its run ended it: the run completed, or a dawn or
/// obstruction park ended it. It waits for the end-of-night calibration that
/// run started, so the masters are calibrated with tonight's darks, then
/// hands the night to the [NightEndRunner]: build every imaged target from all
/// its nights, deliver, and send the morning message, as the Darkroom's
/// Activity settings say. At launch the runner carries on a night a restart
/// cut short.
final autoIntegrationCoordinatorProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is! FfiBackend) return;

  // Created first so it sees every terminal run this coordinator sees.
  final night = ref.read(endOfNightCalibrationCoordinatorProvider);
  final runner = ref.read(nightEndRunnerProvider);
  unawaited(runner.start());
  final handle = _nightEndHandler(ref);
  var queue = Future<void>.value();
  ref.listen<SequenceTerminalRunResult?>(sequenceTerminalRunResultProvider,
      (previous, next) {
    if (next == null) return;
    if (previous?.generation == next.generation) return;
    final sessionId = next.dbSessionId;
    if (sessionId == null) return;
    final generation = next.generation;
    final endedAt = DateTime.now();
    var classified = true;
    final ended = night.runEnded(generation).timeout(
      _nightDecisionTimeout,
      onTimeout: () {
        classified = false;
        return next.runStatus == 'completed'
            ? EonEndReason.targetsComplete
            : null;
      },
    );

    queue = queue.then((_) async {
      final reason = await ended;
      if (reason == null) return;
      if (classified) await night.nightSettled(generation);
      final report = ref.read(endOfNightCalibrationProvider).report;
      await handle(
        sessionId: sessionId,
        generation: generation,
        reason: reason,
        calibration: report != null &&
                !report.startedAt
                    .isBefore(endedAt.subtract(const Duration(minutes: 5)))
            ? report
            : null,
      );
    });
  });

  // A night the operator stopped and then ended with a manual end-of-night
  // calibration is handled once that calibration is done.
  ref.listen<NightIntegrationRequest?>(nightIntegrationRequestProvider,
      (previous, next) {
    if (next == null || previous?.generation == next.generation) return;
    queue = queue.then(
      (_) => handle(
        sessionId: next.sessionId,
        generation: -next.generation,
        reason: EonEndReason.manual,
        calibration: ref.read(endOfNightCalibrationProvider).report,
      ),
    );
  });
});

/// What the coordinator does for one night: run the night-end automation and
/// publish a one-line result for the toast. [generation] keys the toast.
Future<void> Function({
  required int sessionId,
  required int generation,
  required EonEndReason reason,
  EonReport? calibration,
}) _nightEndHandler(Ref ref) => ({
      required sessionId,
      required generation,
      required reason,
      calibration,
    }) async {
      try {
        final run = await ref.read(nightEndRunnerProvider).nightEnded(
              sessionId: sessionId,
              reason: reason.description,
              calibration: calibration,
            );
        if (run == null) return;
        final result = describeNightEndRun(run);
        if (result == null) return;
        ref.read(autoIntegrationCompletionProvider.notifier).state =
            AutoIntegrationCompletion(generation: generation, result: result);
      } catch (error) {
        // Keep the serialization chain alive even if the run or the toast
        // publication fails; the run records its own outcome.
        ref.read(loggingServiceProvider).error(
          'Night-end automation failed',
          source: 'AutoIntegrationCoordinator',
          fields: {'sessionId': sessionId, 'error': '$error'},
        );
      }
    };

/// The toast for a finished night-end run, or null when it built nothing.
AutoIntegrationResult? describeNightEndRun(NightEndRun run) {
  final lines = <String>[];
  var built = 0;
  var failed = false;
  for (final target in run.targets) {
    switch (target.build.state) {
      case NightEndStepState.done:
        built++;
        final nights = target.nights;
        lines.add('${target.target}: masters ready'
            '${nights == null ? '' : ' from $nights night${nights == 1 ? '' : 's'}'}.');
      case NightEndStepState.waiting:
        lines.add('${target.target}: waits for you at the framing check.');
      case NightEndStepState.failed:
        failed = true;
        lines.add('${target.target}: the build failed. '
                '${target.build.detail ?? ''}'
            .trim());
      default:
        break;
    }
  }
  if (lines.isEmpty) return null;
  return AutoIntegrationResult(
    ran: built > 0,
    failed: failed,
    message: lines.join(' '),
  );
}
