import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/frame_exclusion_badge.dart';
import '../../../widgets/frame_thumbnail_loader.dart';
import '../../../widgets/saved_frame/saved_frame_viewer.dart';
import 'package:skotiq_core/models.dart';
import '../../../services/night_session/night_session_frames.dart';

/// The "Session frames" tab: tonight's light frames as thumbnails, grouped by
/// target and filter, newest group and newest frame first, each with its
/// verdict, HFR and star count.
///
/// The rows are the ones Tonight's frame strip shows (the whole observing
/// night), so the two screens never count different frames.
class ImagingSessionFrames extends ConsumerWidget {
  const ImagingSessionFrames({super.key});

  /// A tile's width; the grid fits as many as the pane holds.
  static const double tileWidth = 168;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(nightSessionLightRowsProvider);
    if (rows.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'No frames yet',
          body: 'Tonight\'s light frames appear here as they are captured.',
        ),
      );
    }
    final targetNames = <int, String>{
      for (final target
          in ref.watch(allDbTargetsProvider).valueOrNull ?? const [])
        target.id: target.name,
    };
    final groups = sessionFrameGroups(rows);
    final shown = <SessionFrame>[for (final group in groups) ...group.frames];
    void open(SessionFrame frame) => SavedFrameViewer.show(
          context,
          frames: [for (final f in shown) _viewerEntry(context, f)],
          initialIndex: shown.indexOf(frame),
        );

    // Lazy, per group: a night holds hundreds of frames, and every tile built
    // asks the host for its thumbnail. Built all at once (a Wrap), a linked
    // phone sent a thousand requests and the host refused them (429).
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: SizedBox(height: SkotiqTokens.spaceLg),
        ),
        for (final group in groups) ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceLg,
            ),
            sliver: SliverToBoxAdapter(
              child: _GroupHead(
                group: group,
                targetName: targetNames[group.targetId],
              ),
            ),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: SkotiqTokens.spaceSm),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceLg,
            ),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                const gap = SkotiqTokens.spaceSm;
                final width = constraints.crossAxisExtent;
                final columns = math.max(
                  1,
                  ((width + gap) / (ImagingSessionFrames.tileWidth + gap))
                      .floor(),
                );
                final tileWidth = (width - gap * (columns - 1)) / columns;
                // The 3:2 thumbnail plus the caption row under it.
                final captionHeight =
                    MediaQuery.textScalerOf(context).scale(16) +
                        SkotiqTokens.spaceXs * 2 +
                        2;
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    mainAxisExtent: tileWidth * 2 / 3 + captionHeight,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final frame = group.frames[index];
                      return _FrameTile(
                        key: ValueKey<int>(frame.row.id),
                        frame: frame,
                        onOpen: () => open(frame),
                      );
                    },
                    childCount: group.frames.length,
                  ),
                );
              },
            ),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: SkotiqTokens.spaceXl),
          ),
        ],
      ],
    );
  }
}

/// [frame] as the saved-frame viewer names it.
SavedFrameEntry _viewerEntry(BuildContext context, SessionFrame frame) {
  final row = frame.row;
  final exclusion = frameExclusionKindOf(row.rejectionReason);
  final hfr = row.hfr;
  final stars = row.starCount;
  final filter = row.filter;
  return SavedFrameEntry(
    frame: SavedFrameRef(
      imageId: row.id,
      hostPath: row.filePath,
      capturedAt: row.capturedAt,
    ),
    title: [
      '#${frame.number}',
      if (filter != null && filter.isNotEmpty) filter,
      QuantityFormat.exposure(row.exposureDuration, space: false),
    ].join(' · '),
    time: ClockFormat.hms(row.capturedAt.toLocal()),
    status: [
      _verdict(context, row, exclusion),
      if (hfr != null) 'HFR ${hfr.toStringAsFixed(2)}',
      if (stars != null) '$stars stars',
    ].join(' · '),
    accepted: row.isAccepted,
  );
}

String _verdict(
  BuildContext context,
  DbCapturedImage row,
  FrameExclusionKind? exclusion,
) =>
    exclusion != null
        ? frameExclusionLabel(context, exclusion)
        : row.isAccepted
            ? 'Kept'
            : 'Rejected';

/// A light frame with its place in the night ("#43").
@immutable
class SessionFrame {
  const SessionFrame(this.row, this.number);

  final DbCapturedImage row;
  final int number;
}

/// Frames of one target through one filter.
@immutable
class SessionFrameGroup {
  const SessionFrameGroup({
    required this.targetId,
    required this.filter,
    required this.frames,
  });

  final int? targetId;
  final String? filter;

  /// Newest first.
  final List<SessionFrame> frames;

  int get keptCount => frames.where((f) => f.row.isAccepted).length;

  double get keptSeconds => frames
      .where((f) => f.row.isAccepted)
      .fold(0, (sum, f) => sum + f.row.exposureDuration);
}

/// [lights] (oldest first) grouped by target and filter, the group with the
/// newest frame first.
@visibleForTesting
List<SessionFrameGroup> sessionFrameGroups(List<DbCapturedImage> lights) {
  final byKey = <(int?, String?), List<SessionFrame>>{};
  for (var i = lights.length - 1; i >= 0; i--) {
    final row = lights[i];
    byKey.putIfAbsent(
        (row.targetId, row.filter), () => []).add(SessionFrame(row, i + 1));
  }
  return [
    for (final entry in byKey.entries)
      SessionFrameGroup(
        targetId: entry.key.$1,
        filter: entry.key.$2,
        frames: entry.value,
      ),
  ];
}

class _GroupHead extends StatelessWidget {
  const _GroupHead({required this.group, required this.targetName});

  final SessionFrameGroup group;
  final String? targetName;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final filter = group.filter;
    final title = [
      targetName ?? 'No target',
      if (filter != null && filter.isNotEmpty) filter,
    ].join(' · ');
    final count = group.frames.length;
    final kept = group.keptCount;
    final summary = [
      '$count ${count == 1 ? 'frame' : 'frames'}',
      if (kept != count) '$kept kept',
      DurationFormat.seconds(group.keptSeconds),
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.sectionTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Text(
          summary,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _FrameTile extends ConsumerStatefulWidget {
  const _FrameTile({super.key, required this.frame, required this.onOpen});

  final SessionFrame frame;

  /// Shows the frame at full resolution.
  final VoidCallback onOpen;

  @override
  ConsumerState<_FrameTile> createState() => _FrameTileState();
}

class _FrameTileState extends ConsumerState<_FrameTile> {
  late Future<Uint8List?> _bytes = _load();

  @override
  void didUpdateWidget(covariant _FrameTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.row.id != widget.frame.row.id) _bytes = _load();
  }

  Future<Uint8List?> _load() => fetchFrameThumbnailBytes(
        ref,
        widget.frame.row.id,
        source: 'ImagingSessionFrames',
      );

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final row = widget.frame.row;
    final exclusion = frameExclusionKindOf(row.rejectionReason);
    final rejected = !row.isAccepted;
    final hfr = row.hfr;
    final stars = row.starCount;
    final time = ClockFormat.hms(row.capturedAt.toLocal());
    final verdict = _verdict(context, row, exclusion);
    final metrics = [
      if (hfr != null) 'HFR ${hfr.toStringAsFixed(2)}',
      if (stars != null) '$stars ★',
    ].join(' · ');

    return Semantics(
      container: true,
      button: true,
      enabled: true,
      onTap: widget.onOpen,
      label: [
        'Frame ${widget.frame.number}',
        verdict,
        if (hfr != null) 'HFR ${hfr.toStringAsFixed(2)}',
        if (stars != null) '$stars stars',
        time,
      ].join(', '),
      excludeSemantics: true,
      child: SizedBox(
        child: InkWell(
          onTap: widget.onOpen,
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: Container(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: SkotiqTokens.borderRadiusSm,
              border: Border.all(color: colors.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AspectRatio(
                  aspectRatio: 3 / 2,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(
                        opacity: rejected ? SkotiqTokens.opacityMuted : 1,
                        child: FrameThumbnail(
                          bytesFuture: _bytes,
                          fallbackFilePath: row.filePath,
                          colors: colors,
                        ),
                      ),
                      Positioned(
                        top: SkotiqTokens.spaceXs,
                        left: SkotiqTokens.spaceXs,
                        child: _NumberChip(number: widget.frame.number),
                      ),
                      Positioned(
                        top: SkotiqTokens.spaceXs,
                        right: SkotiqTokens.spaceXs,
                        child: exclusion != null
                            ? FrameExclusionBadge(
                                kind: exclusion,
                                compact: true,
                              )
                            : _VerdictDot(rejected: rejected),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SkotiqTokens.spaceSm,
                    vertical: SkotiqTokens.spaceXs,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          metrics,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.withTabular(
                            SkotiqTypography.captionSm.copyWith(
                              color: rejected
                                  ? colors.error
                                  : colors.textSecondary,
                            ),
                          ),
                        ),
                      ),
                      Text(
                        time,
                        style: SkotiqTypography.withTabular(
                          SkotiqTypography.captionSm.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberChip extends StatelessWidget {
  const _NumberChip({required this.number});

  final int number;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceXs),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: SkotiqTokens.opacityMuted),
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Text(
        '#$number',
        style: SkotiqTypography.withTabular(
          SkotiqTypography.captionSm.copyWith(color: colors.textPrimary),
        ),
      ),
    );
  }
}

/// Green for a kept frame, red for a rejected one; the tile's label says
/// which in words.
class _VerdictDot extends StatelessWidget {
  const _VerdictDot({required this.rejected});

  final bool rejected;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Tooltip(
      message: rejected ? 'Rejected' : 'Kept',
      excludeFromSemantics: true,
      child: StatusDot(
        color: rejected ? colors.error : colors.success,
      ),
    );
  }
}
