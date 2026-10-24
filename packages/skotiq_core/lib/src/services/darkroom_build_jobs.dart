import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';
import '../models/notification/notification_categories.dart';
import '../providers/database_provider.dart';
import '../utils/skotiq_data_directory.dart';
import 'calibration/fits_header_reader.dart';
import 'darkroom_build_service.dart';
import 'notification_service.dart';
import 'post_session_seam.dart';

/// Where a master build is.
enum DarkroomJobStage {
  /// Registering every light from its stars to find the common crop.
  framing,

  /// The pre-pass is done and the build waits for the crop to be accepted.
  awaitingReview,
  building,
  exporting,
  done,
  failed,
  stopped,
}

/// A master build running in the background, independent of any screen.
class DarkroomBuildJob {
  const DarkroomBuildJob({
    required this.target,
    required this.stage,
    required this.message,
    required this.startedAt,
    this.unattended = false,
    this.plan,
    this.preview,
    this.directory,
    this.filter,
    this.filterIndex = 0,
    this.filterCount = 0,
    this.framesDone = 0,
    this.framesTotal = 0,
    this.overallDone = 0,
    this.overallTotal = 0,
    this.eta,
    this.currentImageId,
    this.filterResults = const [],
    this.report,
    this.error,
    this.warnings = const [],
  });

  final String target;
  final DarkroomJobStage stage;
  final String message;
  final DateTime startedAt;
  final bool unattended;
  final DarkroomBuildPlan? plan;
  final DarkroomRegistrationPreview? preview;
  final String? directory;

  /// Filter being built.
  final String? filter;
  final int filterIndex;
  final int filterCount;

  /// Lights done and offered in the current step (pre-pass or filter).
  final int framesDone;
  final int framesTotal;

  /// Lights done and offered over the whole build.
  final int overallDone;
  final int overallTotal;
  final Duration? eta;

  /// The light being processed, for a thumbnail.
  final int? currentImageId;

  /// Finished filters: native results, or `{filter, error}`.
  final List<Map<String, dynamic>> filterResults;
  final Map<String, dynamic>? report;
  final String? error;
  final List<String> warnings;

  bool get active =>
      stage == DarkroomJobStage.framing ||
      stage == DarkroomJobStage.building ||
      stage == DarkroomJobStage.exporting;

  DarkroomBuildJob copyWith({
    DarkroomJobStage? stage,
    String? message,
    DarkroomBuildPlan? plan,
    DarkroomRegistrationPreview? preview,
    String? directory,
    String? filter,
    int? filterIndex,
    int? filterCount,
    int? framesDone,
    int? framesTotal,
    int? overallDone,
    int? overallTotal,
    Duration? eta,
    bool clearEta = false,
    int? currentImageId,
    List<Map<String, dynamic>>? filterResults,
    Map<String, dynamic>? report,
    String? error,
    bool clearError = false,
    List<String>? warnings,
  }) => DarkroomBuildJob(
    target: target,
    unattended: unattended,
    startedAt: startedAt,
    stage: stage ?? this.stage,
    message: message ?? this.message,
    plan: plan ?? this.plan,
    preview: preview ?? this.preview,
    directory: directory ?? this.directory,
    filter: filter ?? this.filter,
    filterIndex: filterIndex ?? this.filterIndex,
    filterCount: filterCount ?? this.filterCount,
    framesDone: framesDone ?? this.framesDone,
    framesTotal: framesTotal ?? this.framesTotal,
    overallDone: overallDone ?? this.overallDone,
    overallTotal: overallTotal ?? this.overallTotal,
    eta: clearEta ? null : (eta ?? this.eta),
    currentImageId: currentImageId ?? this.currentImageId,
    filterResults: filterResults ?? this.filterResults,
    report: report ?? this.report,
    error: clearError ? null : (error ?? this.error),
    warnings: warnings ?? this.warnings,
  );
}

/// Every captured light, by target: the target's name, else the FITS
/// `OBJECT`, else its session.
Future<Map<String, List<CapturedImage>>> loadDarkroomTargets(
  SkotiqDatabase db, {
  DarkroomHeaderReader? readHeader,
}) async {
  final read =
      readHeader ??
      ((path) => const FitsHeaderReader().readPrimaryHeader(path));
  final images = await db.imagesDao.getAllImages();
  final names = {
    for (final t in await db.targetsDao.getAllTargets()) t.id: t.name,
  };
  final targets = <String, List<CapturedImage>>{};
  for (final f in images.where((f) => f.frameType.toLowerCase() == 'light')) {
    var name = names[f.targetId];
    if (name == null) {
      try {
        name = FitsHeaderReader.stringValue(await read(f.filePath), 'OBJECT');
      } catch (_) {
        // Unreadable files stay listed under their session.
      }
    }
    name ??= 'Session ${f.sessionId ?? 'unassigned'}';
    targets.putIfAbsent(name, () => []).add(f);
  }
  return targets;
}

/// The one master build of this process. It lives above every screen, so a
/// build keeps running while the user goes elsewhere, and its progress and
/// outcome are here to come back to.
class DarkroomBuildJobs extends Notifier<DarkroomBuildJob?> {
  StreamSubscription<({String phase, double fraction})>? _progress;
  DateTime? _rateStart;
  int _rateBase = 0;
  List<int> _currentIds = const [];
  int _finishedLights = 0;

  @override
  DarkroomBuildJob? build() {
    ref.onDispose(() => _progress?.cancel());
    return null;
  }

  DarkroomBuildService get _service => ref.read(darkroomBuildServiceProvider);

  void _set(DarkroomBuildJob job) => state = job;

  void _listen() {
    _progress?.cancel();
    _progress = ref
        .read(postSessionSeamProvider)
        .integrationProgress()
        .listen(_onProgress);
  }

  void _onProgress(({String phase, double fraction}) event) {
    final job = state;
    if (job == null || !job.active) return;
    if (event.phase == 'framing' && job.stage == DarkroomJobStage.framing) {
      final done = (event.fraction * job.framesTotal).round();
      _set(
        job.copyWith(
          framesDone: done,
          overallDone: done,
          eta: _eta(done, job.framesTotal),
        ),
      );
    } else if (event.phase == 'registering' &&
        job.stage == DarkroomJobStage.building) {
      final done = (event.fraction * job.framesTotal).round();
      final overall = _finishedLights + done;
      _set(
        job.copyWith(
          framesDone: done,
          overallDone: overall,
          eta: _eta(overall, job.overallTotal),
          currentImageId: done < _currentIds.length ? _currentIds[done] : null,
        ),
      );
    }
  }

  Duration? _eta(int done, int total) {
    final start = _rateStart;
    final processed = done - _rateBase;
    if (start == null || processed < 2 || total <= done) return null;
    final elapsed = DateTime.now().difference(start);
    return elapsed * ((total - done) / processed);
  }

  void _startRate(int base) {
    _rateStart = DateTime.now();
    _rateBase = base;
  }

  /// Run the registration pre-pass for [plan]. The job then waits for the
  /// crop to be accepted.
  Future<void> checkFraming({
    required String target,
    required DarkroomBuildPlan plan,
  }) async {
    _guardIdle();
    _set(
      DarkroomBuildJob(
        target: target,
        stage: DarkroomJobStage.framing,
        message: 'Registering every light to find the common crop',
        startedAt: DateTime.now(),
        plan: plan,
        framesTotal: plan.lights.length,
        overallTotal: plan.lights.length,
      ),
    );
    _startRate(0);
    _listen();
    try {
      final preview = await _service.previewRegistration(plan);
      _set(
        state!.copyWith(
          stage: DarkroomJobStage.awaitingReview,
          message: preview.describeLimit(),
          preview: preview,
          framesDone: plan.lights.length,
          clearEta: true,
        ),
      );
    } catch (e) {
      _fail(e);
    } finally {
      await _progress?.cancel();
    }
  }

  /// Leave lights out and re-evaluate the crop from the known footprints.
  Future<void> exclude(Map<String, String> reasons) async {
    final job = state;
    if (job?.plan == null || job!.stage != DarkroomJobStage.awaitingReview) {
      return;
    }
    try {
      final plan = job.plan!.withoutLights(reasons);
      final preview = await _service.previewRegistration(
        plan,
        previous: job.preview,
      );
      _set(
        job.copyWith(
          plan: plan,
          preview: preview,
          message: preview.describeLimit(),
          clearError: true,
        ),
      );
    } catch (e) {
      _set(job.copyWith(error: '$e'));
    }
  }

  /// Change the smallest acceptable crop.
  Future<void> setMinRetainedArea(double value) async {
    final job = state;
    if (job?.plan == null || job!.stage != DarkroomJobStage.awaitingReview) {
      return;
    }
    try {
      final plan = job.plan!.withMinRetainedArea(value);
      final preview = await _service.previewRegistration(
        plan,
        previous: job.preview,
      );
      _set(
        job.copyWith(
          plan: plan,
          preview: preview,
          message: preview.describeLimit(),
        ),
      );
    } catch (e) {
      _set(job.copyWith(error: '$e'));
    }
  }

  /// Accept the crop and build into [directory].
  Future<void> accept(Directory directory) async {
    final job = state;
    if (job?.plan == null || job!.preview == null) {
      throw StateError('Check framing before building.');
    }
    if (!job.preview!.meetsMinimum) {
      throw StateError(job.preview!.describeLimit());
    }
    await _build(
      job.copyWith(directory: directory.path),
      job.plan!,
      job.preview,
    );
  }

  /// Resume the build saved in [folder].
  Future<void> resume(Directory folder) async {
    _guardIdle();
    final saved =
        jsonDecode(await File(p.join(folder.path, 'plan.json')).readAsString())
            as Map;
    final plan = DarkroomBuildPlan.fromJson(
      Map<String, dynamic>.from(saved['plan'] as Map),
    );
    await _build(
      DarkroomBuildJob(
        target: plan.target,
        stage: DarkroomJobStage.building,
        message: 'Resuming',
        startedAt: DateTime.now(),
        plan: plan,
        directory: folder.path,
      ),
      plan,
      null,
    );
  }

  Future<void> _build(
    DarkroomBuildJob job,
    DarkroomBuildPlan plan,
    DarkroomRegistrationPreview? accepted,
  ) async {
    final byFilter = <String, List<int>>{};
    for (final g in plan.toJson()['groups'] as List) {
      for (final l in (g as Map)['lights'] as List) {
        byFilter
            .putIfAbsent(g['filter'] as String, () => [])
            .add(l['id'] as int);
      }
    }
    final total = byFilter.values.fold<int>(0, (n, v) => n + v.length);
    _finishedLights = 0;
    _rateStart = null;
    _set(
      job.copyWith(
        stage: DarkroomJobStage.building,
        message: 'Starting the build',
        overallTotal: total,
        overallDone: 0,
        framesDone: 0,
        clearEta: true,
        clearError: true,
      ),
    );
    _listen();
    try {
      final report = await _service.run(
        plan,
        Directory(state!.directory!),
        accepted: accepted,
        onStep: (step) => _onStep(step, byFilter),
      );
      final failures = (report['failures'] as List? ?? const []);
      final done = state!.copyWith(
        stage: DarkroomJobStage.done,
        message: failures.isEmpty
            ? 'Masters ready'
            : 'Masters ready; ${failures.length} filter(s) failed',
        report: report,
        overallDone: total,
        clearEta: true,
      );
      _set(done);
      await _notify('Masters ready: ${done.target}', _summary(report));
    } catch (e) {
      if ('$e'.contains('Stopped')) {
        _set(
          state!.copyWith(
            stage: DarkroomJobStage.stopped,
            message: '$e',
            clearEta: true,
          ),
        );
      } else {
        _fail(e);
      }
    } finally {
      await _progress?.cancel();
    }
  }

  void _onStep(DarkroomBuildStep step, Map<String, List<int>> byFilter) {
    final job = state;
    if (job == null) return;
    _finishedLights = 0;
    for (final r in step.filterResults) {
      _finishedLights += byFilter[r['filter']]?.length ?? 0;
    }
    if (step.stage == 'building') {
      _currentIds = byFilter[step.filter] ?? const [];
      if (_rateStart == null) _startRate(_finishedLights);
    }
    _set(
      job.copyWith(
        stage: step.stage == 'exporting'
            ? DarkroomJobStage.exporting
            : DarkroomJobStage.building,
        message: step.message,
        filter: step.filter,
        filterIndex: step.filterIndex,
        filterCount: step.filterCount,
        framesDone: 0,
        framesTotal: step.filterLights,
        overallDone: _finishedLights,
        filterResults: step.filterResults,
      ),
    );
  }

  /// Build every filter of [target] from all its nights, with default choices
  /// and no dialog. The build starts only when the common crop keeps at least
  /// [minRetainedArea] of the field; otherwise the job waits for review and a
  /// notification names the frames that limit the crop. Returns when the job
  /// ends or waits.
  Future<DarkroomBuildJob> startUnattended(
    String target, {
    Directory? outputRoot,
    double minRetainedArea = defaultMinRetainedArea,
  }) async {
    _guardIdle();
    final frames = (await loadDarkroomTargets(
      ref.read(databaseProvider),
    ))[target];
    if (frames == null || frames.isEmpty) {
      throw StateError('No captured lights for $target.');
    }
    final root =
        outputRoot ??
        Directory(
          p.join(
            (await resolveSkotiqDocumentsDirectory()).path,
            'Skotiq',
            'Masters',
          ),
        );
    final stamp = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final directory = Directory(
      p.join(
        root.path,
        '${target.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}-$stamp',
      ),
    );
    _set(
      DarkroomBuildJob(
        target: target,
        unattended: true,
        stage: DarkroomJobStage.framing,
        message: 'Preparing calibration and registering every light',
        startedAt: DateTime.now(),
        directory: directory.path,
        framesTotal: frames.length,
        overallTotal: frames.length,
      ),
    );
    _startRate(0);
    _listen();
    final byFilter = <String, List<int>>{};
    try {
      final outcome = await _service.buildUnattended(
        target: target,
        frames: frames,
        directory: directory,
        minRetainedArea: minRetainedArea,
        onPreview: (preview, plan) {
          for (final g in plan.toJson()['groups'] as List) {
            for (final l in (g as Map)['lights'] as List) {
              byFilter
                  .putIfAbsent(g['filter'] as String, () => [])
                  .add(l['id'] as int);
            }
          }
          _finishedLights = 0;
          _rateStart = null;
          _set(
            state!.copyWith(
              stage: DarkroomJobStage.building,
              preview: preview,
              message: preview.describeLimit(),
              overallTotal: preview.included.length,
              overallDone: 0,
              clearEta: true,
            ),
          );
        },
        onStep: (step) => _onStep(step, byFilter),
      );
      if (!outcome.built) {
        _set(
          state!.copyWith(
            stage: DarkroomJobStage.awaitingReview,
            plan: outcome.plan,
            preview: outcome.preview,
            message: outcome.preview.describeLimit(),
            warnings: outcome.warnings,
            clearEta: true,
          ),
        );
        await _notify(
          'Masters need framing review: $target',
          '${outcome.preview.describeLimit()} Open Darkroom to exclude frames or accept a smaller crop.',
        );
      } else {
        _set(
          state!.copyWith(
            stage: DarkroomJobStage.done,
            plan: outcome.plan,
            report: outcome.report,
            message: 'Masters ready',
            warnings: outcome.warnings,
            clearEta: true,
          ),
        );
        await _notify(
          'Masters ready: $target',
          [_summary(outcome.report!), ...outcome.warnings].join(' '),
        );
      }
    } catch (e) {
      _fail(e);
    } finally {
      await _progress?.cancel();
    }
    return state!;
  }

  Future<void> stop() => _service.stop();

  /// Forget a finished, failed, stopped or unaccepted job.
  void dismiss() {
    if (state?.active == true) return;
    state = null;
  }

  void _guardIdle() {
    if (state?.active == true || _service.isRunning) {
      throw StateError('A master build is already running.');
    }
  }

  void _fail(Object e) {
    final job = state;
    if (job == null) return;
    _set(
      job.copyWith(
        stage: DarkroomJobStage.failed,
        error: '$e',
        message: 'Build failed',
        clearEta: true,
      ),
    );
    unawaited(_notify('Master build failed: ${job.target}', '$e'));
  }

  static String _summary(Map<String, dynamic> report) {
    final results = (report['results'] as List).cast<Map>();
    final failures = (report['failures'] as List? ?? const []).cast<Map>();
    final delivery = report['delivery'] as Map;
    final built = results
        .map(
          (r) =>
              '${r['filter']} ${r['frameCount']} frames, ${((r['totalIntegrationSec'] as num) / 3600).toStringAsFixed(1)} h',
        )
        .join('; ');
    final failed = failures.isEmpty
        ? ''
        : ' Not built: ${failures.map((f) => f['filter']).join(', ')}.';
    return '$built. ${((delivery['retainedArea'] as num) * 100).toStringAsFixed(1)}% of the field kept.$failed';
  }

  Future<void> _notify(String title, String message) async {
    try {
      await ref
          .read(notificationServiceProvider)
          .notify(
            event: NotificationEvent.sequenceComplete,
            title: title,
            message: message,
            routeAs: NotificationCategory.darkroomDraftReady,
          );
    } catch (_) {
      // The job's own state still shows the outcome.
    }
  }
}

final darkroomBuildJobsProvider =
    NotifierProvider<DarkroomBuildJobs, DarkroomBuildJob?>(
      DarkroomBuildJobs.new,
    );
