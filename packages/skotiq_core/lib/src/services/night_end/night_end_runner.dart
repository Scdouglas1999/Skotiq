import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/darkroom_links.dart';
import '../../models/notification/notification_categories.dart';
import '../../providers/database_provider.dart';
import '../darkroom_autopilot/guided_build_delivery.dart';
import '../darkroom_build_jobs.dart';
import '../darkroom_build_service.dart';
import '../calibration_backlog_service.dart';
import '../darkroom_state_store.dart';
import '../end_of_night_calibration/eon_service.dart';
import '../logging_service.dart';
import '../notification_service.dart';
import 'night_end_run.dart';
import 'night_end_settings.dart';

/// Where the night-end runs are saved.
const String nightEndRunsStateKey = 'night_end_runs.v1';

/// How many night-end runs the history keeps.
const int nightEndRunsKept = 30;

/// The saved night-end runs, newest first.
class NightEndRuns extends Notifier<List<NightEndRun>> {
  @override
  List<NightEndRun> build() => const [];

  void _set(List<NightEndRun> runs) => state = List.unmodifiable(runs);
}

final nightEndRunsProvider = NotifierProvider<NightEndRuns, List<NightEndRun>>(
  NightEndRuns.new,
);

/// Runs the end of a night with the operator asleep: record the calibration
/// step, build every imaged target's masters from all its nights (a new
/// night folds into the target's existing build), deliver them, and send one
/// morning message, each step as its switch says. Every run is saved as it
/// goes, so the Activity tab shows it and a run cut short by a restart
/// carries on at the next launch.
class NightEndRunner {
  NightEndRunner(this._ref);

  final Ref _ref;
  Future<void>? _restored;
  Future<void> _saving = Future<void>.value();
  Future<void> _queue = Future<void>.value();
  StreamSubscription<DarkroomBuildJob>? _finished;

  DarkroomBuildJobs get _jobs => _ref.read(darkroomBuildJobsProvider.notifier);

  List<NightEndRun> get _runs => _ref.read(nightEndRunsProvider);

  /// Read the saved runs and the saved builds back, follow builds that end,
  /// and carry on any run a restart cut short.
  Future<void> start() => _restored ??= _start();

  Future<void> _start() async {
    await _jobs.restore();
    try {
      final saved = await _ref
          .read(darkroomStateStoreProvider)
          .read(nightEndRunsStateKey);
      final runs = <NightEndRun>[
        for (final r in saved?['runs'] as List? ?? const [])
          if (r is Map) NightEndRun.fromJson(Map<String, dynamic>.from(r)),
      ];
      if (_runs.isEmpty) _ref.read(nightEndRunsProvider.notifier)._set(runs);
    } catch (e) {
      _log.warning(
        'The saved night-end runs could not be read: $e',
        source: 'NightEnd',
      );
    }
    _finished ??= _jobs.finished.listen(_onBuildFinished);
    _ref.onDispose(() => _finished?.cancel());
    for (final run in _runs.where((r) => !r.finished).toList()) {
      _enqueue(() => _carryOn(run.id));
    }
  }

  LoggingService get _log => _ref.read(loggingServiceProvider);

  /// Wait for the work queued so far.
  Future<void> idle() async {
    await _queue;
    await _saving;
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } catch (e, stack) {
        _log.error(
          'Night-end work failed: $e',
          source: 'NightEnd',
          fields: {'stack': '$stack'},
        );
      }
    });
  }

  NightEndRun? _run(String id) => _runs.where((r) => r.id == id).firstOrNull;

  void _put(NightEndRun run) {
    final runs = [
      run,
      for (final r in _runs)
        if (r.id != run.id) r,
    ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    _ref
        .read(nightEndRunsProvider.notifier)
        ._set(runs.take(nightEndRunsKept).toList());
    final snapshot = {
      'runs': [for (final r in _ref.read(nightEndRunsProvider)) r.toJson()],
    };
    final store = _ref.read(darkroomStateStoreProvider);
    _saving = _saving.then((_) async {
      try {
        await store.write(nightEndRunsStateKey, snapshot);
      } catch (e) {
        _log.warning('Night-end runs not saved: $e', source: 'NightEnd');
      }
    });
  }

  /// The night of [sessionId] ended for [reason]. [calibration] is what the
  /// end-of-night calibration step did, when it ran. Returns the run, or
  /// null when the night took no light frames.
  Future<NightEndRun?> nightEnded({
    required int sessionId,
    required String reason,
    EonReport? calibration,
  }) async {
    await start();
    final settings = await NightEndAutomationSettings.load(
      _ref.read(settingsDaoProvider),
    );
    final images = await _ref
        .read(imagesDaoProvider)
        .getImagesForSession(sessionId);
    final lightIds = {
      for (final image in images)
        if (image.frameType.toLowerCase() == 'light' && image.isAccepted)
          image.id,
    };
    if (lightIds.isEmpty) return null;
    final targets = await loadDarkroomTargets(_ref.read(databaseProvider));
    final names = [
      for (final entry in targets.entries)
        if (entry.value.any((frame) => lightIds.contains(frame.id))) entry.key,
    ]..sort();
    const buildOff = NightEndStep(
      NightEndStepState.skipped,
      'Building masters is switched off.',
    );
    final run = NightEndRun(
      id: 'night-$sessionId-${DateTime.now().microsecondsSinceEpoch}',
      sessionId: sessionId,
      startedAt: DateTime.now(),
      reason: reason,
      calibrate: _calibrationStep(settings, calibration),
      targets: [
        for (final name in names)
          NightEndTarget(
            target: name,
            build: settings.build ? NightEndStep.pending : buildOff,
            deliver: settings.build
                ? NightEndStep.pending
                : const NightEndStep(
                    NightEndStepState.skipped,
                    'Nothing was built to deliver.',
                  ),
          ),
      ],
    );
    _put(run);
    final done = Completer<void>();
    _enqueue(() async {
      try {
        await _carryOn(run.id);
      } finally {
        done.complete();
      }
    });
    await done.future;
    return _run(run.id);
  }

  static NightEndStep _calibrationStep(
    NightEndAutomationSettings settings,
    EonReport? report,
  ) {
    if (!settings.calibrate) {
      return const NightEndStep(
        NightEndStepState.skipped,
        'Taking darks and bias is switched off.',
      );
    }
    if (report == null) {
      return const NightEndStep(
        NightEndStepState.skipped,
        'No darks or bias were taken for this night.',
      );
    }
    final summary = report.summary.isEmpty ? null : report.summary;
    return switch (report.phase) {
      EonPhase.finished =>
        report.problems.isEmpty
            ? NightEndStep(NightEndStepState.done, summary)
            : NightEndStep(
                NightEndStepState.failed,
                [summary, ...report.problems].whereType<String>().join(' '),
              ),
      EonPhase.skipped => NightEndStep(NightEndStepState.skipped, summary),
      EonPhase.cancelled => NightEndStep(
        NightEndStepState.skipped,
        summary ?? 'Stopped.',
      ),
      _ => NightEndStep(
        NightEndStepState.failed,
        [summary, ...report.problems].whereType<String>().join(' '),
      ),
    };
  }

  /// Retry only calibration holds; completed targets and imaging stay alone.
  Future<void> retryCalibration(String id) async {
    await start();
    _enqueue(() async {
      final run = _run(id);
      if (run == null || !run.finished) return;
      _put(
        run.copyWith(
          clearFinishedAt: true,
          targets: [
            for (final target in run.targets)
              if (target.waitingForCalibration &&
                  target.build.state == NightEndStepState.waiting)
                target.copyWith(
                  build: NightEndStep.pending,
                  waitingForCalibration: false,
                )
              else
                target,
          ],
        ),
      );
      await _carryOn(id);
    });
    await idle();
  }

  /// Do whatever [id] still owes: builds, deliveries, the morning message.
  Future<void> _carryOn(String id) async {
    final settings = await NightEndAutomationSettings.load(
      _ref.read(settingsDaoProvider),
    );
    var run = _run(id);
    if (run == null || run.finished) return;
    final jobs = <String, DarkroomBuildJob>{};
    final framesByTarget = await loadDarkroomTargets(
      _ref.read(databaseProvider),
    );
    for (final target in run.targets) {
      final state = target.build.state;
      if (state != NightEndStepState.pending &&
          state != NightEndStepState.running) {
        continue;
      }
      await _jobs.whenIdle();
      _supersedeHeld(target.target, id);
      run = _run(id)!.withTarget(
        target.target,
        (t) => t.copyWith(build: const NightEndStep(NightEndStepState.running)),
      );
      _put(run);
      Map<String, String> selectedFlats;
      // Bias/dark capture has completed before this runner is invoked. Build
      // the operator's selected flats now, before the library is matched.
      try {
        final frames = framesByTarget[target.target] ?? [];
        selectedFlats = await _ref
            .read(calibrationBacklogProvider.notifier)
            .prepareForLights(frames);
        if (!settings.allowIncompleteCalibration) {
          await _ref
              .read(darkroomBuildServiceProvider)
              .requireCompleteCalibration(frames, selectedFlats: selectedFlats);
        }
      } catch (e) {
        _put(
          _run(id)!.withTarget(
            target.target,
            (t) => t.copyWith(
              build: NightEndStep(
                NightEndStepState.waiting,
                'Calibration needed: $e',
              ),
              waitingForCalibration: true,
            ),
          ),
        );
        continue;
      }
      NightEndTarget updated;
      try {
        final job = await _jobs.startUnattended(
          target.target,
          announce: false,
          nightRunId: id,
          minRetainedArea: settings.minRetainedArea,
          requireCalibration: !settings.allowIncompleteCalibration,
          selectedFlats: selectedFlats,
        );
        jobs[target.target] = job;
        updated = _afterBuild(target, job, settings);
      } catch (e) {
        updated = target.copyWith(
          build: NightEndStep(
            NightEndStepState.failed,
            'The build did not start: $e',
          ),
          deliver: const NightEndStep(NightEndStepState.skipped),
        );
      }
      run = _run(id)!.withTarget(target.target, (_) => updated);
      _put(run);
    }

    for (final target in _run(id)!.targets) {
      if (target.deliver.state != NightEndStepState.pending) continue;
      var job = jobs[target.target];
      if (job == null && target.build.state == NightEndStepState.done) {
        // Built before a restart and not yet delivered: the build folder
        // still holds every filter and the export, so this only reads them.
        await _jobs.whenIdle();
        try {
          final selectedFlats = await _ref
              .read(calibrationBacklogProvider.notifier)
              .prepareForLights(framesByTarget[target.target] ?? []);
          job = await _jobs.startUnattended(
            target.target,
            announce: false,
            nightRunId: id,
            minRetainedArea: settings.minRetainedArea,
            requireCalibration: !settings.allowIncompleteCalibration,
            selectedFlats: selectedFlats,
          );
        } catch (e) {
          _log.warning(
            '${target.target}: the finished build could not be read back '
            'for delivery: $e',
            source: 'NightEnd',
          );
        }
      }
      if (job == null || job.stage != DarkroomJobStage.done) continue;
      final step = await _deliver(job, settings);
      _put(
        _run(id)!.withTarget(target.target, (t) => t.copyWith(deliver: step)),
      );
    }

    run = _run(id)!;
    final message = await _morningMessage(run, jobs, settings);
    _put(run.copyWith(message: message, finishedAt: DateTime.now()));
  }

  /// An earlier night whose build of [target] still waits at the framing
  /// check is replaced by this night's build, which folds every night in.
  void _supersedeHeld(String target, String id) {
    for (final other in _runs) {
      if (other.id == id) continue;
      final held = other.targets.where(
        (t) => t.target == target && t.build.state == NightEndStepState.waiting,
      );
      if (held.isEmpty) continue;
      _put(
        other.withTarget(
          target,
          (t) => t.copyWith(
            build: const NightEndStep(
              NightEndStepState.skipped,
              'Folded into a later night\'s build.',
            ),
            waitingForCalibration: false,
            deliver: const NightEndStep(NightEndStepState.skipped),
          ),
        ),
      );
    }
  }

  NightEndTarget _afterBuild(
    NightEndTarget target,
    DarkroomBuildJob job,
    NightEndAutomationSettings settings,
  ) {
    final nights = _nights(job);
    switch (job.stage) {
      case DarkroomJobStage.done:
        return target.copyWith(
          build: NightEndStep(
            NightEndStepState.done,
            summarizeGuidedBuild(job),
          ),
          deliver: settings.deliver
              ? NightEndStep.pending
              : const NightEndStep(
                  NightEndStepState.skipped,
                  'Delivery is switched off.',
                ),
          nights: nights,
          directory: job.directory,
        );
      case DarkroomJobStage.awaitingReview:
        return target.copyWith(
          build: NightEndStep(
            NightEndStepState.waiting,
            [
              if (job.preview case final preview?) preview.describeLimit(),
              'It waits for you at the framing check.',
            ].join(' '),
          ),
          deliver: const NightEndStep(
            NightEndStepState.pending,
            'After the framing check.',
          ),
          nights: nights,
          directory: job.directory,
        );
      default:
        return target.copyWith(
          build: NightEndStep(
            NightEndStepState.failed,
            job.error ?? job.message,
          ),
          deliver: const NightEndStep(NightEndStepState.skipped),
          nights: nights,
          directory: job.directory,
        );
    }
  }

  static int? _nights(DarkroomBuildJob job) {
    final plan = job.plan?.toJson();
    if (plan == null) return null;
    return {
      for (final g in plan['groups'] as List)
        ((g as Map)['label'] as String).split(' · ').first,
    }.length;
  }

  Future<NightEndStep> _deliver(
    DarkroomBuildJob job,
    NightEndAutomationSettings settings,
  ) async {
    if (!settings.deliver) {
      return const NightEndStep(
        NightEndStepState.skipped,
        'Delivery is switched off.',
      );
    }
    try {
      final outcome = await _ref
          .read(guidedBuildDeliveryProvider)
          .deliver(job, announce: false);
      final delivered = outcome.delivery;
      final line = delivered == null || delivered.destinations.isEmpty
          ? 'No delivery destination is set up; the files are in '
                '${job.directory}.'
          : 'Delivered ${delivered.delivered} file'
                '${delivered.delivered == 1 ? '' : 's'} to '
                '${delivered.destinations.length} destination'
                '${delivered.destinations.length == 1 ? '' : 's'}.';
      return NightEndStep(
        outcome.problems.isEmpty
            ? NightEndStepState.done
            : NightEndStepState.failed,
        [line, ...outcome.problems].join(' '),
      );
    } catch (e) {
      return NightEndStep(NightEndStepState.failed, 'Delivery failed: $e');
    }
  }

  Future<NightEndStep> _morningMessage(
    NightEndRun run,
    Map<String, DarkroomBuildJob> jobs,
    NightEndAutomationSettings settings,
  ) async {
    if (!settings.morningMessage) {
      return const NightEndStep(
        NightEndStepState.skipped,
        'The morning message is switched off.',
      );
    }
    final built = run.targets
        .where((t) => t.build.state == NightEndStepState.done)
        .toList();
    final waiting = run.targets
        .where((t) => t.build.state == NightEndStepState.waiting)
        .toList();
    final failed = run.targets
        .where((t) => t.build.state == NightEndStepState.failed)
        .toList();
    if (built.isEmpty &&
        waiting.isEmpty &&
        failed.isEmpty &&
        run.calibrate.state != NightEndStepState.failed) {
      return const NightEndStep(
        NightEndStepState.skipped,
        'Nothing was built, so no message was sent.',
      );
    }
    final String title;
    if (built.length == 1 && waiting.isEmpty && failed.isEmpty) {
      title = 'Masters ready: ${built.single.target}';
    } else if (built.isEmpty && waiting.length == 1 && failed.isEmpty) {
      title = waiting.single.waitingForCalibration
          ? 'Masters wait for calibration: ${waiting.single.target}'
          : 'Masters wait for the framing check: ${waiting.single.target}';
    } else {
      title =
          [
                if (built.isNotEmpty)
                  '${built.length} target${built.length == 1 ? '' : 's'} built',
                if (waiting.isNotEmpty) '${waiting.length} waiting for you',
                if (failed.isNotEmpty) '${failed.length} failed',
                if (built.isEmpty && waiting.isEmpty && failed.isEmpty)
                  'calibration had problems',
              ]
              .join(', ')
              .replaceFirstMapped(RegExp('^.'), (m) => 'Night end: ${m[0]}');
    }
    final lines = [
      for (final t in run.targets)
        switch (t.build.state) {
          NightEndStepState.done =>
            '${t.target}: ${t.build.detail ?? 'masters ready.'}'
                '${t.deliver.detail == null ? '' : ' ${t.deliver.detail}'}',
          NightEndStepState.waiting => '${t.target}: ${t.build.detail}',
          NightEndStepState.failed => [
            '${t.target}: the build failed.',
            if (t.build.detail case final detail?) detail,
          ].join(' '),
          _ => null,
        },
      if (run.calibrate.state == NightEndStepState.failed)
        'Calibration: ${run.calibrate.detail ?? 'it had problems.'}',
    ].whereType<String>();
    final String deepLink;
    if (waiting.isNotEmpty) {
      deepLink = waiting.first.waitingForCalibration
          ? kDarkroomActivityPayloadType
          : darkroomFramingPayload(waiting.first.target);
    } else if (built.length + failed.length == 1) {
      deepLink = darkroomTargetPayload([...built, ...failed].single.target);
    } else {
      deepLink = kDarkroomActivityPayloadType;
    }
    try {
      final dispatch = await _ref
          .read(notificationServiceProvider)
          .notifyDetailed(
            event: NotificationEvent.sequenceComplete,
            title: title,
            message: lines.join(' '),
            routeAs: NotificationCategory.darkroomDraftReady,
            deepLink: deepLink,
          );
      return dispatch.anyDelivered
          ? NightEndStep(NightEndStepState.done, title)
          : NightEndStep(
              NightEndStepState.failed,
              'Not sent: ${dispatch.describe()}',
            );
    } catch (e) {
      return NightEndStep(NightEndStepState.failed, 'Not sent: $e');
    }
  }

  /// A build a night-end run held at the framing check was accepted and has
  /// ended: deliver it and say so, as the run would have.
  void _onBuildFinished(DarkroomBuildJob job) {
    final id = job.nightRunId;
    if (id == null) return;
    final run = _run(id);
    final target = run?.targets
        .where((t) => t.target == job.target)
        .firstOrNull;
    if (run == null ||
        target == null ||
        target.build.state != NightEndStepState.waiting ||
        target.waitingForCalibration) {
      return;
    }
    _enqueue(() async {
      final settings = await NightEndAutomationSettings.load(
        _ref.read(settingsDaoProvider),
      );
      var updated = _afterBuild(target, job, settings);
      if (job.stage == DarkroomJobStage.done && settings.deliver) {
        updated = updated.copyWith(deliver: await _deliver(job, settings));
      }
      _put(_run(id)!.withTarget(job.target, (_) => updated));
      if (!settings.morningMessage) return;
      final done = job.stage == DarkroomJobStage.done;
      try {
        await _ref
            .read(notificationServiceProvider)
            .notifyDetailed(
              event: NotificationEvent.sequenceComplete,
              title: done
                  ? 'Masters ready: ${job.target}'
                  : 'Master build ${job.stage == DarkroomJobStage.stopped ? 'stopped' : 'failed'}: ${job.target}',
              message: [
                updated.build.detail,
                updated.deliver.detail,
              ].whereType<String>().join(' '),
              routeAs: NotificationCategory.darkroomDraftReady,
              deepLink: darkroomTargetPayload(job.target),
            );
      } catch (e) {
        _log.warning('Build message not sent: $e', source: 'NightEnd');
      }
    });
  }
}

final nightEndRunnerProvider = Provider<NightEndRunner>(NightEndRunner.new);
