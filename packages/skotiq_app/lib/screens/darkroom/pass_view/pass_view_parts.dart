// Pieces both pass-view directions share: the section frame, the header with
// the status line and the clocks, the image well, and the status sentence.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_charts.dart';
import 'pass_view_model.dart';

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
    this.expand = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: SkotiqTokens.spaceMd,
      vertical: 10,
    ),
  });

  final String title;
  final String? note;
  final Widget child;
  final bool divider;
  final bool expand;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (note != null) ...<Widget>[
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  note!,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (expand) Expanded(child: child) else child,
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: colors.border))
            : const Border(),
      ),
      child: Padding(padding: padding, child: body),
    );
  }
}

/// The status sentence: what the running stage is doing, with the numbers
/// it has measured on the sub it just finished.
String passStatusSentence(PassSnapshot s) {
  final active = s.activeSpan;
  if (active == null) return 'The pass is done';
  final (lane, span) = active;
  if (lane == null) {
    switch (span.stage) {
      case PassStage.align:
        final fits = s.timeline.channelFits;
        final lead = s.lanes.first.filter;
        if (fits.isEmpty) return 'Aligning channels to $lead';
        final f =
            fits.firstWhere((f) => f.failure == null, orElse: () => fits.first);
        if (f.failure != null) return 'Aligning channels to $lead';
        return 'Aligning ${fits.map((f) => f.filter).join(', ')} to $lead · '
            '${f.filter} ${passGrouped(f.inliers)} stars matched, '
            'shift ${_fixed(_hyp(f.dx, f.dy), 1)} px';
      case PassStage.combine:
        return 'Combining ${s.lanes.map((l) => l.filter).join(', ')} into color';
      case PassStage.draft:
        return 'Drafting ${s.timeline.target}';
      default:
        return span.stage.verb;
    }
  }
  final total = span.ticks.isEmpty ? lane.frames.length : span.ticks.length;
  final done = span.doneAt(s.elapsed);
  final counter = span.ticks.isEmpty
      ? ''
      : ' · ${done + 1 > total ? total : done + 1} of $total';
  final head = '${span.stage.verb} ${lane.filter}$counter';
  switch (span.stage) {
    case PassStage.calibrate:
      final note = s.timeline.calibrationNote;
      return note == null ? head : '$head · $note';
    case PassStage.register:
      if (done == 0) return '$head · picking the reference';
      final f = lane.frames[done - 1];
      final parts = <String>[
        if (f.stars != null) '${passGrouped(f.stars!)} stars',
        if (f.shift != null) 'shift ${_fixed(f.shift!, 1)} px',
        if (f.rmsPx != null && !f.isReference)
          'residual ${_fixed(f.rmsPx!, 2)} px',
        if (f.isReference) 'reference',
      ];
      return parts.isEmpty
          ? head
          : '$head · sub ${f.index}: ${parts.join(', ')}';
    case PassStage.normalize:
      final reached = s.depthsReached;
      return reached.isEmpty
          ? head
          : '$head · noise ${_fixed(reached.last.noise, 1)} ADU at ${reached.last.depth} subs';
    case PassStage.integrate:
      final n = lane.frames.where((f) => f.accepted).length;
      return '$head · $n subs, winsorized sigma 3 / 3';
    case PassStage.write:
      return '$head master';
    default:
      return head;
  }
}

String _fixed(double v, int d) => v.toStringAsFixed(d);
double _hyp(double a, double b) => ui.Offset(a, b).distance;

/// The top bar: title and target, the status sentence under it, and the
/// elapsed and remaining clocks with Stop.
class PassHeader extends StatelessWidget {
  const PassHeader({super.key, required this.snapshot, this.compact = false});

  final PassSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (remaining, complete) = snapshot.remaining;
    final status = passStatusSentence(snapshot);
    final clocks = <Widget>[
      _Clock(label: 'Elapsed', value: passClock(snapshot.elapsed)),
      _Clock(
        label: complete ? 'Remaining' : 'Remaining, at least',
        value: passClock(remaining),
      ),
    ];
    final title = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: <Widget>[
        Text(
          'Darkroom pass',
          style: (compact
                  ? SkotiqTypography.labelStrong
                  : SkotiqTypography.sectionTitle)
              .copyWith(color: colors.textPrimary),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Flexible(
          child: Text(
            snapshot.timeline.target,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.labelStrong
                .copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
    final line = Row(
      children: <Widget>[
        StatusDot(color: colors.primary, size: 7, live: false),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            status,
            maxLines: compact ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.label.copyWith(color: colors.textPrimary),
          ),
        ),
      ],
    );
    if (compact) {
      return Container(
        padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceMd, 10, SkotiqTokens.spaceMd, 10),
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(bottom: BorderSide(color: colors.border)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            title,
            const SizedBox(height: 6),
            line,
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                for (final c in clocks) ...<Widget>[
                  c,
                  const SizedBox(width: 20)
                ],
                const Spacer(),
                SkotiqButton(
                  label: 'Stop',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () {},
                ),
              ],
            ),
          ],
        ),
      );
    }
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceLg),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[title, const SizedBox(height: 4), line],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          for (final c in clocks) ...<Widget>[c, const SizedBox(width: 24)],
          SkotiqButton(
            label: 'Stop',
            variant: ButtonVariant.secondary,
            size: ButtonSize.medium,
            onPressed: () {},
          ),
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
        Text(value,
            style: SkotiqTypography.monoSm.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w500)),
        Text(label,
            style:
                SkotiqTypography.captionSm.copyWith(color: colors.textMuted)),
      ],
    );
  }
}

/// The image at its own aspect on a dark well, with what it is under it.
class PassImageWell extends StatelessWidget {
  const PassImageWell({
    super.key,
    required this.image,
    required this.caption,
    this.aspect = 4656 / 3520,
  });

  final ui.Image? image;
  final String caption;
  final double aspect;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final img = image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AspectRatio(
          aspectRatio: aspect,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.well,
              border: Border.all(color: colors.border),
            ),
            child: img == null
                ? Center(
                    child: Text(
                      caption,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textMuted),
                    ),
                  )
                : Semantics(
                    image: true,
                    label: caption,
                    child: RawImage(image: img, fit: BoxFit.cover),
                  ),
          ),
        ),
        if (img != null) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// A small filter key: a square in the lane's color and its letter.
class PassFilterKey extends StatelessWidget {
  const PassFilterKey(this.filter, {super.key, this.size = 8});
  final String filter;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
            width: size, height: size, color: passFilterColor(filter, colors)),
        const SizedBox(width: 5),
        Text(filter,
            style: SkotiqTypography.monoSm.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w600)),
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
