// The Activity inspector tab — the run information that today renders inline
// under the tree row, moved into the side panel (spec §8).
//
// Content by node shape:
//   * leaf nodes — the same progress panel the tree paints
//     ([getProgressPanelForNode]), fed from LIVE values while the run
//     reports them and from [lastKnownNodeActivityProvider] afterwards, so a
//     finished node keeps its last true reading for the session instead of
//     falling back to "0 / 4 frames".
//   * [ExposureNode] — the spec'd frame grid (success / primary /
//     surfaceOverlay cells), `N of M done · capturing K` caption, total
//     integration, and the existing thumbnail strip. The grid is the
//     exposure's activity view: `_ExposureProgressPanel` already carries its
//     own grid + stat boxes, so rendering it here too would paint the same
//     facts twice.
//   * containers — subtree progress over [plannedCaptureUnder] plus
//     [sequenceProgressProvider]: done / total frames, a
//     [SkotiqProgressBar], and remaining time.
//   * nothing has run — one muted sentence, no illustration.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../plan_math.dart';
import 'exposure_node_thumbnail_strip.dart';
import 'node_progress_panels.dart';

/// What the subtree under a container node plans vs. has captured.
///
/// Totals come from [plannedCaptureUnder] so this count can never disagree
/// with the tree's duration chips, the toolbar total, or the library preview
/// by drifting into its own walk. "Done" is reconstructed from per-node
/// statuses and the exposure tally, under the same rule
/// `targetExecutionProgressProvider` documents: a loop resets its children
/// every pass and the wire carries no pass index, so per-pass statuses under
/// a repeat cannot be scaled into a run total — [completionUnknown] says so
/// instead of fabricating a ratio.
class SubtreeActivity {
  /// Planned frames with known counts, loop multipliers applied.
  final int plannedFrames;

  /// Frames attributed done. Only meaningful when [hasKnownCompletion].
  final int doneFrames;

  /// Planned integration seconds for [plannedFrames].
  final double plannedIntegrationSecs;

  /// True when a `loopUntilStopped` SmartExposure lives under this node —
  /// its frame count is open-ended, so [plannedFrames] excludes it.
  final bool hasOpenEndedLoop;

  /// True when a non-`count` loop wraps part of the subtree, making
  /// [plannedFrames] a single-pass floor rather than the plan.
  final bool hasUnboundedRepeat;

  /// True when done frames cannot be honestly derived (repeat loop whose
  /// frames cannot be attributed, or an open-ended capture plan).
  final bool completionUnknown;

  /// True once any node in the subtree has reported a status — separates
  /// "nothing ran" from "ran and did nothing".
  final bool ran;

  const SubtreeActivity({
    required this.plannedFrames,
    required this.doneFrames,
    required this.plannedIntegrationSecs,
    required this.hasOpenEndedLoop,
    required this.hasUnboundedRepeat,
    required this.completionUnknown,
    required this.ran,
  });

  double get fraction => hasKnownCompletion && plannedFrames > 0
      ? (doneFrames / plannedFrames).clamp(0.0, 1.0)
      : 0.0;

  bool get hasKnownCompletion => !completionUnknown;

  /// The pre-run / no-sequence value.
  static const empty = SubtreeActivity(
    plannedFrames: 0,
    doneFrames: 0,
    plannedIntegrationSecs: 0,
    hasOpenEndedLoop: false,
    hasUnboundedRepeat: false,
    completionUnknown: false,
    ran: false,
  );

  // Value equality lets the subtree provider's `.select` dedupe rebuilds:
  // a progress tick that lands on identical numbers must not rebuild the tab.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubtreeActivity &&
          other.plannedFrames == plannedFrames &&
          other.doneFrames == doneFrames &&
          other.plannedIntegrationSecs == plannedIntegrationSecs &&
          other.hasOpenEndedLoop == hasOpenEndedLoop &&
          other.hasUnboundedRepeat == hasUnboundedRepeat &&
          other.completionUnknown == completionUnknown &&
          other.ran == ran;

  @override
  int get hashCode => Object.hash(
        plannedFrames,
        doneFrames,
        plannedIntegrationSecs,
        hasOpenEndedLoop,
        hasUnboundedRepeat,
        completionUnknown,
        ran,
      );
}

/// Walk [sequence] under [rootId] and reconcile the plan
/// ([plannedCaptureUnder]) with what [progress] reports done.
///
/// Pure so the frame math is unit-testable without a widget tree.
SubtreeActivity subtreeActivityProgress(
  Sequence sequence,
  SequenceProgress progress,
  Map<String, NodeExposureTally> tallies,
  String rootId,
) {
  final planned = plannedCaptureUnder(sequence, rootId);

  var doneFrames = 0;
  var repeats = false;
  var ran = progress.nodeStatuses[rootId] != null;
  final visited = <String>{rootId};

  /// Per-pass frames for the three capture node types, mirroring the cases
  /// `plannedCaptureUnder` counts. Open-ended SmartExposure contributes none
  /// by definition.
  int perPassFrames(SequenceNode node) => switch (node) {
        ExposureNode n => n.count,
        SciencePhotometryNode n => n.count,
        SmartExposureNode n =>
          n.loopUntilStopped ? 0 : n.plans.fold(0, (s, p) => s + p.count),
        _ => 0,
      };

  void visit(SequenceNode node, bool underRepeat) {
    if (!node.isEnabled) return;
    if (progress.nodeStatuses[node.id] != null) ran = true;

    final frames = perPassFrames(node);
    if (frames > 0) {
      if (underRepeat) {
        // Per-node statuses reset every pass, so scaling them into a run
        // total invents a number. The run-level fallback below can still
        // recover when this subtree IS the whole plan.
        repeats = true;
      } else {
        final status = progress.nodeStatuses[node.id];
        if (status == NodeStatus.success) {
          doneFrames += frames;
        } else if (status == NodeStatus.running) {
          // The tally is authoritative when present; the percent-derived
          // partial is the fallback for emitters that send no structured
          // exposure progress.
          final tally = tallies[node.id];
          if (tally != null) {
            doneFrames += tally.captured.clamp(0, frames);
          } else {
            final pct =
                (progress.nodeProgressPercent[node.id] ?? 0).clamp(0, 100);
            doneFrames += (frames * pct / 100.0).floor();
          }
        }
      }
    }

    var childRepeat = underRepeat;
    if (node is LoopNode) {
      if (node.conditionType == LoopConditionType.count) {
        if ((node.repeatCount ?? 1) > 1) childRepeat = true;
      } else {
        childRepeat = true;
      }
    }
    for (final childId in node.childIds) {
      if (!visited.add(childId)) continue;
      final child = sequence.nodes[childId];
      if (child == null) continue;
      visit(child, childRepeat);
    }
  }

  final root = sequence.nodes[rootId];
  if (root != null) visit(root, false);

  var completionUnknown = repeats || planned.hasOpenEndedLoop;
  if (completionUnknown &&
      !planned.hasUnboundedRepeat &&
      !planned.hasOpenEndedLoop &&
      planned.frames > 0 &&
      planned.frames == sequence.totalExposures) {
    // When every frame the run plans sits under this subtree, the run-level
    // frame counter describes it exactly — and unlike node statuses it
    // already counts loop passes.
    doneFrames = progress.completedExposures.clamp(0, planned.frames);
    completionUnknown = false;
  }

  return SubtreeActivity(
    plannedFrames: planned.frames,
    doneFrames: doneFrames,
    plannedIntegrationSecs: planned.integrationSecs,
    hasOpenEndedLoop: planned.hasOpenEndedLoop,
    hasUnboundedRepeat: planned.hasUnboundedRepeat,
    completionUnknown: completionUnknown,
    ran: ran,
  );
}

/// Subtree activity for one container id.
///
/// The provider recomputes on every progress emission (the walk is cheap),
/// and callers subscribe through `.select` — [SubtreeActivity]'s value
/// equality then rebuilds the widget only when the numbers actually move,
/// instead of on every unrelated node's progress tick.
final _subtreeActivityProvider =
    Provider.family<SubtreeActivity, String>((ref, nodeId) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return SubtreeActivity.empty;
  return subtreeActivityProgress(
    sequence,
    ref.watch(sequenceProgressProvider),
    ref.watch(nodeExposureTallyProvider),
    nodeId,
  );
});

/// The node categories the tree treats as containers — the same list
/// `node_tree_view.dart` uses to decide which rows get children. The
/// Activity tab keys its subtree section off the identical set so a row and
/// its inspector agree about what "a container" is.
bool _isContainerNode(SequenceNode node) =>
    node is TargetHeaderNode ||
    node is LoopNode ||
    node is InstructionSetNode ||
    node is ParallelNode ||
    node is ConditionalNode ||
    node is RecoveryNode;

class NodeActivityTab extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final ScrollController? scrollController;
  final bool isMobile;

  const NodeActivityTab({
    super.key,
    required this.colors,
    required this.node,
    this.scrollController,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Per-node slices, not the whole progress object: every node in the run
    // ticks these maps, and watching them wholesale rebuilt this tab on
    // frames belonging to nodes it does not even name.
    final liveStatus = ref.watch(
      sequenceProgressProvider.select((p) => p.nodeStatuses[node.id]),
    );
    final livePercent = ref.watch(
      sequenceProgressProvider.select((p) => p.nodeProgressPercent[node.id]),
    );
    final liveDetail = ref.watch(
      sequenceProgressProvider.select((p) => p.nodeProgressDetail[node.id]),
    );
    final liveStructured = ref.watch(
      sequenceProgressProvider
          .select((p) => p.nodeProgressStructuredDetail[node.id]),
    );
    final liveFilter =
        ref.watch(sequenceProgressProvider.select((p) => p.currentFilter));
    final snapshot = ref.watch(
      lastKnownNodeActivityProvider.select((m) => m[node.id]),
    );
    final tally =
        ref.watch(nodeExposureTallyProvider.select((m) => m[node.id]));

    // Live values win; the snapshot is the memory of the last thing that was
    // true when the run cleared the per-node maps on the success path.
    final status = liveStatus ?? snapshot?.status;
    final percent = livePercent ?? snapshot?.percent;
    final detail = liveDetail ?? snapshot?.detail;
    final structured = liveStructured ?? snapshot?.structuredDetail;
    final runFilter = liveFilter ?? snapshot?.runFilter;

    final hasOwnActivity = status != null ||
        percent != null ||
        detail != null ||
        structured != null ||
        tally != null;

    final isContainer = _isContainerNode(node);
    final subtree = isContainer
        ? ref.watch(_subtreeActivityProvider(node.id).select((s) => s))
        : null;

    // A node that captured frames in an EARLIER session has thumbnails but no
    // live progress (the tally resets, the progress maps clear). The strip is
    // the honest record for that state, so it can render on its own — but the
    // "0 of N done" grid would be a false claim next to real frames, so the
    // full section is gated on THIS session's activity.
    // Local alias so `is ExposureNode` promotes — `widget.node` is a public
    // field, which Dart's promotion rules exclude.
    final selected = node;
    final hasThumbnails = selected is ExposureNode &&
        (ref
                .watch(exposureNodeThumbnailsProvider(selected.id))
                .valueOrNull
                ?.isNotEmpty ??
            false);

    final children = <Widget>[
      if (selected is ExposureNode) ...[
        if (hasOwnActivity)
          _ExposureActivitySection(
            colors: colors,
            node: selected,
            status: status,
            detail: detail,
            structuredDetail: structured,
            runFilter: runFilter,
            tally: tally,
          )
        else if (hasThumbnails)
          ExposureNodeThumbnailStrip(nodeId: node.id),
      ] else ...[
        if (hasOwnActivity)
          getProgressPanelForNode(
            node: node,
            colors: colors,
            progressPercent: percent ?? 0,
            progressDetail: detail,
            structuredProgressDetail: structured,
            nodeStatus: status,
            runFilter: runFilter,
            exposureTally: tally,
          ),
        if (subtree != null &&
            (subtree.plannedFrames > 0 ||
                subtree.hasOpenEndedLoop ||
                subtree.ran)) ...[
          if (hasOwnActivity) const SizedBox(height: SkotiqTokens.spaceMd),
          _SubtreeActivitySection(
            colors: colors,
            nodeId: node.id,
            subtree: subtree,
          ),
        ],
      ],
    ];

    final hasContent = children.any((w) => w is! SizedBox);
    return Material(
      type: MaterialType.transparency,
      child: hasContent
          ? SingleChildScrollView(
              controller: scrollController,
              padding: EdgeInsets.all(
                isMobile ? SkotiqTokens.spaceXl : SkotiqTokens.spaceLg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
              child: Text(
                'Nothing has run for this node yet.',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
    );
  }
}

/// Resolved frame accounting for one exposure node — the same precedence the
/// tree's `_ExposureProgressPanel` applies (dedicated tally over structured
/// detail over the parsed display string over the node's own count).
///
/// Kept as a pure value object so the pop animation can key off
/// [completedFrames] changes without re-deriving them per cell.
class _ExposureFrames {
  final int totalFrames;
  final int completedFrames;

  /// 1-based frame in flight, or 0 when none is exposing.
  final int currentFrame;

  /// Seconds per frame, for the integration total.
  final double durationSecs;

  const _ExposureFrames({
    required this.totalFrames,
    required this.completedFrames,
    required this.currentFrame,
    required this.durationSecs,
  });
}

class _ExposureActivitySection extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final ExposureNode node;
  final NodeStatus? status;
  final String? detail;
  final InstructionProgressDetail? structuredDetail;
  final String? runFilter;
  final NodeExposureTally? tally;

  const _ExposureActivitySection({
    required this.colors,
    required this.node,
    required this.status,
    required this.detail,
    required this.structuredDetail,
    required this.runFilter,
    required this.tally,
  });

  @override
  ConsumerState<_ExposureActivitySection> createState() =>
      _ExposureActivitySectionState();
}

class _ExposureActivitySectionState
    extends ConsumerState<_ExposureActivitySection> {
  /// Frame-landed bookkeeping: the cell index (0-based) that should play the
  /// 0.6 → 1.0 pop, and a stamp so the SAME index re-pops on a later pass
  /// (a re-run lands on cell 0 again, and a key that never changes would
  /// keep its settled end-state and skip the animation). [_seeded] marks
  /// "the baseline was taken from the resolved count" — without it, opening
  /// the tab on a node mid-run (6 captured, `_previousCaptured` still 0)
  /// reads as six frames landing at once and pops on mere selection.
  int _previousCaptured = 0;
  int _landedIndex = -1;
  int _landedStamp = 0;
  bool _seeded = false;

  @override
  void didUpdateWidget(_ExposureActivitySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Selection moved between two exposure nodes: the State object persists
    // (same runtime type in the same slot), so the previous node's captured
    // count would otherwise read as "a frame just landed" on this one.
    if (oldWidget.node.id != widget.node.id) {
      _seeded = false;
      _landedIndex = -1;
    }
  }

  _ExposureFrames _resolve() {
    final node = widget.node;
    final tally = widget.tally;
    final exposureDetail =
        widget.structuredDetail is ExposureInstructionProgressDetail
            ? widget.structuredDetail as ExposureInstructionProgressDetail
            : null;
    final parsed = parseExposureProgressDetail(widget.detail ?? '');
    final totalFrames =
        tally?.planned ?? exposureDetail?.total ?? parsed?.total ?? node.count;
    final liveFrame = exposureDetail?.frame ?? parsed?.frame ?? 0;
    final liveFrameIsDone =
        exposureDetail == null && (parsed?.frameCompleted ?? false);

    final int completed;
    final int current;
    if (tally != null) {
      completed = tally.captured.clamp(0, totalFrames);
      current = (widget.status == NodeStatus.running && completed < totalFrames)
          ? completed + 1
          : 0;
    } else {
      final isDone = widget.status == NodeStatus.success ||
          (liveFrameIsDone && liveFrame >= totalFrames);
      current = (isDone || liveFrameIsDone) ? 0 : liveFrame;
      // Clamp like `_ExposureProgressPanel.headerFrames` does: a node that
      // just entered `running` reports frame 0 with nothing parsed yet, and
      // `liveFrame - 1` would caption "-1 of 12 done".
      completed =
          (isDone ? totalFrames : (liveFrameIsDone ? liveFrame : liveFrame - 1))
              .clamp(0, totalFrames);
    }
    final durationSecs =
        exposureDetail != null && exposureDetail.durationSecs > 0
            ? exposureDetail.durationSecs
            : node.durationSecs;
    return _ExposureFrames(
      totalFrames: totalFrames,
      completedFrames: completed,
      currentFrame: current,
      durationSecs: durationSecs,
    );
  }

  String get _filterLabel {
    final own = widget.node.filter;
    if (own != null && own.isNotEmpty) return own;
    final live = widget.runFilter;
    if (live != null && live.isNotEmpty) return '$live (current)';
    return 'No filter set';
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final frames = _resolve();

    // The pop fires when the captured count INCREMENTS — a frame landing.
    // Rebuilds for unrelated reasons must not re-trigger it, so the trigger
    // is a plain field comparison, not an animation keyed off the count
    // itself (which would re-pop every settled cell on any rebuild).
    if (!_seeded) {
      // First build for this node (or after a node switch): adopt the
      // resolved count as the baseline so existing frames are simply true,
      // not "landed".
      _previousCaptured = frames.completedFrames;
      _seeded = true;
    } else if (frames.completedFrames < _previousCaptured) {
      // A new pass reset the count (the tally dropped its previous frames):
      // re-baseline so the first landing of THIS pass pops too.
      _previousCaptured = 0;
      _landedIndex = -1;
    }
    if (frames.completedFrames > _previousCaptured) {
      _landedIndex = frames.completedFrames - 1;
      _landedStamp++;
    }
    _previousCaptured = frames.completedFrames;

    // A detail line that is not an exposure frame line is another
    // instruction's report against the node (an error, a download notice) —
    // the only channel those reach the tab, so it stays.
    final detail = widget.detail;
    final showDetail = detail != null &&
        detail.isNotEmpty &&
        parseExposureProgressDetail(detail) == null;

    final caption = StringBuffer(
      '${frames.completedFrames} of ${frames.totalFrames} done',
    );
    if (frames.currentFrame > 0) {
      caption.write(' · capturing ${frames.currentFrame}');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              SkotiqIcons.camera,
              size: SkotiqTokens.iconXs,
              color: colors.success,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                'Exposure: $_filterLabel',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Row(
          children: [
            Expanded(
              child: Text(
                caption.toString(),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              DurationFormat.seconds(
                frames.durationSecs * frames.totalFrames,
                style: DurationStyle.compactTrimmed,
              ),
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ),
        if (showDetail) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            detail,
            style: SkotiqTypography.caption.copyWith(
              color: widget.status == NodeStatus.failure
                  ? colors.error
                  : colors.textMuted,
            ),
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        Semantics(
          label:
              '${frames.completedFrames} of ${frames.totalFrames} frames captured',
          // The label IS the announcement; without this the '+N' overflow
          // cell's text would be read a second time.
          excludeSemantics: true,
          child: _ActivityFrameGrid(
            colors: colors,
            totalFrames: frames.totalFrames,
            completedFrames: frames.completedFrames,
            currentFrame: frames.currentFrame,
            landedIndex: _landedIndex,
            landedStamp: _landedStamp,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        // The strip already collapses to nothing when the node has no frames
        // or the preference is off — it is safe to drop in unconditionally.
        ExposureNodeThumbnailStrip(nodeId: widget.node.id),
      ],
    );
  }
}

/// One cell per planned frame: success for captured, primary for the frame
/// in flight, `surfaceOverlay` for pending (spec §8). The frame-landed pop
/// (§9) lives here: the cell at [landedIndex] scales 0.6 → 1.0 once, keyed
/// by [landedStamp] so the same index can re-pop on a later pass.
class _ActivityFrameGrid extends StatelessWidget {
  final SkotiqColors colors;
  final int totalFrames;
  final int completedFrames;
  final int currentFrame;
  final int landedIndex;
  final int landedStamp;

  const _ActivityFrameGrid({
    required this.colors,
    required this.totalFrames,
    required this.completedFrames,
    required this.currentFrame,
    required this.landedIndex,
    required this.landedStamp,
  });

  /// Cap on individually-rendered cells — the same one the tree's frame grid
  /// uses. Above it, the last slot becomes a "+N" tally so a 200-frame plan
  /// doesn't paint 200 squares.
  static const int _maxCells = 20;

  @override
  Widget build(BuildContext context) {
    final frameSize = totalFrames > 10 ? 14.0 : 18.0;
    final overflow = totalFrames > _maxCells;
    final individualCells = overflow ? _maxCells - 1 : totalFrames;

    Widget cell(int frameNum) {
      final index = frameNum - 1;
      final isCompleted = frameNum <= completedFrames;
      final isCurrent = frameNum == currentFrame;
      final box = Container(
        width: frameSize,
        height: frameSize,
        decoration: BoxDecoration(
          color: isCompleted
              ? colors.success
              : isCurrent
                  ? colors.primary
                  : colors.surfaceOverlay,
          borderRadius: SkotiqTokens.borderRadiusXs,
          border: Border.all(
            color: isCompleted
                ? colors.success
                : isCurrent
                    ? colors.primary
                    : colors.border,
            width: isCurrent ? 2 : 1,
          ),
        ),
      );
      if (index == landedIndex) {
        // Keyed on the landing stamp: `TweenAnimationBuilder` runs its tween
        // once per key, which is exactly the "pops once" the spec asks for.
        return TweenAnimationBuilder<double>(
          key: ValueKey('frame-landed-$index-$landedStamp'),
          tween: Tween(begin: 0.6, end: 1.0),
          duration: animationDuration(context, SkotiqTokens.durationQuick),
          curve: SkotiqTokens.curveStandard,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: box,
        );
      }
      return box;
    }

    final children = <Widget>[
      for (var i = 0; i < individualCells; i++) cell(i + 1),
    ];

    if (overflow) {
      final remaining = totalFrames - individualCells;
      final remainingCompleted =
          (completedFrames - individualCells).clamp(0, remaining);
      final allRemainingDone = remainingCompleted >= remaining;
      children.add(
        Container(
          height: frameSize,
          constraints: BoxConstraints(minWidth: frameSize * 1.6),
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceXs,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: allRemainingDone
                ? colors.success.withValues(alpha: 0.18)
                : colors.surfaceOverlay,
            borderRadius: SkotiqTokens.borderRadiusXs,
            border: Border.all(
              color: allRemainingDone ? colors.success : colors.border,
            ),
          ),
          child: Text(
            '+$remaining',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize9,
              fontWeight: FontWeight.w700,
              color: allRemainingDone ? colors.success : colors.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: SkotiqTokens.spaceXs,
      runSpacing: SkotiqTokens.spaceXs,
      children: children,
    );
  }
}

/// Subtree rollup for containers: planned frames vs done, a progress bar,
/// and a remaining-time estimate that shares the tree's rollup model.
class _SubtreeActivitySection extends ConsumerWidget {
  final SkotiqColors colors;
  final String nodeId;
  final SubtreeActivity subtree;

  const _SubtreeActivitySection({
    required this.colors,
    required this.nodeId,
    required this.subtree,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rollup = ref.watch(nodeRollupDurationProvider(nodeId));
    final hasPlan = subtree.plannedFrames > 0 || subtree.hasOpenEndedLoop;

    if (!subtree.ran ||
        subtree.completionUnknown ||
        subtree.plannedFrames == 0) {
      // Pre-run, a repeat/open-ended plan whose per-pass numbers cannot form
      // a ratio, or a subtree with no capture work at all: the honest
      // statement is the plan, not a 0% bar (and "0 / 0 frames" is noise).
      final frameLabel = subtree.hasUnboundedRepeat || subtree.hasOpenEndedLoop
          ? '${subtree.plannedFrames}+ frames planned'
          : '${subtree.plannedFrames} frames planned';
      return Semantics(
        label: '$frameLabel, estimated ${formatRollupDuration(rollup)}',
        // The wrapped Text would otherwise announce the same sentence again.
        excludeSemantics: true,
        child: Text(
          hasPlan
              ? '$frameLabel · ${formatRollupDuration(rollup)}'
              : 'No exposures planned under this node.',
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textMuted,
          ),
        ),
      );
    }

    final fraction = subtree.fraction;
    final remaining =
        Duration(seconds: (rollup.inSeconds * (1 - fraction)).round());
    final summary = '${subtree.doneFrames} / ${subtree.plannedFrames} frames';
    final remainingLabel = '${formatRollupDuration(remaining)} left';

    return Semantics(
      label: '$summary captured, $remainingLabel',
      // The label summarizes; the inner Texts would announce the same facts
      // a second time (and the progress bar adds its own reading).
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.layers,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'Subtree',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: Text(
                  summary,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                remainingLabel,
                style: SkotiqTypography.monoSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqProgressBar(
            value: fraction,
            // Null keeps the progress bar's own default; zero is the
            // only override the accessibility setting asks for.
            animationDuration:
                animationsDisabled(context) ? Duration.zero : null,
          ),
        ],
      ),
    );
  }
}
