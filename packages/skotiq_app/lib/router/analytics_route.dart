import 'query_word.dart';

/// The Analytics sub-tabs, in the order they are shown.
enum AnalyticsTab with QueryWord {
  session('session', []),
  history('history', []),
  projects('projects', []),
  science('science', []);

  const AnalyticsTab(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The tab a `?tab=` word names, or null.
  static AnalyticsTab? fromQuery(String? word) => readQueryWord(values, word);
}

/// The views inside Analytics > Science, in the order they are shown.
enum ScienceTab with QueryWord {
  workspace('workspace', []),
  firstLight('firstlight', ['first_light', 'discovery']),
  transients('transients', ['alerts']);

  const ScienceTab(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The view a `?view=` word (or the old `/science?tab=` word) names, or
  /// null.
  static ScienceTab? fromQuery(String? word) => readQueryWord(values, word);
}

/// The views inside Analytics > Session, in the order they are shown.
enum SessionView with QueryWord {
  charts('charts', []),

  /// Tilt, curvature and guiding residuals of the session's frames.
  optics('optics', ['diagnostics']);

  const SessionView(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The view a `?view=` word names, or null.
  static SessionView? fromQuery(String? word) => readQueryWord(values, word);
}

/// The views of one night in Analytics > History, in the order they are
/// shown.
enum NightView with QueryWord {
  summary('summary', []),
  frames('frames', []),
  log('log', ['replay']),
  report('report', ['review']),
  workbench('workbench', []);

  const NightView(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The view a `?view=` word names, or null.
  static NightView? fromQuery(String? word) => readQueryWord(values, word);
}

/// The night a History link opens: a session, or a sequence run when the link
/// only knows the run.
class NightRef {
  const NightRef.session(int this.sessionId) : runId = null;
  const NightRef.run(int this.runId) : sessionId = null;

  final int? sessionId;
  final int? runId;

  /// The night `?night=` (a session id) or `?run=` names, or null.
  static NightRef? fromQuery(Map<String, String> query) {
    final session = readQueryInt(query['night']);
    if (session != null) return NightRef.session(session);
    final run = readQueryInt(query['run']);
    return run == null ? null : NightRef.run(run);
  }

  Map<String, String> get query => {
        if (sessionId != null) 'night': '$sessionId',
        if (runId != null) 'run': '$runId',
      };

  @override
  bool operator ==(Object other) =>
      other is NightRef &&
      other.sessionId == sessionId &&
      other.runId == runId;

  @override
  int get hashCode => Object.hash(sessionId, runId);
}
