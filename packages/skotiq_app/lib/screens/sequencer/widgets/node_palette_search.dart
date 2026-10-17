// Relevance ranking for the node palette's search.
//
// A NAME hit must outrank a DESCRIPTION hit. Filtering on
// `name.contains(q) || description.contains(q)` in catalogue order puts
// "Smart Exposure" above the Dither node for "dither", and "Instruction Set"
// above Loop for "loop" — and the first row is the one people click.
//
// Both palette surfaces (the toolbox pane inside `sequencer_screen.dart` and
// the standalone `NodePalette`) share this ranking so they cannot drift apart.

import 'package:skotiq_core/skotiq_core.dart';

/// Relevance of [item] against an already-lower-cased [query].
///
/// Higher is better. `null` means "no match at all" — the item is dropped.
/// A name hit always beats a description-only hit, so the node the user
/// literally typed can never be pushed below a node that merely mentions it.
int? nodePaletteMatchScore(NodePaletteItem item, String query) {
  final name = item.name.toLowerCase();
  if (name == query) return 100;
  if (name.startsWith(query)) return 80;
  if (name.contains(query)) return 60;
  if (item.description.toLowerCase().contains(query)) return 20;
  return null;
}

/// Filter [categories] by [query] and order both the items inside each
/// category and the categories themselves by relevance.
///
/// Category grouping is kept (the headers are how a user tells a Guiding
/// "Dither" from an Imaging one), but a category is hoisted to the top when
/// it holds the best match, so the first row on screen is the best match
/// overall. Ties preserve the catalogue's own order, which is curated.
///
/// An empty/whitespace-only [query] returns [categories] untouched.
List<NodePaletteCategory> rankNodePaletteMatches(
  List<NodePaletteCategory> categories,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return categories;

  final ranked = <({int order, int best, NodePaletteCategory category})>[];
  for (var ci = 0; ci < categories.length; ci++) {
    final category = categories[ci];

    final scored = <({int order, int score, NodePaletteItem item})>[];
    for (var ii = 0; ii < category.items.length; ii++) {
      final score = nodePaletteMatchScore(category.items[ii], q);
      if (score != null) {
        scored.add((order: ii, score: score, item: category.items[ii]));
      }
    }
    if (scored.isEmpty) continue;

    // List.sort is not stable, so the catalogue index is the explicit
    // tie-breaker rather than an assumption about the sort.
    scored.sort(
        (a, b) => a.score != b.score ? b.score - a.score : a.order - b.order);

    ranked.add((
      order: ci,
      best: scored.first.score,
      category: NodePaletteCategory(
        name: category.name,
        icon: category.icon,
        items: [for (final s in scored) s.item],
      ),
    ));
  }

  ranked.sort((a, b) => a.best != b.best ? b.best - a.best : a.order - b.order);
  return [for (final r in ranked) r.category];
}
