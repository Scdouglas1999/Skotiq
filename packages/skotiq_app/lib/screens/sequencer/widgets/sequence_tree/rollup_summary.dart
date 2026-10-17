// One line that says what a COLLAPSED container holds.
//
// Collapsing a container is what makes a 40-step night fit on a screen, and a
// collapsed row that says only "Narrowband" has hidden the plan rather than
// summarised it. This produces the line the ledger and compact rows append in
// `textMuted` after the container's name (spec §3).
//
// Widget-free and pure so each shape is unit-testable in isolation. The
// per-child descriptors come from `nodeSummary`, the same terse fragment list
// the expanded row shows, so a collapsed summary cannot contradict the rows it
// is standing in for.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../plan_math.dart';
import '../node_summary.dart';
import '../../ledger_seconds.dart';

/// How many child names the generic shape lists before it counts the rest.
const _genericNameLimit = 3;

/// A one-line description of what [container] holds, or `''` when it holds
/// nothing (an empty container's name already says everything there is).
///
/// Four shapes, in precedence order:
///
///  1. **Target** — `North America Nebula · Ha/OIII/SII`: the object and the
///     bands the subtree will actually image.
///  2. **Filter run** — `Ha · OIII · SII 300 s ×12 each · dither every 3`:
///     children that are exposures differing ONLY by filter, which is what a
///     narrowband loop is. Applied to any container of such exposures, not
///     just a loop: an instruction set holding the same three rows is the same
///     plan and deserves the same line.
///  3. **Trigger group** — `meridian flip minutesPastMeridian · 5 min past ·
///     auto-center`: a container whose children are all watchdogs (plus,
///     optionally, the autofocus that usually rides with them), described by
///     their own summaries because a watchdog's threshold IS its identity.
///  4. **Generic** — the first three child names, then `+k more`.
String rollupSummary(SequenceNode container, Sequence sequence) {
  final children = sequence.getChildren(container.id);
  if (children.isEmpty) return '';

  if (container is TargetHeaderNode) {
    final target = _targetSummary(container, sequence);
    if (target != null) return target;
  }

  final filterRun = _filterRunSummary(children);
  if (filterRun != null) return filterRun;

  final triggers = _triggerGroupSummary(children);
  if (triggers != null) return triggers;

  return _genericSummary(children);
}

/// `<target name> · Ha/OIII/SII`.
///
/// Returns null when the subtree images nothing, so a target that is only a
/// slew and a park falls through to the generic shape rather than printing its
/// own name and stopping.
String? _targetSummary(TargetHeaderNode target, Sequence sequence) {
  final planned = plannedCaptureUnder(sequence, target.id);
  final filters = planned.integrationSecsByFilter.keys
      .where((name) => name != _noFilterKey)
      .toList(growable: false);
  if (filters.isEmpty) return null;
  return '${target.targetName} · ${filters.join('/')}';
}

/// The key `plannedCaptureUnder` collects unfiltered exposures under. It is a
/// bucket, not a band, so it never joins the filter list.
const _noFilterKey = 'No filter';

/// `Ha · OIII · SII 300 s ×12 each · dither every 3`.
///
/// Requires at least two exposure children that agree on everything except
/// their filter — exposure length, count, frame type, gain, offset, binning
/// and dither cadence. One child is not a "run" (there is nothing for "each"
/// to distribute over) and a set that disagrees on exposure length is two
/// plans, not one; both fall through.
String? _filterRunSummary(List<SequenceNode> children) {
  if (children.length < 2) return null;
  final exposures = <ExposureNode>[];
  for (final child in children) {
    if (child is! ExposureNode) return null;
    exposures.add(child);
  }

  final first = exposures.first;
  for (final exposure in exposures.skip(1)) {
    if (exposure.durationSecs != first.durationSecs ||
        exposure.count != first.count ||
        exposure.frameType != first.frameType ||
        exposure.gain != first.gain ||
        exposure.offset != first.offset ||
        exposure.binning != first.binning ||
        exposure.ditherEvery != first.ditherEvery) {
      return null;
    }
  }

  final filters = exposures
      .map((exposure) => exposure.filter)
      .whereType<String>()
      .where((filter) => filter.isNotEmpty)
      .toList(growable: false);
  // Unfiltered exposures have no bands to name; describing them as a filter
  // run would print `· 300 s ×12 each` with nothing in front of it.
  if (filters.length != exposures.length) return null;
  if (filters.toSet().length != filters.length) return null;

  final dither = first.ditherEvery;
  // The filter list runs straight into the shared spec: `Ha · OIII · SII
  // 300 s ×12 each` reads as one phrase; a ` · ` there would detach the
  // exposure length from the bands it belongs to.
  return <String>[
    '${filters.join(' · ')} ${formatLedgerSeconds(first.durationSecs)} s '
        '×${first.count} each',
    if (dither != null && dither > 0) 'dither every $dither',
  ].join(' · ');
}

/// `meridian flip minutesPastMeridian · 5 min past · autofocus global AF
/// settings`.
///
/// Returns null unless every child is a watchdog or an autofocus AND at least
/// one is a watchdog: a container of plain instructions is not a trigger
/// group, and an autofocus-only set reads better as the generic shape.
String? _triggerGroupSummary(List<SequenceNode> children) {
  var watchdogs = 0;
  for (final child in children) {
    final isWatchdog = child.category == NodeCategory.trigger;
    if (isWatchdog) watchdogs++;
    if (!isWatchdog && child is! AutofocusNode) return null;
  }
  if (watchdogs == 0) return null;

  final described = <String>[
    for (final child in children.take(_genericNameLimit)) _describe(child),
  ];
  final extra = children.length - described.length;
  return extra > 0
      ? '${described.join(' · ')} · +$extra more'
      : described.join(' · ');
}

/// The child's name in the running prose of a summary line, followed by its
/// own terse summary when it has one.
String _describe(SequenceNode node) {
  final summary = _summaryText(node);
  final name = node.name.toLowerCase();
  return summary.isEmpty ? name : '$name $summary';
}

/// The plain text of [node]'s at-a-glance summary, joined the way the row's
/// accessibility string joins it.
String _summaryText(SequenceNode node) {
  return nodeSummary(node)
      .map((fragment) => switch (fragment) {
            StaticFragment(text: final text) => text.trim(),
            EditableFragment(displayValue: final value) => value.trim(),
          })
      .where((text) => text.isNotEmpty)
      .join(' ');
}

/// `Slew · Center · Start Guiding · +2 more`.
String _genericSummary(List<SequenceNode> children) {
  final names = children
      .take(_genericNameLimit)
      .map((child) => child.name)
      .toList(growable: false);
  final extra = children.length - names.length;
  return extra > 0 ? '${names.join(' · ')} · +$extra more' : names.join(' · ');
}

/// The collapsed-container summary for every node in the open sequence,
/// computed once per sequence change rather than once per row build: each
/// `rollupSummary` call walks the node's children (and, for targets, the whole
/// subtree via `plannedCaptureUnder`), so running it inside every collapsed
/// row's `build` repeats that walk on every progress tick. Rows read their own
/// entry with `.select`. `autoDispose` so the map is freed with the tree.
final rollupSummaryMapProvider =
    Provider.autoDispose<Map<String, String>>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return const <String, String>{};
  final summaries = <String, String>{};
  for (final node in sequence.nodes.values) {
    if (node.childIds.isEmpty) continue;
    final summary = rollupSummary(node, sequence);
    if (summary.isNotEmpty) summaries[node.id] = summary;
  }
  return Map<String, String>.unmodifiable(summaries);
});
