import 'package:skotiq_astro/skotiq_astro.dart' show observingNightOf;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

/// One row of History: a session together with the sequence run that made
/// it. Either half can be missing: sessions recorded before runs were kept
/// have no run, and a run whose session row was never opened has no session.
class NightEntry {
  NightEntry({this.session, this.run, this.stats})
      : assert(session != null || run != null);

  final ImagingSession? session;
  final SequenceRun? run;

  /// The run's statistics, or null when there is no run or its record cannot
  /// be read.
  final ParsedRunStats? stats;

  String? get name => session?.name ?? run?.sequenceName;

  DateTime get startedAt => session?.startTime ?? run!.startedAt;

  /// The observing night the entry started in (the local evening date).
  DateTime get night => observingNightOf(startedAt);

  /// How the night ended, in the run vocabulary. A session still open reads
  /// as running; null when the stored word is not one the app knows.
  SequenceRunStatus? get ending {
    final runStatus = run?.runStatus;
    if (runStatus != null) return runStatus;
    final sessionStatus = session?.sessionStatus;
    if (sessionStatus == SessionStatus.active) return SequenceRunStatus.running;
    return sessionStatus?.runEnding;
  }

  /// The target names the run reported frames for.
  Iterable<String> get runTargets => stats?.targetBreakdown.keys ?? const [];
}

/// The run's statistics, or null when the stored record cannot be read. One
/// unreadable row must not take the list down.
ParsedRunStats? parseRunStats(String json) {
  try {
    return ParsedRunStats.fromJson(json);
  } on FormatException {
    return null;
  } on TypeError {
    return null;
  }
}

/// Every night on record, newest first: each session with its run, then the
/// runs no session claims.
List<NightEntry> pairNightEntries(
  List<ImagingSession> sessions,
  List<SequenceRun> runs,
) {
  final runBySession = <int, SequenceRun>{};
  final orphans = <SequenceRun>[];
  for (final run in runs) {
    final sessionId = resolveSessionIdForSequenceRun(run, sessions);
    if (sessionId == null || runBySession.containsKey(sessionId)) {
      orphans.add(run);
    } else {
      runBySession[sessionId] = run;
    }
  }
  NightEntry entry(ImagingSession? session, SequenceRun? run) => NightEntry(
        session: session,
        run: run,
        stats: run == null ? null : parseRunStats(run.statsJson),
      );
  return [
    for (final session in sessions) entry(session, runBySession[session.id]),
    for (final run in orphans) entry(null, run),
  ]..sort((a, b) => b.startedAt.compareTo(a.startedAt));
}

/// The span of time History lists.
enum HistoryPeriod {
  all('All time'),
  thisMonth('This month'),
  thisYear('This year');

  const HistoryPeriod(this.label);

  final String label;

  bool contains(DateTime when, DateTime now) {
    final local = when.toLocal();
    return switch (this) {
      all => true,
      thisMonth => local.year == now.year && local.month == now.month,
      thisYear => local.year == now.year,
    };
  }
}

/// What the History toolbar narrows the list by.
class HistoryFilter {
  const HistoryFilter({
    this.query = '',
    this.status,
    this.target,
    this.untargeted = false,
    this.period = HistoryPeriod.all,
    this.sequenceId,
  });

  /// Matched against the night's name and the run's target names.
  final String query;

  /// A live status (running) also matches a paused run.
  final SequenceRunStatus? status;

  /// A target name from the library.
  final String? target;

  /// Only nights with no target; set instead of [target].
  final bool untargeted;

  final HistoryPeriod period;

  /// Only the runs of one saved sequence (Saved > View runs).
  final int? sequenceId;

  bool get isEmpty =>
      query.trim().isEmpty &&
      status == null &&
      target == null &&
      !untargeted &&
      period == HistoryPeriod.all &&
      sequenceId == null;

  /// True when a quick-capture row, which has no name, status or target, can
  /// still belong in the list.
  bool get admitsQuickCaptures =>
      query.trim().isEmpty &&
      status == null &&
      target == null &&
      !untargeted &&
      sequenceId == null;

  HistoryFilter copyWith({
    String? query,
    SequenceRunStatus? Function()? status,
    String? Function()? target,
    bool? untargeted,
    HistoryPeriod? period,
    int? Function()? sequenceId,
  }) =>
      HistoryFilter(
        query: query ?? this.query,
        status: status == null ? this.status : status(),
        target: target == null ? this.target : target(),
        untargeted: untargeted ?? this.untargeted,
        period: period ?? this.period,
        sequenceId: sequenceId == null ? this.sequenceId : sequenceId(),
      );

  bool matches(
    NightEntry entry, {
    required Map<int, String> targetNameById,
    required DateTime now,
  }) {
    if (!period.contains(entry.startedAt, now)) return false;

    if (sequenceId != null &&
        entry.run?.sequenceId != sequenceId &&
        entry.session?.sequenceId != sequenceId) {
      return false;
    }

    final wanted = status;
    if (wanted != null) {
      final ending = entry.ending;
      final matchesLive = wanted.isLive && (ending?.isLive ?? false);
      if (ending != wanted && !matchesLive) return false;
    }

    final targetId = entry.session?.targetId;
    final sessionTarget = targetId == null ? null : targetNameById[targetId];
    if (untargeted && sessionTarget != null && sessionTarget.isNotEmpty) {
      return false;
    }
    if (target != null &&
        sessionTarget != target &&
        !entry.runTargets.contains(target)) {
      return false;
    }

    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return (entry.name?.toLowerCase().contains(needle) ?? false) ||
        entry.runTargets.any((name) => name.toLowerCase().contains(needle));
  }
}

/// The frames taken outside any sequence during one observing night.
class QuickCaptureNight {
  QuickCaptureNight(this.night, this.lights);

  final DateTime night;
  final List<DbCapturedImage> lights;

  double get integrationSecs => lights.fold(
        0,
        (sum, image) =>
            image.exposureDuration.isFinite && image.exposureDuration > 0
                ? sum + image.exposureDuration
                : sum,
      );
}

/// One observing night of History, newest entries first.
class HistoryNight {
  HistoryNight(this.night, this.entries, this.quickCaptures);

  /// The local evening date the night began on.
  final DateTime night;
  final List<NightEntry> entries;
  final QuickCaptureNight? quickCaptures;
}

/// [entries] and the quick captures in [standaloneLights] grouped by
/// observing night, newest night first.
List<HistoryNight> groupByNight(
  List<NightEntry> entries, {
  List<DbCapturedImage> standaloneLights = const [],
}) {
  final byNight = <DateTime, List<NightEntry>>{};
  for (final entry in entries) {
    byNight.putIfAbsent(entry.night, () => []).add(entry);
  }
  final quickByNight = <DateTime, List<DbCapturedImage>>{};
  for (final image in standaloneLights) {
    quickByNight
        .putIfAbsent(observingNightOf(image.capturedAt), () => [])
        .add(image);
  }
  final nights = {...byNight.keys, ...quickByNight.keys}.toList()
    ..sort((a, b) => b.compareTo(a));
  return [
    for (final night in nights)
      HistoryNight(
        night,
        byNight[night] ?? const [],
        quickByNight[night] == null
            ? null
            : QuickCaptureNight(night, quickByNight[night]!),
      ),
  ];
}

/// Lifetime totals shown above the History list.
class HistoryTotals {
  const HistoryTotals({
    required this.exposures,
    required this.acceptedIntegrationSecs,
    required this.meridianFlips,
    required this.autofocusRuns,
    required this.meanHfr,
    required this.meanGuidingRms,
    required this.meanSensorTemp,
  });

  /// Every frame on record, calibration frames included.
  final int exposures;

  /// Exposure time of the accepted light frames.
  final double acceptedIntegrationSecs;

  /// Counted from the run records; null while they have not loaded.
  final int? meridianFlips;

  /// Counted from the session records; null while they have not loaded.
  final int? autofocusRuns;

  /// Means over the accepted light frames that recorded the value.
  final double? meanHfr;
  final double? meanGuidingRms;

  /// Mean over every frame that recorded a sensor temperature.
  final double? meanSensorTemp;

  static HistoryTotals of({
    required List<DbCapturedImage> images,
    required List<ImagingSession>? sessions,
    required List<SequenceRun>? runs,
  }) {
    final acceptedLights =
        images.where((i) => i.isLight && i.isAccepted).toList(growable: false);
    return HistoryTotals(
      exposures: images.length,
      acceptedIntegrationSecs: acceptedLights.fold(
        0,
        (sum, image) =>
            image.exposureDuration.isFinite && image.exposureDuration > 0
                ? sum + image.exposureDuration
                : sum,
      ),
      meridianFlips: runs?.fold<int>(
        0,
        (sum, run) => sum + (parseRunStats(run.statsJson)?.meridianFlips ?? 0),
      ),
      autofocusRuns: sessions?.fold<int>(
        0,
        (sum, session) => sum + session.autofocusCount,
      ),
      meanHfr: _mean(
        acceptedLights.map((i) => i.hfr).where((v) => v != null && v >= 0),
      ),
      meanGuidingRms: _mean(
        acceptedLights
            .map((i) => i.guidingRmsTotal)
            .where((v) => v != null && v >= 0),
      ),
      meanSensorTemp: _mean(images.map((i) => i.sensorTemp)),
    );
  }

  static double? _mean(Iterable<double?> values) {
    var sum = 0.0;
    var count = 0;
    for (final value in values) {
      if (value == null || !value.isFinite) continue;
      sum += value;
      count++;
    }
    return count == 0 ? null : sum / count;
  }
}
