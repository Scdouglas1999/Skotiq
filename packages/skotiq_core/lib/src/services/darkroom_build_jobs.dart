import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../database/database.dart';
import '../models/darkroom/darkroom_links.dart';
import '../models/notification/notification_categories.dart';
import '../providers/database_provider.dart';
import '../utils/skotiq_data_directory.dart';
import 'calibration/fits_header_reader.dart';
import 'darkroom_build_service.dart';
import 'darkroom_state_store.dart';
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
    this.nightRunId,
    this.finishedAt,
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

  /// The night-end run that started this build, when it was one. A build of
  /// that run that waits for the framing check is delivered and announced by
  /// the run once it is accepted and finishes.
  final String? nightRunId;

  /// When the build ended: done, failed or stopped.
  final DateTime? finishedAt;
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
    DateTime? finishedAt,
  }) => DarkroomBuildJob(
    target: target,
    unattended: unattended,
    nightRunId: nightRunId,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
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

  /// Whether the build ended, one way or another.
  bool get ended =>
      stage == DarkroomJobStage.done ||
      stage == DarkroomJobStage.failed ||
      stage == DarkroomJobStage.stopped;

  /// The job as it is saved across restarts. The report keeps what the
  /// summaries and delivery read; its per-frame lists stay in the build
  /// folder's `report.json`.
  Map<String, dynamic> toJson() => {
    'target': target,
    'stage': stage.name,
    'message': message,
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toUtc().toIso8601String(),
    'unattended': unattended,
    if (nightRunId != null) 'nightRunId': nightRunId,
    if (plan != null) 'plan': plan!.toJson(),
    if (preview != null) 'preview': preview!.toJson(),
    if (directory != null) 'directory': directory,
    'filterResults': [for (final r in filterResults) _brief(r)],
    if (report != null) 'report': _briefReport(report!),
    if (error != null) 'error': error,
    'warnings': warnings,
    'overallTotal': overallTotal,
  };

  factory DarkroomBuildJob.fromJson(Map<String, dynamic> json) {
    final plan = json['plan'] is Map
        ? DarkroomBuildPlan.fromJson(
            Map<String, dynamic>.from(json['plan'] as Map),
          )
        : null;
    final report = json['report'] is Map
        ? Map<String, dynamic>.from(json['report'] as Map)
        : null;
    if (report != null && plan != null) report['plan'] = plan.toJson();
    return DarkroomBuildJob(
      target: json['target'] as String,
      stage: DarkroomJobStage.values.byName(json['stage'] as String),
      message: json['message'] as String? ?? '',
      startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
      finishedAt: json['finishedAt'] == null
          ? null
          : DateTime.parse(json['finishedAt'] as String).toLocal(),
      unattended: json['unattended'] == true,
      nightRunId: json['nightRunId'] as String?,
      plan: plan,
      preview: json['preview'] is Map
          ? DarkroomRegistrationPreview.fromJson(
              Map<String, dynamic>.from(json['preview'] as Map),
            )
          : null,
      directory: json['directory'] as String?,
      filterResults: [
        for (final r in json['filterResults'] as List? ?? const [])
          Map<String, dynamic>.from(r as Map),
      ],
      report: report,
      error: json['error'] as String?,
      warnings: [for (final w in json['warnings'] as List? ?? const []) '$w'],
      overallTotal: (json['overallTotal'] as num?)?.toInt() ?? 0,
    );
  }

  static Map<String, dynamic> _brief(Map<String, dynamic> result) => {
    for (final key in [
      'filter',
      'error',
      'frameCount',
      'totalIntegrationSec',
      'masterPath',
      'coveragePath',
    ])
      if (result.containsKey(key)) key: result[key],
  };

  static Map<String, dynamic> _briefReport(Map<String, dynamic> report) => {
    'results': [
      for (final r in report['results'] as List? ?? const [])
        _brief(Map<String, dynamic>.from(r as Map)),
    ],
    'failures': report['failures'] ?? const [],
    'delivery': report['delivery'],
  };
}

/// What the Darkroom keeps across restarts: the current build, the builds
/// waiting at the framing check, and the latest finished ones.
const String darkroomBuildJobsStateKey = 'build_jobs.v1';

/// How many finished builds are kept for the Activity tab.
const int darkroomRecentBuildsKept = 20;

/// Builds that wait at the framing check and are not the current job.
class DarkroomHeldBuilds extends Notifier<List<DarkroomBuildJob>> {
  @override
  List<DarkroomBuildJob> build() => const [];

  void _set(List<DarkroomBuildJob> jobs) => state = List.unmodifiable(jobs);
}

final darkroomHeldBuildsProvider =
    NotifierProvider<DarkroomHeldBuilds, List<DarkroomBuildJob>>(
      DarkroomHeldBuilds.new,
    );

/// Finished builds, newest first.
class DarkroomRecentBuilds extends Notifier<List<DarkroomBuildJob>> {
  @override
  List<DarkroomBuildJob> build() => const [];

  void _set(List<DarkroomBuildJob> jobs) => state = List.unmodifiable(jobs);
}

final darkroomRecentBuildsProvider =
    NotifierProvider<DarkroomRecentBuilds, List<DarkroomBuildJob>>(
      DarkroomRecentBuilds.new,
    );

/// The folder an unattended build of [target] writes into under [root]. One
/// folder per target, so each night folds into the same build.
Directory darkroomTargetBuildDirectory(Directory root, String target) =>
    Directory(
      p.join(root.path, target.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')),
    );

/// Where unattended builds go unless told otherwise.
Future<Directory> defaultDarkroomMastersRoot() async => Directory(
  p.join((await resolveSkotiqDocumentsDirectory()).path, 'Skotiq', 'Masters'),
);

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
      } catch (e) {
        // Unreadable files stay listed under their session.
        developer.log(
          'Darkroom: no OBJECT for ${f.filePath}: $e',
          name: 'darkroom',
        );
      }
    }
    name ??= 'Session ${f.sessionId ?? 'unassigned'}';
    targets.putIfAbsent(name, () => []).add(f);
  }
  return targets;
}

/// The master builds of this process. They live above every screen, so a
/// build keeps running while the user goes elsewhere, and its progress and
/// outcome are here to come back to. The current build, the builds waiting
/// at the framing check and the latest finished ones are saved, so a restart
/// loses none of them: a build that was running when the process ended comes
/// back stopped, ready to resume from its folder.
class DarkroomBuildJobs extends Notifier<DarkroomBuildJob?> {
  StreamSubscription<({String phase, double fraction})>? _progress;
  DateTime? _rateStart;
  int _rateBase = 0;
  List<int> _currentIds = const [];
  int _finishedLights = 0;
  bool _quiet = false;
  Future<void>? _restored;
  Future<void> _saving = Future<void>.value();
  final _finished = StreamController<DarkroomBuildJob>.broadcast();
  final _idleWaiters = <Completer<void>>[];

  @override
  DarkroomBuildJob? build() {
    ref.onDispose(() {
      _progress?.cancel();
      _finished.close();
    });
    return null;
  }

  DarkroomBuildService get _service => ref.read(darkroomBuildServiceProvider);

  /// Every build that ends (done, failed or stopped), as it ends.
  Stream<DarkroomBuildJob> get finished => _finished.stream;

  /// Whether a build is running.
  bool get busy => state?.active == true || _service.isRunning;

  /// Completes once no build is running.
  Future<void> whenIdle() {
    if (!busy) return Future<void>.value();
    final waiter = Completer<void>();
    _idleWaiters.add(waiter);
    return waiter.future;
  }

  /// Read the saved builds back. Safe to call more than once; later calls
  /// wait for the first.
  Future<void> restore() => _restored ??= _restore();

  Future<void> _restore() async {
    Map<String, dynamic>? saved;
    try {
      saved = await ref
          .read(darkroomStateStoreProvider)
          .read(darkroomBuildJobsStateKey);
    } catch (e) {
      developer.log('Darkroom: saved builds not read: $e', name: 'darkroom');
    }
    if (saved == null) return;
    List<DarkroomBuildJob> jobs(String key) => [
      for (final j in saved![key] as List? ?? const [])
        if (_decode(j) case final job?) job,
    ];
    if (ref.read(darkroomHeldBuildsProvider).isEmpty) {
      ref.read(darkroomHeldBuildsProvider.notifier)._set(jobs('held'));
    }
    if (ref.read(darkroomRecentBuildsProvider).isEmpty) {
      ref.read(darkroomRecentBuildsProvider.notifier)._set(jobs('recent'));
    }
    final current = _decode(saved['current']);
    if (current == null || state != null) return;
    if (current.active) {
      final resumable =
          current.directory != null &&
          await File(p.join(current.directory!, 'plan.json')).exists();
      state = current.copyWith(
        stage: DarkroomJobStage.stopped,
        message: resumable
            ? 'Interrupted when Skotiq closed. Resume keeps the finished '
                  'filters.'
            : 'Interrupted when Skotiq closed, before the build started. '
                  'Check framing again.',
        finishedAt: DateTime.now(),
        clearEta: true,
      );
      _save();
    } else {
      state = current;
    }
  }

  static DarkroomBuildJob? _decode(Object? json) {
    if (json is! Map) return null;
    try {
      return DarkroomBuildJob.fromJson(Map<String, dynamic>.from(json));
    } catch (e) {
      developer.log(
        'Darkroom: a saved build was unreadable: $e',
        name: 'darkroom',
      );
      return null;
    }
  }

  void _set(DarkroomBuildJob job) {
    final before = state;
    state = job;
    if (before == null ||
        before.stage != job.stage ||
        !identical(before.plan, job.plan) ||
        !identical(before.preview, job.preview) ||
        before.error != job.error ||
        before.directory != job.directory ||
        before.filterResults.length != job.filterResults.length) {
      _save();
    }
    if (job.ended && before?.ended != true) _finished.add(job);
    if (!busy && _idleWaiters.isNotEmpty) {
      for (final w in _idleWaiters) {
        w.complete();
      }
      _idleWaiters.clear();
    }
  }

  /// Save the builds. Writes are chained so the last state always lands last.
  void _save() {
    final snapshot = {
      'current': state?.toJson(),
      'held': [
        for (final j in ref.read(darkroomHeldBuildsProvider)) j.toJson(),
      ],
      'recent': [
        for (final j in ref.read(darkroomRecentBuildsProvider)) j.toJson(),
      ],
    };
    final store = ref.read(darkroomStateStoreProvider);
    _saving = _saving.then((_) async {
      try {
        await store.write(darkroomBuildJobsStateKey, snapshot);
      } catch (e) {
        developer.log('Darkroom: builds not saved: $e', name: 'darkroom');
      }
    });
  }

  /// Wait for the saves made so far.
  Future<void> flush() => _saving;

  /// Make [job] the current build. A build waiting at the framing check is
  /// kept in the held list, a finished one in the recent list, and a held
  /// build of the same target is replaced.
  void _begin(DarkroomBuildJob job, {bool quiet = false}) {
    _guardIdle();
    final previous = state;
    final held = [
      for (final h in ref.read(darkroomHeldBuildsProvider))
        if (h.target != job.target) h,
    ];
    if (previous != null) {
      if (previous.stage == DarkroomJobStage.awaitingReview) {
        if (previous.target != job.target) held.add(previous);
      } else if (previous.ended) {
        _archive(previous);
      }
    }
    ref.read(darkroomHeldBuildsProvider.notifier)._set(held);
    _quiet = quiet;
    state = null;
    _set(job);
  }

  void _archive(DarkroomBuildJob job) {
    final recent = [
      job,
      for (final r in ref.read(darkroomRecentBuildsProvider))
        if (!identical(r, job)) r,
    ];
    ref
        .read(darkroomRecentBuildsProvider.notifier)
        ._set(recent.take(darkroomRecentBuildsKept).toList());
  }

  /// The build of [target] waiting at the framing check, current or held.
  DarkroomBuildJob? heldFor(String target) {
    final current = state;
    if (current?.target == target &&
        current?.stage == DarkroomJobStage.awaitingReview) {
      return current;
    }
    for (final h in ref.read(darkroomHeldBuildsProvider)) {
      if (h.target == target) return h;
    }
    return null;
  }

  /// Make the held build of [target] the current one, so its framing check
  /// can be reviewed, edited and accepted. Returns it, or null when [target]
  /// has none.
  DarkroomBuildJob? reviewHeld(String target) {
    final current = state;
    if (current?.target == target &&
        current?.stage == DarkroomJobStage.awaitingReview) {
      return current;
    }
    final held = ref
        .read(darkroomHeldBuildsProvider)
        .where((h) => h.target == target)
        .firstOrNull;
    if (held == null) return null;
    _begin(held, quiet: false);
    return held;
  }

  /// Forget the held build of [target] without building it.
  void discardHeld(String target) {
    final current = state;
    if (current?.target == target &&
        current?.stage == DarkroomJobStage.awaitingReview) {
      state = null;
    }
    ref.read(darkroomHeldBuildsProvider.notifier)._set([
      for (final h in ref.read(darkroomHeldBuildsProvider))
        if (h.target != target) h,
    ]);
    _save();
  }

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
    _begin(
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

  /// Accept the crop and build into [directory], or into the folder the
  /// build already has (an unattended build held for review).
  Future<void> accept([Directory? directory]) async {
    final job = state;
    if (job?.plan == null || job!.preview == null) {
      throw StateError('Check framing before building.');
    }
    if (!job.preview!.meetsMinimum) {
      throw StateError(job.preview!.describeLimit());
    }
    final folder = directory?.path ?? job.directory;
    if (folder == null) {
      throw StateError('Choose a folder for the masters.');
    }
    _quiet = false;
    await _build(job.copyWith(directory: folder), job.plan!, job.preview);
  }

  /// Resume the build saved in [folder].
  Future<void> resume(Directory folder) async {
    final saved =
        jsonDecode(await File(p.join(folder.path, 'plan.json')).readAsString())
            as Map;
    final plan = DarkroomBuildPlan.fromJson(
      Map<String, dynamic>.from(saved['plan'] as Map),
    );
    final previous = state;
    final job = DarkroomBuildJob(
      target: plan.target,
      stage: DarkroomJobStage.building,
      message: 'Resuming',
      startedAt: DateTime.now(),
      plan: plan,
      directory: folder.path,
      unattended: previous?.directory == folder.path && previous!.unattended,
      nightRunId: previous?.directory == folder.path
          ? previous!.nightRunId
          : null,
    );
    // The interrupted job this resumes is replaced, not kept as a result.
    if (previous?.directory == folder.path && previous!.ended) state = null;
    _begin(job);
    await _build(job, plan, null);
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
        finishedAt: DateTime.now(),
      );
      _set(done);
      // A night-end build is announced by its night-end run.
      if (done.nightRunId == null) {
        await _notify(
          'Masters ready: ${done.target}',
          _summary(report),
          deepLink: darkroomTargetPayload(done.target),
        );
      }
    } catch (e) {
      if ('$e'.contains('Stopped')) {
        _set(
          state!.copyWith(
            stage: DarkroomJobStage.stopped,
            message: '$e',
            clearEta: true,
            finishedAt: DateTime.now(),
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
  /// and no dialog, into the target's own folder under [outputRoot]: a new
  /// night folds into the build already there. The build starts only when
  /// the common crop keeps at least [minRetainedArea] of the field;
  /// otherwise the job waits for review. Returns when the job ends or waits.
  ///
  /// With [announce] the outcome is sent as a notification; a night-end run
  /// passes false and sends one morning message for the whole night.
  Future<DarkroomBuildJob> startUnattended(
    String target, {
    Directory? outputRoot,
    double minRetainedArea = defaultMinRetainedArea,
    bool announce = true,
    String? nightRunId,
  }) async {
    _guardIdle();
    final frames = (await loadDarkroomTargets(
      ref.read(databaseProvider),
    ))[target];
    if (frames == null || frames.isEmpty) {
      throw StateError('No captured lights for $target.');
    }
    final root = outputRoot ?? await defaultDarkroomMastersRoot();
    final directory = darkroomTargetBuildDirectory(root, target);
    _begin(
      DarkroomBuildJob(
        target: target,
        unattended: true,
        nightRunId: nightRunId,
        stage: DarkroomJobStage.framing,
        message: 'Preparing calibration and registering every light',
        startedAt: DateTime.now(),
        directory: directory.path,
        framesTotal: frames.length,
        overallTotal: frames.length,
      ),
      quiet: !announce,
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
              plan: plan,
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
        if (!_quiet) {
          await _notify(
            'Masters need framing review: $target',
            '${outcome.preview.describeLimit()} Open the framing check to '
                'leave frames out or accept a smaller crop.',
            deepLink: darkroomFramingPayload(target),
          );
        }
      } else {
        _set(
          state!.copyWith(
            stage: DarkroomJobStage.done,
            plan: outcome.plan,
            report: outcome.report,
            message: 'Masters ready',
            warnings: outcome.warnings,
            clearEta: true,
            finishedAt: DateTime.now(),
          ),
        );
        if (!_quiet) {
          await _notify(
            'Masters ready: $target',
            [_summary(outcome.report!), ...outcome.warnings].join(' '),
            deepLink: darkroomTargetPayload(target),
          );
        }
      }
    } catch (e) {
      _fail(e);
    } finally {
      await _progress?.cancel();
    }
    return state!;
  }

  Future<void> stop() => _service.stop();

  /// Forget a finished, failed, stopped or unaccepted job. A finished one
  /// stays in the recent list.
  void dismiss() {
    final job = state;
    if (job == null || job.active) return;
    if (job.ended) _archive(job);
    state = null;
    _save();
  }

  void _guardIdle() {
    if (busy) {
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
        finishedAt: DateTime.now(),
      ),
    );
    if (!_quiet) {
      unawaited(
        _notify(
          'Master build failed: ${job.target}',
          '$e',
          deepLink: darkroomTargetPayload(job.target),
        ),
      );
    }
  }

  static String _summary(Map<String, dynamic> report) {
    final results = (report['results'] as List).cast<Map>();
    final failures = (report['failures'] as List? ?? const []).cast<Map>();
    final delivery = report['delivery'] as Map;
    final built = results
        .map(
          (r) =>
              '${r['filter']} ${r['frameCount']} frames, ${describeIntegration(r['totalIntegrationSec'] as num)}',
        )
        .join('; ');
    final failed = failures.isEmpty
        ? ''
        : ' Not built: ${failures.map((f) => f['filter']).join(', ')}.';
    return '$built. ${((delivery['retainedArea'] as num) * 100).toStringAsFixed(1)}% of the field kept.$failed';
  }

  Future<void> _notify(
    String title,
    String message, {
    required String deepLink,
  }) async {
    try {
      await ref
          .read(notificationServiceProvider)
          .notify(
            event: NotificationEvent.sequenceComplete,
            title: title,
            message: message,
            routeAs: NotificationCategory.darkroomDraftReady,
            deepLink: deepLink,
          );
    } catch (e) {
      // The job's own state still shows the outcome.
      developer.log('Darkroom: notification not sent: $e', name: 'darkroom');
    }
  }
}

final darkroomBuildJobsProvider =
    NotifierProvider<DarkroomBuildJobs, DarkroomBuildJob?>(
      DarkroomBuildJobs.new,
    );
