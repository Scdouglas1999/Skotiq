import 'query_word.dart';

/// The Plan sub-tabs, in the order they are shown: what is best right now,
/// the owner's targets with their progress and the autopilot that works
/// through them, the two sky-work surfaces, then discovery.
enum PlannerTab with QueryWord {
  recommendation('recommendation', ['recommend', 'best', 'best-tonight']),
  targets('targets', [
    'target',
    'projects',
    'project',
    'groups',
    'campaign',
    'campaigns',
    'progress',
    'history',
    'scheduler',
    'schedule',
    'queue',
    'target-queue',
    'targetqueue',
    'autopilot',
    'week',
    'forecast',
    'thisweek',
    'this-week',
  ]),
  framing('framing', []),
  planetarium('planetarium', []),
  discover('discover', ['sky', 'yoursky', 'your-sky', 'constellation']);

  const PlannerTab(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The tab a `?tab=` word names, or null.
  static PlannerTab? fromQuery(String? word) => readQueryWord(values, word);
}

/// The `?group=` word for the mosaics group of Plan > Targets.
const String plannerMosaicsGroupWord = 'mosaics';

/// Which view the Discover tab's segmented control shows.
enum DiscoverView with QueryWord {
  yourSky('yoursky', ['your-sky', 'atlas']),
  constellation('constellation', ['swarm']),
  collaborative('collaborative', ['collaborative-sky', 'collab']);

  const DiscoverView(this.word, this.olderWords);

  @override
  final String word;
  @override
  final List<String> olderWords;

  /// The view a `?view=` word names, or null.
  static DiscoverView? fromQuery(String? word) => readQueryWord(values, word);
}
