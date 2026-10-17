/// Count labels that read correctly at one.
///
/// Skotiq renders a lot of "`n` things" chips, and every one of them was
/// hand-written as `'\${list.length} things'`. That reads "1 nodes", "1 steps",
/// "1 frames", "1 targets" — spotted across the sequencer header, the sequence
/// tree, the imaging session panel and the template cards while driving the
/// desktop app. Use [countLabel] instead of interpolating the noun directly.
library;

/// `"1 step"` / `"2 steps"`.
///
/// [plural] defaults to [singular] + `'s'`, which covers every current caller;
/// pass it explicitly for irregular nouns (e.g. `countLabel(n, 'entry',
/// plural: 'entries')`).
String countLabel(int count, String singular, {String? plural}) =>
    '$count ${count == 1 ? singular : (plural ?? '${singular}s')}';
