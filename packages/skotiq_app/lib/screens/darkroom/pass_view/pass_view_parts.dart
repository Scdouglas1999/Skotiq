// Pieces of the pass view: the section frame, the header with the status line
// and the clocks, the image well, and the status sentence.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_charts.dart';

final NumberFormat _grouped = NumberFormat('#,##0', 'en_US');

String passGrouped(num v) => _grouped.format(v);

/// A titled block with a muted note on the right and a hairline under it,
/// the same frame the Tonight plan column uses.
class PassSection extends StatelessWidget {
  const PassSection({
    super.key,
    required this.title,
    required this.child,
    this.note,
    this.divider = true,
    this.padding = const EdgeInsets.symmetric(
      horizontal: SkotiqTokens.spaceMd,
      vertical: 10,
    ),
  });

  final String title;
  final String? note;
  final Widget child;
  final bool divider;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: colors.border))
            : const Border(),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: SkotiqTypography.labelStrong
                        .copyWith(color: colors.textPrimary),
                    maxLines: 1,
                  ),
                ),
                if (note != null) ...<Widget>[
                  const SizedBox(width: SkotiqTokens.spaceMd),
                  Expanded(
                    child: Text(
                      note!,
                      textAlign: TextAlign.end,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

/// The status sentence: what the running stage is doing, with the numbers it
/// measured on the sub it just finished.
String passStatusSentence(PassSnapshot s) {
  final tl = s.timeline;
  if (s.ended) {
    final failure = tl.failure;
    if (failure != null) return 'The pass stopped: $failure';
    return 'The pass finished';
  }
  final active = s.activeSpan;
  if (active == null) {
    return s.lanes.isEmpty ? 'Starting the pass' : 'Between stages';
  }
  final (lane, span) = active;
  if (lane == null) {
    switch (span.stage) {
      case PassStage.align:
        final lead = s.lanes.isEmpty ? 'the first channel' : s.lanes.first.lane;
        final placed = <PassChannelFit>[
          for (final f in tl.channelFits)
            if (f.at <= s.elapsed) f,
        ];
        if (placed.isEmpty) return 'Aligning the channels to $lead';
        final f = placed.last;
        if (f.failure != null) {
          return 'Aligning the channels to $lead · ${f.lane} could not be placed';
        }
        return 'Aligning the channels to $lead · ${f.lane}: '
            '${f.inliers == null ? '' : '${passGrouped(f.inliers!)} stars matched, '}'
            'shift ${f.shift?.toStringAsFixed(1) ?? '?'} px';
      case PassStage.combine:
        return 'Combining ${s.lanes.map((l) => l.lane).join(', ')} into color';
      case PassStage.draft:
        final total = span.total;
        final done = span.doneAt(s.elapsed);
        return total == null
            ? 'Drafting ${tl.target ?? 'the masters'}'
            : 'Drafting · ${done + 1 > total ? total : done + 1} of $total';
      default:
        return span.stage.verb;
    }
  }
  final total = span.total ?? lane.subCount;
  final done = span.doneAt(s.elapsed);
  final counted = span.stage == PassStage.calibrate ||
      span.stage == PassStage.register ||
      span.stage == PassStage.normalize;
  final counter = counted && total > 0
      ? ' · ${done + 1 > total ? total : done + 1} of $total'
      : '';
  final head = '${span.stage.verb} ${lane.lane}$counter';
  switch (span.stage) {
    case PassStage.calibrate:
      final note = lane.calibrationNote;
      return note == null ? head : '$head · $note';
    case PassStage.register:
      if (done == 0) {
        return '${span.stage.verb} ${lane.lane} · picking the reference sub';
      }
      final f = lane.frames[done - 1];
      if (!f.accepted) {
        return '$head · sub ${f.index} rejected: '
            '${passReadableReason(f.reason ?? 'no reason recorded')}';
      }
      final parts = <String>[
        if (f.stars != null) '${passGrouped(f.stars!)} stars',
        if (f.shift != null && !f.isReference)
          'shift ${f.shift!.toStringAsFixed(1)} px',
        if (f.rmsPx != null && !f.isReference)
          'residual ${f.rmsPx!.toStringAsFixed(2)} px',
        if (f.isReference) 'the reference',
      ];
      return parts.isEmpty
          ? head
          : '$head · sub ${f.index}: ${parts.join(', ')}';
    case PassStage.normalize:
      final depths = s.depthsOf(lane).where((d) => d.noise != null).toList();
      return depths.isEmpty
          ? head
          : '$head · noise ${depths.last.noise!.toStringAsFixed(1)} ADU '
              'at ${depths.last.depth} subs';
    case PassStage.integrate:
      final n = span.total ?? lane.frames.where((f) => f.accepted).length;
      return '$head · ${n > 0 ? '$n subs, ' : ''}rejecting outlying pixels';
    case PassStage.write:
      return '$head master';
    case PassStage.finish:
      return 'Solving and saving the ${lane.lane} master';
    default:
      return head;
  }
}

/// The top bar: what the pass is, the status sentence, and the clocks. A
/// finished pass shows when it ran instead of what is left.
class PassHeader extends StatelessWidget {
  const PassHeader({
    super.key,
    required this.snapshot,
    this.compact = false,
    this.onStop,
  });

  final PassSnapshot snapshot;
  final bool compact;

  /// Stops the pass; null hides Stop (a record, or nothing to stop).
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tl = snapshot.timeline;
    final status = passStatusSentence(snapshot);
    final ended = snapshot.ended;
    final (remaining, complete) = snapshot.remaining;
    final clocks = <Widget>[
      _Clock(
        label: ended ? 'Took' : 'Elapsed',
        value: passClock(snapshot.elapsed),
      ),
      if (ended)
        _Clock(
          label: 'Started',
          value: DateFormat('MMM d HH:mm').format(tl.startedAt),
        )
      else
        _Clock(
          label: complete ? 'Remaining' : 'Remaining, at least',
          value: passClock(remaining),
        ),
    ];
    final stop = onStop == null || ended
        ? null
        : SkotiqButton(
            label: 'Stop',
            variant: ButtonVariant.secondary,
            size: compact ? ButtonSize.small : ButtonSize.medium,
            onPressed: onStop,
          );
    final title = Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: ended ? 'Pass record' : 'Pass',
            style: (compact
                    ? SkotiqTypography.labelStrong
                    : SkotiqTypography.sectionTitle)
                .copyWith(color: colors.textPrimary),
          ),
          if (tl.target != null)
            TextSpan(
              text: '  ${tl.target}',
              style: SkotiqTypography.labelStrong
                  .copyWith(color: colors.textSecondary),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final failed = ended && tl.failure != null;
    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: StatusDot(
            color: failed
                ? colors.error
                : (ended ? colors.success : colors.primary),
            size: 7,
            live: false,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            status,
            style: SkotiqTypography.label.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
    return Container(
      padding: EdgeInsets.fromLTRB(
        compact ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
        10,
        compact ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
        10,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                title,
                const SizedBox(height: 6),
                line,
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: Wrap(
                        spacing: 20,
                        runSpacing: 6,
                        children: clocks,
                      ),
                    ),
                    if (stop != null) stop,
                  ],
                ),
              ],
            )
          : Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[title, const SizedBox(height: 4), line],
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceLg),
                for (final c in clocks) ...<Widget>[
                  c,
                  const SizedBox(width: 24),
                ],
                if (stop != null) stop,
              ],
            ),
    );
  }
}

class _Clock extends StatelessWidget {
  const _Clock({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          value,
          style: SkotiqTypography.monoSm.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          label,
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// The image at its own aspect on a dark well, with what it is under it. The
/// file is decoded at the well's width, never at the master's.
class PassImageWell extends StatelessWidget {
  const PassImageWell({
    super.key,
    required this.path,
    required this.caption,
    this.aspect = 4 / 3,
  });

  final String? path;
  final String caption;
  final double aspect;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final file = path;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AspectRatio(
          aspectRatio: aspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // The well stays dark in both themes: it is where an
              // astronomical image sits.
              color: SkotiqColors.dark.well,
              border: Border.all(color: colors.border),
            ),
            child: file == null
                ? Center(
                    child: Text(
                      caption,
                      style: SkotiqTypography.caption
                          .copyWith(color: SkotiqColors.dark.textMuted),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, c) => Semantics(
                      image: true,
                      label: caption,
                      child: PassImageSource.of(context)?.call(file) ??
                          Image.file(
                            File(file),
                            key: ValueKey<String>(file),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            cacheWidth: (c.maxWidth *
                                    MediaQuery.devicePixelRatioOf(context))
                                .round()
                                .clamp(64, 2048),
                            errorBuilder: (context, error, stack) => Center(
                              child: Text(
                                'The preview file could not be read',
                                style: SkotiqTypography.caption.copyWith(
                                    color: SkotiqColors.dark.textMuted),
                              ),
                            ),
                          ),
                    ),
                  ),
          ),
        ),
        if (file != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            caption,
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// Draws pass previews from somewhere other than the file system, for a
/// render that cannot wait on real file reads.
class PassImageSource extends InheritedWidget {
  const PassImageSource(
      {super.key, required this.builder, required super.child});

  /// The image for a preview path, or null to read the file.
  final Widget? Function(String path) builder;

  static Widget? Function(String path)? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PassImageSource>()?.builder;

  @override
  bool updateShouldNotify(PassImageSource oldWidget) =>
      oldWidget.builder != builder;
}

/// A small lane key: a square in the lane's color and its name.
class PassFilterKey extends StatelessWidget {
  const PassFilterKey(this.lane, {super.key, this.size = 8});
  final String lane;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: size,
          height: size,
          color: passFilterColor(lane, colors),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            lane,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.monoSm.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// `24 m`, `1 h 05 m` of integration.
String passIntegration(double seconds) {
  final m = (seconds / 60).round();
  if (m < 60) return '$m m';
  return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} m';
}
