// The Targets panel: the toolbox tab that answers "what am I pointing at?".
//
// Two sections, because the word "queue" was doing two jobs and neither was
// visible. The tab used to be called Queue and showed ONLY the planetarium's
// wishlist, so loading the bundled "Mono LRGB M51" starter — a sequence with a
// target in it — produced the tab saying "Your target queue is empty."
//
//   * IN THIS SEQUENCE reads `Sequence.targetHeaders`, the same list the
//     canvas bar counts in its "1 target" chip. One row per target header,
//     with the coordinates and the planned capture the tree row carries, and a
//     tap that selects it in the tree and scrolls it into view — the same
//     `selectedNodeIdProvider` + `treeNodeKeyRegistryProvider` jump the step
//     finder and the minimap use.
//   * SAVED FOR LATER is the planetarium's `targetQueueProvider` wishlist,
//     unchanged: sort, filter, live visibility readouts, drag-to-insert and
//     remove. The section stays on screen when it is empty so the panel says
//     what the wishlist IS rather than only reporting that it has nothing.
//
// The panel is still purely a *view* on both sources. Mutations to the
// wishlist (add / remove / mark active) flow through `targetQueueProvider`;
// selection flows through `selectedNodeIdProvider`.
//
// Drag payload: a `TargetQueueDragPayload` (defined below) carrying the
// queued target plus a resolved coordinate. The sequence tree's
// existing `DragTarget<Object>` is widened in `sequence_tree.dart` to
// accept this payload and convert it into an `addNode` call.
//
// Drag-drop is disabled while the sequencer is running: the panel
// watches `canEditSequenceProvider` and wraps the Draggable subtree in
// an IgnorePointer when edits are locked.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/add_target_header_helper.dart';
import '../../../utils/count_label.dart';
import '../../accessible_dropdown.dart';
import '../plan_math.dart';
import 'sequence_tree.dart' show revealSequenceRow, treeNodeKeyRegistryProvider;
import 'target_coordinates.dart';
import 'target_header_card.dart';

/// Drag payload type carried by `Draggable<TargetQueueDragPayload>` from
/// the queue panel to the sequence tree. Carries the source queued
/// target so the tree can both build the node and (after a successful
/// drop) mark the queue entry as "in plan" for visual feedback.
/// Drag ghost width: design 320px, capped to ~92% of viewport so narrow
/// test surfaces and split-pane layouts never hit [clamp] min > max.
double _dragFeedbackWidth(BuildContext context) {
  final viewport = MediaQuery.sizeOf(context).width;
  final maxW = viewport * AdaptiveDialogConstraints.defaultWidthFraction;
  if (maxW <= 120) return maxW;
  return AdaptiveDialogConstraints.clampPanelWidth(
    context,
    designWidth: 320,
    minWidth: math.min(160, maxW),
    maxWidth: maxW,
  );
}

class TargetQueueDragPayload {
  final QueuedTarget queuedTarget;

  /// Pre-computed TargetHeaderNode template. Built in the panel so the
  /// drop site doesn't need access to the planetarium types — it just
  /// reads `node` and passes it to `currentSequenceProvider.addNode`.
  final TargetHeaderNode node;

  const TargetQueueDragPayload({
    required this.queuedTarget,
    required this.node,
  });
}

/// Matches an executor target to a queue label without confusing catalog IDs
/// such as M1 and M10. Qualified names (for example "M31 (Panel 1/9)") still
/// match their base target when the extra text begins at a word boundary.
bool targetQueueNamesMatch(String first, String second) {
  final a = first.trim().toLowerCase();
  final b = second.trim().toLowerCase();
  if (a.isEmpty || b.isEmpty) return false;
  return _isQualifiedTargetName(a, b) || _isQualifiedTargetName(b, a);
}

bool _isQualifiedTargetName(String candidate, String base) {
  if (candidate == base) return true;
  if (!candidate.startsWith(base) || candidate.length == base.length) {
    return false;
  }
  return RegExp(r'[\s\(\[\{\-–—/:]').hasMatch(candidate[base.length]);
}

/// Sort modes for the target queue list.
enum _QueueSortMode {
  userOrder,
  score,
  altitude,
  name,
  ra,
}

extension _QueueSortModeLabel on _QueueSortMode {
  String get label {
    switch (this) {
      case _QueueSortMode.userOrder:
        return 'User order';
      case _QueueSortMode.score:
        return 'Visibility (altitude proxy)';
      case _QueueSortMode.altitude:
        return 'Current altitude';
      case _QueueSortMode.name:
        return 'Name';
      case _QueueSortMode.ra:
        return 'RA';
    }
  }
}

/// Filter modes.
enum _QueueFilterMode {
  all,
  aboveHorizon,
  pendingOnly,
}

extension _QueueFilterLabel on _QueueFilterMode {
  String get label {
    switch (this) {
      case _QueueFilterMode.all:
        return 'All targets';
      case _QueueFilterMode.aboveHorizon:
        return 'Above horizon';
      case _QueueFilterMode.pendingOnly:
        return 'Pending only';
    }
  }
}

/// Single-target visibility snapshot computed from the shared ticker.
class _TargetVisibility {
  final double altitudeDeg;
  final double azimuthDeg;
  final double? transitAltitudeDeg;
  final DateTime? setTime;
  final bool aboveHorizon;
  final bool neverRises;
  final bool isCircumpolar;

  const _TargetVisibility({
    required this.altitudeDeg,
    required this.azimuthDeg,
    required this.transitAltitudeDeg,
    required this.setTime,
    required this.aboveHorizon,
    required this.neverRises,
    required this.isCircumpolar,
  });
}

_TargetVisibility _computeVisibility({
  required CelestialCoordinate coords,
  required double latitude,
  required double longitude,
  required DateTime now,
  required double effectiveHorizonDeg,
}) {
  final raDeg = coords.raDegrees;
  final decDeg = coords.dec;
  final (alt, az) = AstronomyCalculations.objectAltAz(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: now,
    latitudeDeg: latitude,
    longitudeDeg: longitude,
  );
  final visibility = AstronomyCalculations.calculateObjectVisibility(
    raDeg: raDeg,
    decDeg: decDeg,
    // The NIGHT containing [now], not its calendar day: the scan runs local
    // noon to noon, so after midnight the raw instant selected the FOLLOWING
    // night and the "Sets" countdown below read ~25h for a target an hour from
    // the horizon.
    date: AstronomyCalculations.nightDateOf(now),
    latitudeDeg: latitude,
    longitudeDeg: longitude,
    minAltitude: effectiveHorizonDeg,
  );
  return _TargetVisibility(
    altitudeDeg: alt,
    azimuthDeg: az,
    transitAltitudeDeg: visibility.transitAltitude,
    setTime: visibility.setTime,
    aboveHorizon: alt > effectiveHorizonDeg,
    neverRises: visibility.neverRises,
    isCircumpolar: visibility.isCircumpolar,
  );
}

/// The Targets tab of the sequencer Builder toolbox.
///
/// Named for the wishlist it started as; it now renders the sequence's own
/// targets above that wishlist. The class name is kept because the drag
/// payload beside it (`TargetQueueDragPayload`) is what `sequence_tree.dart`
/// accepts, and renaming both for the tab's sake would rename a wire contract.
class TargetQueuePanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const TargetQueuePanel({
    super.key,
    required this.colors,
  });

  @override
  ConsumerState<TargetQueuePanel> createState() => _TargetQueuePanelState();
}

class _TargetQueuePanelState extends ConsumerState<TargetQueuePanel> {
  _QueueSortMode _sortMode = _QueueSortMode.userOrder;
  _QueueFilterMode _filterMode = _QueueFilterMode.all;

  /// Per-target visibility cache. Keyed by an invalidation signature built
  /// from the 30s tick bucket, observer location, and horizon so a sort/
  /// filter dropdown change (which triggers setState but doesn't change the
  /// sky) reuses the snapshots instead of recomputing real spherical trig for
  /// every queue entry. The cache is rebuilt only when the signature changes.
  final Map<String, _TargetVisibility> _visibilityCache = {};
  String? _visibilityCacheSignature;

  @override
  void initState() {
    super.initState();
    // Cross-screen reactivity: when the sequencer reaches a
    // TargetHeader whose display name matches a queue entry, mark
    // that entry as active. This drives the "live" pulsing card on
    // the planetarium too (both screens read from the same
    // targetQueueProvider).
    //
    // The reverse — removing a TargetHeader from the sequence
    // affecting the queue — is deliberately *not* wired here: the
    // queue is a wishlist and the user expects it to persist when
    // they delete nodes from the sequence tree. The brief is
    // explicit about this asymmetry.
    ref.listenManual<String?>(
      sequenceProgressProvider.select((p) => p.currentTarget),
      (prev, next) {
        if (!mounted) return;
        final queue = ref.read(targetQueueProvider);
        if (next == null || next.isEmpty) {
          // Sequencer is between targets — clear "active" flag.
          if (queue.activeTargetId != null) {
            ref.read(targetQueueProvider.notifier).setActiveTarget(null);
          }
          return;
        }
        // Find queue entry whose displayName matches the executor's
        // current target. Case-insensitive prefix match keeps "M31"
        // and "M31 (Panel 1/9)" together so mosaics light up the
        // parent queue card.
        final match = queue.targets.cast<QueuedTarget?>().firstWhere(
              (t) => t != null && targetQueueNamesMatch(t.displayName, next),
              orElse: () => null,
            );
        if (match != null && match.id != queue.activeTargetId) {
          ref.read(targetQueueProvider.notifier).setActiveTarget(match.id);
        }
      },
      fireImmediately: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final queue = ref.watch(targetQueueProvider);
    final observer = ref.watch(observerLocationProvider);
    final horizonDeg = ref.watch(planetariumEffectiveHorizonDegProvider);
    // Live 30s tick — altitude / time-to-set need to refresh as the
    // sky moves. Cadence intentionally matches the dashboard's altitude
    // card (see clock_provider.dart).
    final tickAsync = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
    final now = tickAsync.valueOrNull ?? DateTime.now();
    final canEdit = ref.watch(canEditSequenceProvider);

    // Compute visibility for every queue entry, memoised on the tick bucket /
    // location / horizon so sort+filter dropdown changes don't recompute the
    // trig. The snapshots stay in lock-step with the 30s ticker; a separate
    // provider would add cache-coordination work for no real benefit at this
    // list size (<= 50 targets typically).
    //
    // Altitude and rise/set are readings against a horizon, so with no site on
    // record there is nothing to compute: the cache is emptied and the rows
    // render without visibility rather than against a default observer.
    final site = observer.site;
    final tickBucket = now.millisecondsSinceEpoch ~/ 30000;
    final signature = site == null
        ? 'no-site'
        : '$tickBucket|${site.latitude}|${site.longitude}|$horizonDeg';
    if (site == null) {
      _visibilityCache.clear();
      _visibilityCacheSignature = signature;
    } else if (_visibilityCacheSignature != signature) {
      _visibilityCache
        ..clear()
        ..addEntries(queue.targets.map((t) => MapEntry(
              t.id,
              _computeVisibility(
                coords: t.coordinates,
                latitude: site.latitude,
                longitude: site.longitude,
                now: now,
                effectiveHorizonDeg: horizonDeg,
              ),
            )));
      _visibilityCacheSignature = signature;
    } else {
      // Same tick/location, but the queue set may have changed (add/remove);
      // backfill any newly-present targets without touching the rest.
      for (final t in queue.targets) {
        _visibilityCache.putIfAbsent(
          t.id,
          () => _computeVisibility(
            coords: t.coordinates,
            latitude: site.latitude,
            longitude: site.longitude,
            now: now,
            effectiveHorizonDeg: horizonDeg,
          ),
        );
      }
    }
    final visibilityByTarget = _visibilityCache;

    final filtered = _applyFilter(queue.targets, visibilityByTarget);
    _applySort(filtered, visibilityByTarget);

    // `targetHeaders` and not a tree walk of our own: it is what the canvas
    // bar's "N targets" chip counts, and a panel that listed a different set
    // from the chip two panes away would be the same class of lie this rewrite
    // is here to remove.
    final sequence = ref.watch(currentSequenceProvider);
    final headers = sequence?.targetHeaders ?? const <TargetHeaderNode>[];
    final selectedId = ref.watch(selectedNodeIdProvider);

    // ONE scroll view over both sections: they are one list of targets read
    // twice, and two independently scrolling boxes in a 280 px column would
    // each be a few rows tall and neither would reach its end.
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _SectionHeader(
            colors: colors,
            label: 'In this sequence',
            count: headers.length,
          ),
        ),
        if (sequence == null || headers.isEmpty)
          SliverToBoxAdapter(
            child: _SectionSentence(
              colors: colors,
              text: 'No targets in this sequence yet. Drop a Target from the '
                  'Nodes tab, or pick one below.',
            ),
          )
        else
          SliverPadding(
            padding: _listPadding,
            sliver: SliverList.separated(
              key: const ValueKey('in_sequence_target_list'),
              itemCount: headers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final header = headers[index];
                return _InSequenceRow(
                  colors: colors,
                  node: header,
                  planned: plannedCaptureUnder(sequence, header.id),
                  isSelected: header.id == selectedId,
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          child: _SectionHeader(
            colors: colors,
            label: 'Saved for later',
            count: queue.targets.length,
          ),
        ),
        if (queue.targets.isEmpty)
          SliverToBoxAdapter(
            child: _SectionSentence(
              colors: colors,
              text: 'Targets you queue from the Planetarium or Plan Tonight '
                  'appear here, ready to drag into the sequence.',
            ),
          )
        else ...[
          SliverToBoxAdapter(
            child: _SortFilterBar(
              colors: colors,
              sortMode: _sortMode,
              filterMode: _filterMode,
              onSortChanged: (m) => setState(() => _sortMode = m),
              onFilterChanged: (m) => setState(() => _filterMode = m),
            ),
          ),
          if (filtered.isEmpty)
            SliverToBoxAdapter(
              child: _SectionSentence(
                colors: colors,
                text: 'No targets match the current filter.',
              ),
            )
          else
            SliverPadding(
              padding: _listPadding,
              sliver: SliverList.separated(
                key: const ValueKey('target_queue_list'),
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final target = filtered[index];
                  final visibility = visibilityByTarget[target.id];
                  return _QueueRow(
                    colors: colors,
                    target: target,
                    visibility: visibility,
                    canEdit: canEdit,
                  );
                },
              ),
            ),
        ],
        const SliverToBoxAdapter(
          child: SizedBox(height: SkotiqTokens.spaceMd),
        ),
      ],
    );
  }

  List<QueuedTarget> _applyFilter(
    List<QueuedTarget> input,
    Map<String, _TargetVisibility> visibility,
  ) {
    switch (_filterMode) {
      case _QueueFilterMode.all:
        return List.of(input);
      case _QueueFilterMode.aboveHorizon:
        return input
            .where((t) => visibility[t.id]?.aboveHorizon ?? false)
            .toList();
      case _QueueFilterMode.pendingOnly:
        return input.where((t) => t.isPending).toList();
    }
  }

  void _applySort(
    List<QueuedTarget> list,
    Map<String, _TargetVisibility> visibility,
  ) {
    switch (_sortMode) {
      case _QueueSortMode.userOrder:
        list.sort((a, b) => a.priority.compareTo(b.priority));
        return;
      case _QueueSortMode.score:
        // Score = clamped altitude (0..90) — a real night-window
        // scoring would require the scoring service, which itself
        // depends on moon/twilight providers and would over-rebuild
        // this list on every minute tick. Altitude is the dominant
        // term in the published score function (target_scoring.dart),
        // so it's a good practical proxy for the list view.
        list.sort((a, b) {
          final av = visibility[a.id]?.altitudeDeg ?? -90;
          final bv = visibility[b.id]?.altitudeDeg ?? -90;
          return bv.compareTo(av); // descending
        });
        return;
      case _QueueSortMode.altitude:
        list.sort((a, b) {
          final av = visibility[a.id]?.altitudeDeg ?? -90;
          final bv = visibility[b.id]?.altitudeDeg ?? -90;
          return bv.compareTo(av);
        });
        return;
      case _QueueSortMode.name:
        list.sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
        return;
      case _QueueSortMode.ra:
        list.sort((a, b) => a.coordinates.ra.compareTo(b.coordinates.ra));
        return;
    }
  }
}

// Section chrome

/// The padding both target lists take, so the sequence rows and the wishlist
/// rows share one left edge down the whole panel.
const EdgeInsets _listPadding =
    EdgeInsets.symmetric(horizontal: 8, vertical: 8);

/// An eyebrow label and the number of rows under it.
///
/// The panel's own title is gone with it: the toolbox's segmented control
/// already names this pane "Targets", and a second title under it said the
/// same word twice. What the sections need is the eyebrow that says which of
/// the two lists you are reading (06: panel and column labels).
class _SectionHeader extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final int count;

  const _SectionHeader({
    required this.colors,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final style = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text('$count', style: style),
        ],
      ),
    );
  }
}

/// One plain sentence under a section header: what the empty list is for, or
/// why the populated one is showing nothing. No icon and no headline above it
/// — an empty list inside a 280 px pane is a line of explanation, not a
/// full-height illustrated state (07).
class _SectionSentence extends StatelessWidget {
  final SkotiqColors colors;
  final String text;

  const _SectionSentence({required this.colors, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceSm,
      ),
      child: Text(
        text,
        style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
      ),
    );
  }
}

class _SortFilterBar extends StatelessWidget {
  final SkotiqColors colors;
  final _QueueSortMode sortMode;
  final _QueueFilterMode filterMode;
  final ValueChanged<_QueueSortMode> onSortChanged;
  final ValueChanged<_QueueFilterMode> onFilterChanged;

  const _SortFilterBar({
    required this.colors,
    required this.sortMode,
    required this.filterMode,
    required this.onSortChanged,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: _Dropdown<_QueueSortMode>(
              colors: colors,
              icon: LucideIcons.arrowDownUp,
              tooltip: 'Sort',
              value: sortMode,
              entries: _QueueSortMode.values
                  .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onSortChanged(v);
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _Dropdown<_QueueFilterMode>(
              colors: colors,
              icon: LucideIcons.filter,
              tooltip: 'Filter',
              value: filterMode,
              entries: _QueueFilterMode.values
                  .map((m) => DropdownMenuItem(value: m, child: Text(m.label)))
                  .toList(),
              onChanged: (v) {
                if (v != null) onFilterChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String tooltip;
  final T value;
  final List<DropdownMenuItem<T>> entries;
  final ValueChanged<T?> onChanged;

  const _Dropdown({
    required this.colors,
    required this.icon,
    required this.tooltip,
    required this.value,
    required this.entries,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: colors.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: AccessibleDropdown<T>(
                  value: value,
                  isDense: true,
                  isExpanded: true,
                  iconSize: 14,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textPrimary,
                  ),
                  dropdownColor: colors.surface,
                  items: entries,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// In this sequence

/// What a target's subtree plans to capture, in one phrase.
///
/// Reads the shared [plannedCaptureUnder] walk, so this row, the target card
/// in the tree and the library preview cannot disagree about the same target.
/// The honesty rules are the walk's own: an open-ended Smart Exposure has no
/// fixed count and is described as looping rather than as zero frames, and a
/// non-`count` loop makes the counted figure one pass rather than the night.
String targetPlanSummary(PlannedCapture planned) {
  if (planned.isEmpty) return 'No exposures yet';

  final parts = <String>[];
  if (planned.frames > 0) {
    final integration = DurationFormat.seconds(
      planned.integrationSecs,
      style: DurationStyle.compact,
    );
    parts.add(
      '${countLabel(planned.frames, 'frame')} \u00b7 $integration'
      '${planned.hasUnboundedRepeat ? ' per pass' : ''}',
    );
  }
  if (planned.hasOpenEndedLoop) {
    final budget = planned.openEndedBudgetSecs > 0
        ? 'looping up to ${DurationFormat.seconds(
            planned.openEndedBudgetSecs,
            style: DurationStyle.compact,
          )}'
        : 'looping until the window closes';
    parts.add(parts.isEmpty ? _sentenceCase(budget) : budget);
  }
  return parts.join(' + ');
}

String _sentenceCase(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

/// One target already in the loaded sequence.
///
/// Tapping it selects the header in the tree and scrolls it into view \u2014 the
/// same "select, then [revealSequenceRow] through the key registry"
/// jump the step finder and the minimap make, so the three navigations land
/// the row in the same place at the same speed.
class _InSequenceRow extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;
  final PlannedCapture planned;
  final bool isSelected;

  const _InSequenceRow({
    required this.colors,
    required this.node,
    required this.planned,
    required this.isSelected,
  });

  /// Land the row ~30 % from the top, matching the minimap and the run's own
  /// auto-follow, so its children are visible under it.
  static const double _revealAlignment = 0.3;

  void _select(BuildContext context, WidgetRef ref) {
    ref.read(multiSelectedNodeIdsProvider.notifier).clear();
    ref.read(selectedNodeIdProvider.notifier).state = node.id;

    // No key when the target sits inside a collapsed container: the row is not
    // built, so there is nothing to scroll to. Selection still lands, and the
    // inspector follows it \u2014 the same limit the step finder has.
    final target = ref.read(treeNodeKeyRegistryProvider)?[node.id];
    final anchor = target?.currentContext;
    if (anchor != null) {
      revealSequenceRow(
        anchor,
        duration: SkotiqTokens.durationSlow,
        alignment: _revealAlignment,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = node.targetName.isEmpty ? node.name : node.targetName;
    final unset = targetCoordinatesUnset(node);
    final summary = targetPlanSummary(planned);
    final chipLabels = unset
        ? const <String>['Not set']
        : <String>[
            CoordinateFormat.raHm(
              node.raHours,
              style: SexagesimalStyle.compactLetters,
              wrapHours: true,
            ),
            CoordinateFormat.decDm(
              node.decDegrees,
              style: SexagesimalStyle.compactLetters,
            ),
          ];

    return Semantics(
      button: true,
      selected: isSelected,
      label: <String>[name, ...chipLabels, summary].join(' \u00b7 '),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _select(context, ref),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? colors.primary
                      .withValues(alpha: SkotiqTokens.opacityStatusFill)
                  : colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(
                color: isSelected ? colors.primary : colors.border,
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.target, size: 12, color: colors.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        name,
                        style: SkotiqTypography.labelStrong
                            .copyWith(color: colors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: SkotiqTokens.spaceXs,
                  runSpacing: SkotiqTokens.spaceXs,
                  children: [
                    for (final label in chipLabels)
                      _TargetChip(
                        colors: colors,
                        label: label,
                        tone: unset ? colors.warning : null,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  summary,
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A coordinate (or "Not set") chip, cut to the ledger row's chip so the same
/// target reads the same in the panel and in the tree. [tone] null is a fact
/// about the target; a toned chip carries state, and "Not set" is `warning`
/// because exactly 0h/+0\u00b0 is a real point in Pisces and printing it as a
/// settled pointing is the bug [targetCoordinatesUnset] exists to prevent.
class _TargetChip extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final Color? tone;

  const _TargetChip({
    required this.colors,
    required this.label,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: SkotiqTokens.paddingXs,
      decoration: SkotiqDecorations.chip(colors, tone: tone),
      child: Text(
        label,
        style: SkotiqTypography.overline.copyWith(
          color: tone ?? colors.textSecondary,
        ),
        softWrap: false,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// Single queue row + draggable

class _QueueRow extends ConsumerWidget {
  final SkotiqColors colors;
  final QueuedTarget target;
  final _TargetVisibility? visibility;
  final bool canEdit;

  const _QueueRow({
    required this.colors,
    required this.target,
    required this.visibility,
    required this.canEdit,
  });

  TargetHeaderNode _buildNode() {
    return TargetHeaderNode(
      name: target.displayName,
      targetName: target.displayName,
      raHours: target.coordinates.ra,
      decDegrees: target.coordinates.dec,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final payload = TargetQueueDragPayload(
      queuedTarget: target,
      node: _buildNode(),
    );

    final card = _RowCard(
      colors: colors,
      target: target,
      visibility: visibility,
      onAddPressed: canEdit ? () => _addToSequence(context, ref) : null,
      onRemovePressed: () =>
          ref.read(targetQueueProvider.notifier).removeTarget(target.id),
    );

    if (!canEdit) {
      // While the sequencer is running we still let the user see the
      // queue but block the drag handle. The remove button stays live
      // because the queue is independent of the sequence (per the
      // brief — the queue is a wishlist).
      return Opacity(opacity: 0.75, child: card);
    }

    return LongPressDraggable<TargetQueueDragPayload>(
      data: payload,
      delay: const Duration(milliseconds: 150),
      hapticFeedbackOnStart: true,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: _dragFeedbackWidth(context),
          child: TargetHeaderCard(
            node: payload.node,
            colors: colors,
            isSelected: false,
            nodeStatus: null,
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      child: card,
    );
  }

  Future<void> _addToSequence(BuildContext context, WidgetRef ref) async {
    final node = _buildNode();
    final added = await addTargetHeaderWithPrompt(
      context: context,
      ref: ref,
      targetNode: node,
    );
    if (added && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${target.displayName} to sequence')),
      );
    }
  }
}

/// The visual card for a queue row — extracted so the same widget can
/// render both the actual list item and the drag-feedback ghost.
class _RowCard extends StatelessWidget {
  final SkotiqColors colors;
  final QueuedTarget target;
  final _TargetVisibility? visibility;
  final VoidCallback? onAddPressed;
  final VoidCallback? onRemovePressed;

  const _RowCard({
    required this.colors,
    required this.target,
    required this.visibility,
    required this.onAddPressed,
    required this.onRemovePressed,
  });

  @override
  Widget build(BuildContext context) {
    final v = visibility;
    final altText = v == null
        ? '—'
        : v.neverRises
            ? 'never rises'
            : '${v.altitudeDeg.toStringAsFixed(0)}°';
    final transitText = v?.transitAltitudeDeg == null
        ? '—'
        : '${v!.transitAltitudeDeg!.toStringAsFixed(0)}°';
    final setText = v?.setTime == null
        ? (v?.isCircumpolar == true ? 'never sets' : '—')
        : _formatTimeRemaining(v!.setTime!);

    final coordsText =
        'RA ${_formatHours(target.coordinates.ra)}  Dec ${_formatDegrees(target.coordinates.dec)}';

    final accent = target.isActive ? colors.primary : colors.border;
    return Container(
      decoration: BoxDecoration(
        color: target.isActive
            ? colors.primary.withValues(alpha: 0.06)
            : colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: accent),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 12, color: colors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  target.displayName,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onAddPressed != null)
                Tooltip(
                  message: 'Add to sequence',
                  child: InkWell(
                    onTap: onAddPressed,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(LucideIcons.plus,
                          size: 13, color: colors.primary),
                    ),
                  ),
                ),
              if (onRemovePressed != null)
                Tooltip(
                  message: 'Remove from queue',
                  child: InkWell(
                    onTap: onRemovePressed,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(LucideIcons.x,
                          size: 13, color: colors.textMuted),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            coordsText,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              color: colors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _Stat(
                colors: colors,
                label: 'Alt',
                value: altText,
                highlight: v?.aboveHorizon ?? false,
              ),
              const SizedBox(width: 8),
              _Stat(
                colors: colors,
                label: 'Max',
                value: transitText,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Stat(
                  colors: colors,
                  label: 'Sets',
                  value: setText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatHours(double ra) {
    final h = ra.floor();
    final m = ((ra - h) * 60).floor();
    return '${h.toString().padLeft(2, '0')}h${m.toString().padLeft(2, '0')}m';
  }

  static String _formatDegrees(double dec) {
    final sign = dec >= 0 ? '+' : '-';
    final absDec = dec.abs();
    final d = absDec.floor();
    final m = ((absDec - d) * 60).floor();
    return '$sign${d.toString().padLeft(2, '0')}°${m.toString().padLeft(2, '0')}\'';
  }

  static String _formatTimeRemaining(DateTime when) {
    final now = DateTime.now();
    final diff = when.difference(now);
    if (diff.isNegative) return 'set';
    final hours = diff.inHours;
    final minutes = diff.inMinutes.remainder(60);
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }
}

class _Stat extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final bool highlight;

  const _Stat({
    required this.colors,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize8,
            color: colors.textMuted,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          value,
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: highlight ? colors.primary : colors.textPrimary),
        ),
      ],
    );
  }
}
