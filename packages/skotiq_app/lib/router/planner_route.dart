import 'query_word.dart';

/// The Plan sub-tabs, in the order they are shown.
///
/// The tabs read left to right as a planning-to-execution funnel: what is
/// best right now, the multi-night campaign workspace, the forecast strip over
/// the target queue, the two sky-work surfaces, then discovery.
enum PlannerTab with QueryWord {
  recommendation('recommendation', ['recommend']),
  projects(
    'projects',
    ['project', 'campaign', 'campaigns', 'progress', 'history'],
  ),
  schedule('scheduler', [
    'schedule',
    'queue',
    'target-queue',
    'targetqueue',
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
