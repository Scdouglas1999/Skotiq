import '../../router/query_word.dart';

/// The Analytics sub-tabs, in the order they are shown; Diagnostics is
/// right-most.
enum AnalyticsTab with QueryWord {
  session('session', []),
  history('history', []),
  projects('projects', []),
  equipment('equipment', ['equipment-stats', 'equipmentstats']),
  science('science', []),
  diagnostics('diagnostics', []);

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
