// The subs of a pass: as a ledger (one row per sub, every measurement in a
// column) and as a field (one tile per sub, in filter lanes). A sub shows only
// what the pass has measured on it so far; a value far from its lane's median
// is drawn in the warning tone so it stands out from the column.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_charts.dart';
import 'pass_view_model.dart';
import 'pass_view_parts.dart';

final DateFormat _hm = DateFormat('HH:mm');

/// Whether [v] sits more than 3 robust sigmas above the median of [values].
bool passHighOutlier(double? v, Iterable<double?> values) {
  if (v == null) return false;
  final xs = values.whereType<double>().toList()..sort();
  if (xs.length < 5) return false;
  final med = xs[xs.length ~/ 2];
  final dev = xs.map((x) => (x - med).abs()).toList()..sort();
  final mad = dev[dev.length ~/ 2] * 1.4826;
  if (mad <= 0) return false;
  return (v - med) / mad > 3;
}

/// What a sub is doing at this moment, as the ledger's status column says it.
(String, Color) passFrameStatus(
    PassSnapshot s, PassLane lane, PassFrame f, SkotiqColors colors) {
  if (s.measured(lane, f)) {
    if (!f.accepted) {
      return ('rejected: ${f.reason ?? 'no reason recorded'}', colors.error);
    }
    if (f.isReference) return ('reference', colors.primary);
    final norm = lane.span(PassStage.normalize);
    if (norm.stateAt(s.elapsed) == PassStepState.running &&
        s.stackedIn(lane) ==
            lane.frames.where((x) => x.accepted).toList().indexOf(f)) {
      return ('normalizing', colors.primary);
    }
    return ('', colors.textMuted);
  }
  final reg = lane.span(PassStage.register);
  if (reg.stateAt(s.elapsed) == PassStepState.running &&
      reg.doneAt(s.elapsed) + 1 == f.index) {
    return ('registering', colors.primary);
  }
  final cal = lane.span(PassStage.calibrate);
  if (cal.stateAt(s.elapsed) == PassStepState.running) {
    return cal.doneAt(s.elapsed) >= f.index
        ? ('calibrated', colors.textMuted)
        : (cal.doneAt(s.elapsed) + 1 == f.index
            ? ('calibrating', colors.primary)
            : ('', colors.textMuted));
  }
  return ('', colors.textMuted);
}

class _Col {
  const _Col(this.label, this.width, {this.unit, this.align = TextAlign.right});
  final String label;
  final String? unit;
  final double width;
  final TextAlign align;
}

/// One row per sub of [lane], every measurement in a column.
class PassLedger extends StatelessWidget {
  const PassLedger({
    super.key,
    required this.snapshot,
    required this.lane,
    this.rowHeight = 20,
    this.compact = false,
  });

  final PassSnapshot snapshot;
  final PassLane lane;
  final double rowHeight;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final cols = compact
        ? const <_Col>[
            _Col('#', 22, align: TextAlign.left),
            _Col('Stars', 46),
            _Col('FWHM', 42, unit: 'px'),
            _Col('Shift', 46, unit: 'px'),
            _Col('Weight', 70),
          ]
        : const <_Col>[
            _Col('#', 24, align: TextAlign.left),
            _Col('Taken', 44, align: TextAlign.left),
            _Col('Stars', 50),
            _Col('FWHM', 50, unit: 'px'),
            _Col('Ecc.', 40),
            _Col('Bkg', 54, unit: 'ADU'),
            _Col('Noise', 50, unit: 'ADU'),
            _Col('Shift', 50, unit: 'px'),
            _Col('Resid.', 50, unit: 'px'),
            _Col('Weight', 84),
          ];
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final weighed = snapshot.weighed(lane);
    final fwhms = [
      for (final f in lane.frames)
        if (snapshot.measured(lane, f)) f.fwhm
    ];
    final eccs = [
      for (final f in lane.frames)
        if (snapshot.measured(lane, f)) f.eccentricity
    ];
    final shifts = [
      for (final f in lane.frames)
        if (snapshot.measured(lane, f)) f.rmsPx
    ];

    Widget cell(_Col c, String text, {Color? color}) => SizedBox(
          width: c.width,
          child: Text(
            text,
            textAlign: c.align,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: mono.copyWith(color: color),
          ),
        );

    final rows = <Widget>[
      SizedBox(
        height: 28,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (final c in cols) ...<Widget>[
              SizedBox(
                width: c.width,
                child: Text(
                  c.unit == null ? c.label : '${c.label}\n${c.unit}',
                  textAlign: c.align,
                  maxLines: 2,
                  style: head.copyWith(height: 1.15),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (!compact) Expanded(child: Text('Status', style: head)),
          ],
        ),
      ),
      const SizedBox(height: 3),
    ];
    for (final f in lane.frames) {
      final m = snapshot.measured(lane, f);
      final (status, statusColor) = passFrameStatus(snapshot, lane, f, colors);
      final active = statusColor == colors.primary && status != 'reference';
      final dim = !m;
      String v(num? x, int d) => !m || x == null
          ? ''
          : (d == 0 ? passGrouped(x) : x.toStringAsFixed(d));
      final values = <Widget>[];
      for (final c in cols) {
        final Widget w = switch (c.label) {
          '#' => cell(c, '${f.index}',
              color: dim ? colors.textMuted : colors.textSecondary),
          'Taken' => cell(
              c, f.capturedAt == null ? '' : _hm.format(f.capturedAt!),
              color: colors.textMuted),
          'Stars' => cell(c, v(f.stars, 0)),
          'FWHM' => cell(c, v(f.fwhm, 2),
              color:
                  m && passHighOutlier(f.fwhm, fwhms) ? colors.warning : null),
          'Ecc.' => cell(c, v(f.eccentricity, 2),
              color: m && passHighOutlier(f.eccentricity, eccs)
                  ? colors.warning
                  : null),
          'Bkg' => cell(c, v(f.background, 0)),
          'Noise' => cell(c, v(f.noise, 1)),
          'Shift' => cell(c, v(f.shift, 1)),
          'Resid.' => cell(c, f.isReference ? (m ? '0' : '') : v(f.rmsPx, 2),
              color: m && passHighOutlier(f.rmsPx, shifts)
                  ? colors.warning
                  : null),
          'Weight' => SizedBox(
              width: c.width,
              child: weighed && m && f.accepted && f.weight != null
                  ? _WeightBar(
                      weight: f.weight!,
                      color: passFilterColor(lane.filter, colors))
                  : (weighed && m && !f.accepted
                      ? Text('0',
                          textAlign: TextAlign.right,
                          style: mono.copyWith(color: colors.error))
                      : const SizedBox.shrink()),
            ),
          _ => const SizedBox.shrink(),
        };
        values
          ..add(w)
          ..add(const SizedBox(width: 6));
      }
      rows.add(
        Container(
          height: rowHeight,
          decoration: BoxDecoration(
            color: active
                ? colors.primary.withValues(alpha: 0.10)
                : (!f.accepted && m
                    ? colors.error.withValues(alpha: 0.07)
                    : null),
            border: Border(
              left: BorderSide(
                color: active ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: const EdgeInsets.only(left: 4),
          child: Row(
            children: <Widget>[
              ...values,
              if (!compact)
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: statusColor, height: 1),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      label:
          '${lane.filter} subs, ${lane.frames.where((f) => snapshot.measured(lane, f)).length} '
          'of ${lane.frames.length} measured',
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
    );
  }
}

class _WeightBar extends StatelessWidget {
  const _WeightBar({required this.weight, required this.color});
  final double weight;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) => Stack(
              children: <Widget>[
                Container(height: 4, color: colors.border),
                Container(
                    height: 4,
                    width: c.maxWidth * weight.clamp(0, 1),
                    color: color),
              ],
            ),
          ),
        ),
        const SizedBox(width: 5),
        SizedBox(
          width: 28,
          child: Text(
            weight.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: SkotiqTypography.monoXs
                .copyWith(color: colors.textSecondary, height: 1),
          ),
        ),
      ],
    );
  }
}

/// One tile per sub, one row per filter lane. A tile shows the sub's
/// stretched thumbnail and its FWHM once it is measured, its weight as the
/// bar under it, and its index while it waits.
class PassFrameField extends StatelessWidget {
  const PassFrameField({
    super.key,
    required this.snapshot,
    this.thumbnails = true,
    this.labelWidth = 92,
  });

  final PassSnapshot snapshot;
  final bool thumbnails;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final maxSubs =
        snapshot.lanes.fold<int>(0, (m, l) => math.max(m, l.frames.length));
    return LayoutBuilder(builder: (context, c) {
      const gap = 3.0;
      final tileW = ((c.maxWidth - labelWidth - gap * (maxSubs - 1)) / maxSubs)
          .floorToDouble();
      final thumbH = thumbnails ? (tileW / 1.32).roundToDouble() : tileW;
      final tileH = thumbnails ? thumbH + 17 : 16.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final lane in snapshot.lanes) ...<Widget>[
            SizedBox(
              height: tileH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: labelWidth,
                    child: _LaneLabel(
                        snapshot: snapshot, lane: lane, compact: !thumbnails),
                  ),
                  for (var i = 0; i < lane.frames.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: tileW,
                      height: tileH,
                      child: _Tile(
                        snapshot: snapshot,
                        lane: lane,
                        frame: lane.frames[i],
                        thumbHeight: thumbH,
                        thumbnails: thumbnails,
                        fwhms: [
                          for (final f in lane.frames)
                            if (snapshot.measured(lane, f)) f.fwhm
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          Padding(
            padding: EdgeInsets.only(left: labelWidth),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: <Widget>[
                if (thumbnails)
                  _KeyItem(
                      color: colors.textSecondary,
                      label: 'FWHM px under each sub'),
                if (!thumbnails)
                  _KeyItem(color: colors.textSecondary, label: 'fill: weight'),
                if (thumbnails)
                  _KeyItem(
                      color: colors.warning,
                      label: 'far above the lane median'),
                _KeyItem(color: colors.error, label: 'rejected'),
                _KeyItem(color: colors.primary, label: 'working on it'),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _KeyItem extends StatelessWidget {
  const _KeyItem({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
      Container(width: 8, height: 2, color: color),
      const SizedBox(width: 5),
      Text(label,
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted)),
    ]);
  }
}

class _LaneLabel extends StatelessWidget {
  const _LaneLabel(
      {required this.snapshot, required this.lane, this.compact = false});
  final PassSnapshot snapshot;
  final PassLane lane;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final measured =
        lane.frames.where((f) => snapshot.measured(lane, f)).length;
    final kept = lane.frames
        .where((f) => snapshot.measured(lane, f) && f.accepted)
        .toList();
    final secs = kept.length * lane.exposureSec;
    final done = lane.span(PassStage.write).stateAt(snapshot.elapsed) ==
        PassStepState.done;
    if (compact) {
      return Row(children: <Widget>[
        PassFilterKey(lane.filter),
        const SizedBox(width: 6),
        Text(
          done ? passIntegration(secs) : '$measured/${lane.frames.length}',
          style: SkotiqTypography.monoXs
              .copyWith(fontSize: 9, color: colors.textSecondary, height: 1),
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PassFilterKey(lane.filter),
        const SizedBox(height: 3),
        Text(
          done ? passIntegration(secs) : '$measured / ${lane.frames.length}',
          style: SkotiqTypography.monoXs
              .copyWith(color: colors.textSecondary, height: 1.2),
        ),
        Text(
          done ? '${kept.length} subs' : '${lane.exposureSec.round()} s subs',
          style: SkotiqTypography.captionSm
              .copyWith(color: colors.textMuted, height: 1.2),
        ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.snapshot,
    required this.lane,
    required this.frame,
    required this.thumbHeight,
    required this.thumbnails,
    required this.fwhms,
  });

  final PassSnapshot snapshot;
  final PassLane lane;
  final PassFrame frame;
  final double thumbHeight;
  final bool thumbnails;
  final List<double?> fwhms;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final m = snapshot.measured(lane, frame);
    final (status, statusColor) =
        passFrameStatus(snapshot, lane, frame, colors);
    final working = statusColor == colors.primary && status != 'reference';
    final rejected = m && !frame.accepted;
    final laneColor = passFilterColor(lane.filter, colors);
    final border =
        working ? colors.primary : (rejected ? colors.error : colors.border);

    if (!thumbnails) {
      final fill = !m
          ? null
          : rejected
              ? colors.error.withValues(alpha: 0.85)
              : laneColor.withValues(
                  alpha: snapshot.weighed(lane)
                      ? 0.35 + 0.6 * (frame.weight ?? 0).clamp(0, 1)
                      : 0.6);
      return Container(
        decoration: BoxDecoration(
          color: fill ?? colors.well,
          border: Border.all(color: border, width: working ? 1.5 : 1),
        ),
      );
    }

    final thumb = frame.thumbnail;
    final outlier = m && passHighOutlier(frame.fwhm, fwhms);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: thumbHeight,
          decoration: BoxDecoration(
            color: colors.well,
            border: Border.all(color: border, width: working ? 1.5 : 1),
          ),
          child: m && thumb != null
              ? Opacity(
                  opacity: rejected ? 0.35 : 1,
                  child: RawImage(image: thumb, fit: BoxFit.cover),
                )
              : Center(
                  child: Text(
                    '${frame.index}',
                    style: SkotiqTypography.monoXs.copyWith(
                        fontSize: 9,
                        color: working ? colors.primary : colors.textMuted),
                  ),
                ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          height: 3,
          child: LayoutBuilder(
            builder: (context, c) => Stack(children: <Widget>[
              Container(color: colors.border),
              if (m && snapshot.weighed(lane))
                Container(
                  width: c.maxWidth * (frame.weight ?? 0).clamp(0, 1),
                  color: rejected ? colors.error : laneColor,
                ),
            ]),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          !m
              ? ''
              : rejected
                  ? 'rej.'
                  : (frame.fwhm?.toStringAsFixed(2) ?? ''),
          textAlign: TextAlign.center,
          maxLines: 1,
          softWrap: false,
          style: SkotiqTypography.monoXs.copyWith(
            fontSize: 9,
            height: 1,
            color: rejected
                ? colors.error
                : (outlier ? colors.warning : colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
