/// The record of one Darkroom pass: every report it made, in order, with the
/// wall-clock time it was made.
///
/// Reports come from two places. The native integration emits them as
/// `IntegrationTelemetry` events (see `api::post_session::telemetry`); the
/// Dart services that plan a pass and run its later stages add their own
/// through [PassReporter]. Both land in one [PassLog], which is all the pass
/// view reads, live or afterwards.
library;

/// One report.
class PassLogEntry {
  const PassLogEntry({
    required this.t,
    required this.kind,
    this.detail = const <String, dynamic>{},
  });

  /// Milliseconds since the epoch at which the report was made.
  final int t;
  final String kind;
  final Map<String, dynamic> detail;

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': t,
    'kind': kind,
    'detail': detail,
  };

  static PassLogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t'];
    final kind = json['kind'];
    if (t is! num || kind is! String) return null;
    final detail = json['detail'];
    return PassLogEntry(
      t: t.toInt(),
      kind: kind,
      detail: detail is Map
          ? Map<String, dynamic>.from(detail)
          : const <String, dynamic>{},
    );
  }
}

/// Every report of one pass.
class PassLog {
  PassLog({required this.runId, List<PassLogEntry>? entries})
    : entries = entries ?? <PassLogEntry>[];

  final String runId;
  final List<PassLogEntry> entries;

  /// Whether the pass reported its end.
  bool get ended => entries.any((e) => e.kind == PassKinds.passEnded);

  int? get startedAt => entries.isEmpty ? null : entries.first.t;

  /// The planned pass, if it was announced.
  Map<String, dynamic>? get plan {
    for (final e in entries) {
      if (e.kind == PassKinds.passPlanned) return e.detail;
    }
    return null;
  }

  String? get target => plan?['target'] as String?;

  int? get sessionId => (plan?['sessionId'] as num?)?.toInt();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': 1,
    'runId': runId,
    'entries': <Map<String, dynamic>>[for (final e in entries) e.toJson()],
  };

  static PassLog? fromJson(Object? json) {
    if (json is! Map) return null;
    final runId = json['runId'];
    final entries = json['entries'];
    if (runId is! String || entries is! List) return null;
    return PassLog(
      runId: runId,
      entries: <PassLogEntry>[
        for (final e in entries) ?PassLogEntry.fromJson(e),
      ],
    );
  }
}

/// The report kinds a pass makes.
abstract final class PassKinds {
  // Made by the Dart services.
  /// `{target, sessionId, lanes: [{lane, subs, exposure}], finishing, color,
  /// drafts}`: what the pass is about to do.
  static const passPlanned = 'pass_planned';

  /// `{ok, error}`: the pass is over.
  static const passEnded = 'pass_ended';

  /// `{lane}`: a lane's master is integrated and the service is solving and
  /// saving it.
  static const laneFinishing = 'lane_finishing';

  /// `{lane, ok, error}`.
  static const laneFinished = 'lane_finished';

  /// `{stage: align | combine | draft, state: started | step | done |
  /// failed, name, error}`: a stage after the lanes. A `step` is one channel
  /// aligned or one master drafted.
  static const stage = 'stage';

  // Made by the native integration, one lane at a time.
  static const runStarted = 'run_started';
  static const calibrated = 'calibrated';
  static const referenceChoosing = 'reference_choosing';
  static const referenceChosen = 'reference_chosen';
  static const registered = 'registered';
  static const weighted = 'weighted';
  static const normalized = 'normalized';
  static const runningPreview = 'running_preview';
  static const integrating = 'integrating';
  static const integrated = 'integrated';
  static const written = 'written';
  static const runEnded = 'run_ended';

  // Made by the color stage (native or Dart) through the same helper.
  static const channelAligned = 'channel_aligned';
  static const combineStarted = 'combine_started';
  static const combineDone = 'combine_done';
}

/// Where Dart services send the reports they make about a pass.
abstract interface class PassReporter {
  /// Add a report to the pass [runId].
  void report(String runId, String kind, [Map<String, dynamic> detail]);

  /// Add a report to the newest pass planned for [sessionId]; a pass is
  /// started for it when there is none.
  void reportForSession(
    int sessionId,
    String kind, [
    Map<String, dynamic> detail,
  ]);

  /// The pass planned for [sessionId] that has not ended, if any.
  String? runningForSession(int sessionId);

  /// The directory the native run [runId] writes its preview PNGs to, or
  /// null when previews are not kept.
  Future<String?> previewDir(String runId);
}
