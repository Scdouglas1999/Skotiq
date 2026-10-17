part of '../node_progress_panels.dart';

class _ExposureProgressPanel extends StatelessWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;
  final InstructionProgressDetail? structuredDetail;
  final ExposureNode node;

  /// The node finished all its frames. The live per-frame detail is cleared on
  /// the success path, so without this the card fell back to frame 0 and read
  /// "0 / 4 frames" directly above the four thumbnails it had just captured.
  final bool isComplete;

  /// The node is exposing right now — used only to decide whether a frame is
  /// in flight above the frames already captured.
  final bool isRunning;

  /// Frames this node actually captured, from a DEDICATED channel no other
  /// instruction can overwrite. `SequenceProgress.nodeProgressDetail` is a
  /// single slot shared with every instruction reporting against the node —
  /// `emit_budget_progress` overwrites it a millisecond after a burst finishes
  /// — so a count parsed out of it cannot tell "captured everything" from
  /// "captured nothing".
  final NodeExposureTally? tally;

  /// The filter the run is imaging through, when the node itself names none.
  ///
  /// A node with `filter == null` does not image unfiltered — it images
  /// through whatever is in the wheel, and every other surface says so: the
  /// telemetry strip reads `Filter: R`, the thumbnails `Filter R`, the files on
  /// disk `M42-TEST_R_0001.fits`, the session report a single `R` row. This
  /// header must not be the one place that calls it "No Filter", two rows under
  /// a target rollup reading "R 180s".
  final String? runFilter;

  const _ExposureProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
    this.structuredDetail,
    required this.node,
    this.isComplete = false,
    this.isRunning = false,
    this.runFilter,
    this.tally,
  });

  /// What to call the filter on this card. The node's own choice wins; the
  /// run's filter is the fallback and is marked as inherited rather than
  /// presented as if the node had asked for it.
  String get _filterLabel {
    final own = node.filter;
    if (own != null && own.isNotEmpty) return own;
    final live = runFilter;
    if (live != null && live.isNotEmpty) return '$live (current)';
    return 'No filter set';
  }

  @override
  Widget build(BuildContext context) {
    final exposureDetail = structuredDetail is ExposureInstructionProgressDetail
        ? structuredDetail as ExposureInstructionProgressDetail
        : null;
    // The node's own progress line, in EITHER of the two wordings the executor
    // writes: "Frame 3/4 (R)" while a frame is exposing, "Completed 3/4" once
    // it lands. The LAST line a successful run leaves behind is the second, so
    // a card that only understands the first parses 4 captured frames as none
    // and reads "0 / 4 frames" over four thumbnails. One vocabulary:
    // skotiq_core's [parseExposureProgressDetail], round-trip-tested
    // against the formatters the executor uses.
    //
    // The typed ExposureInstructionProgressDetail is still preferred when
    // present; it always describes a frame in flight.
    final parsedDetail = parseExposureProgressDetail(detail);
    final tallied = tally;
    final totalFrames = tallied?.planned ??
        exposureDetail?.total ??
        parsedDetail?.total ??
        node.count;
    final liveFrame = exposureDetail?.frame ?? parsedDetail?.frame ?? 0;
    final liveFrameIsDone =
        exposureDetail == null && (parsedDetail?.frameCompleted ?? false);

    final int completedFrames;
    final int currentFrame;
    final int headerFrames;
    if (tallied != null) {
      // The authoritative count. It survives the display string being
      // overwritten by another instruction, so it is what the card counts with
      // whenever it exists; the string paths below remain for hosts that emit
      // no per-node exposure progress at all.
      completedFrames = tallied.captured.clamp(0, totalFrames);
      headerFrames = completedFrames;
      currentFrame = (isRunning && completedFrames < totalFrames)
          ? completedFrames + 1
          : 0;
    } else {
      // A node is finished when its status says so OR when its own last line
      // reports the final planned frame captured. The status does not always
      // reach this card, so the line the run left behind is a second,
      // independent witness.
      final isDone =
          isComplete || (liveFrameIsDone && liveFrame >= totalFrames);
      // A finished node — and a node between frames — has nothing in flight.
      currentFrame = (isDone || liveFrameIsDone) ? 0 : liveFrame;
      completedFrames =
          isDone ? totalFrames : (liveFrameIsDone ? liveFrame : liveFrame - 1);
      headerFrames = isDone ? totalFrames : liveFrame;
    }
    final durationSecs =
        exposureDetail != null && exposureDetail.durationSecs > 0
            ? exposureDetail.durationSecs
            : node.durationSecs;

    return _ProgressPanelContainer(
      colors: colors,
      accentColor: colors.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(SkotiqIcons.camera, size: 16, color: colors.success),
              const SizedBox(width: 8),
              // The filter name is the elastic half of this header: the frame
              // counter is the number the operator is watching and must never
              // be the thing that gets pushed off the panel. Both were rigid,
              // so a long filter name or a scaled-up font size overflowed the
              // row instead of truncating the title.
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
              const SizedBox(width: 8),
              Text(
                '$headerFrames / $totalFrames frames',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize10,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Frame grid
          _FrameGrid(
            colors: colors,
            totalFrames: totalFrames,
            completedFrames: completedFrames,
            currentFrame: currentFrame,
          ),
          const SizedBox(height: 12),

          // Duration info
          Row(
            children: [
              _StatBox(
                colors: colors,
                label: 'Duration',
                value: durationSecs.toStringAsFixed(0),
                unit: 's',
                color: colors.success,
              ),
              const SizedBox(width: 12),
              _StatBox(
                colors: colors,
                label: 'Total',
                value: (durationSecs * totalFrames / 60).toStringAsFixed(1),
                unit: 'min',
                color: colors.info,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FrameGrid extends StatelessWidget {
  final SkotiqColors colors;
  final int totalFrames;
  final int completedFrames;
  final int currentFrame;

  const _FrameGrid({
    required this.colors,
    required this.totalFrames,
    required this.completedFrames,
    required this.currentFrame,
  });

  /// Cap on individually-rendered cells. Above this we render the first
  /// [_maxCells]-1 frames plus a single "+N" summary cell so a 200-frame
  /// exposure node doesn't paint 200 squares.
  static const int _maxCells = 20;

  @override
  Widget build(BuildContext context) {
    final frameSize = totalFrames > 10 ? 14.0 : 18.0;
    final overflow = totalFrames > _maxCells;
    // When overflowing, show the first 19 frames as real cells and reserve
    // the 20th slot for a "+N" tally of the remaining frames.
    final individualCells = overflow ? _maxCells - 1 : totalFrames;

    Widget cell(int frameNum) {
      final isCompleted = frameNum <= completedFrames;
      final isCurrent = frameNum == currentFrame;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: frameSize,
        height: frameSize,
        decoration: BoxDecoration(
          color: isCompleted
              ? colors.success
              : isCurrent
                  ? colors.info
                  : colors.surface,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: Border.all(
            color: isCompleted
                ? colors.success
                : isCurrent
                    ? colors.info
                    : colors.border,
            width: isCurrent ? 2 : 1,
          ),
        ),
      );
    }

    final children = <Widget>[
      for (var i = 0; i < individualCells; i++) cell(i + 1),
    ];

    if (overflow) {
      final remaining = totalFrames - individualCells;
      // How many of the remaining (hidden) frames are already done — colours
      // the tally green once the run has advanced past the shown cells.
      final remainingCompleted =
          (completedFrames - individualCells).clamp(0, remaining);
      final allRemainingDone = remainingCompleted >= remaining;
      // Slightly wider than a single cell so the "+N" label fits.
      children.add(
        Container(
          height: frameSize,
          constraints: BoxConstraints(minWidth: frameSize * 1.6),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: allRemainingDone
                ? colors.success.withValues(alpha: 0.18)
                : colors.surface,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
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

    return Wrap(spacing: 4, runSpacing: 4, children: children);
  }
}
