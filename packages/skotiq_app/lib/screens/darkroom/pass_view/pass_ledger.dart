// The subs of one lane as a ledger: one row per sub, every measurement in a
// column, and under it every rejected sub with the whole reason the pipeline
// gave. A sub shows only what the pass has measured on it so far; a value far
// above its lane's median is drawn in the warning tone, so the rule follows
// the lane's own numbers whatever the star detector reports.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_charts.dart';
import 'pass_view_parts.dart';

final DateFormat _hm = DateFormat('HH:mm');

/// Whether [v] sits more than 3 robust sigmas above the median of [values].
/// Needs five values; a lane with fewer flags nothing.
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

/// What a sub is doing at this moment, and the tone to say it in.
(String, Color) passFrameStatus(
  PassSnapshot s,
  PassLane lane,
  PassFrame f,
  SkotiqColors colors,
) {
  if (s.measured(lane, f)) {
    if (!f.accepted) return ('rejected', colors.error);
    if (f.isReference) return ('reference', colors.primary);
    final norm = lane.span(PassStage.normalize);
    if (norm.stateAt(s.elapsed) == PassStepState.running) {
      final order = <PassFrame>[
        for (final x in lane.frames)
          if (x.accepted) x,
      ];
      if (norm.doneAt(s.elapsed) == order.indexOf(f)) {
        return ('normalizing', colors.primary);
      }
    }
    return ('', colors.textMuted);
  }
  final reg = lane.span(PassStage.register);
  if (reg.stateAt(s.elapsed) == PassStepState.running &&
      reg.doneAt(s.elapsed) + 1 == f.index) {
    return ('registering', colors.primary);
  }
  final cal = lane.span(PassStage.calibrate);
  if (cal.stateAt(s.elapsed) == PassStepState.running &&
      cal.doneAt(s.elapsed) + 1 == f.index) {
    return ('calibrating', colors.primary);
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

/// One row per sub of [lane]. [compact] keeps the five columns that fit the
/// side panel.
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

  static const List<_Col> _wide = <_Col>[
    _Col('#', 24, align: TextAlign.left),
    _Col('Taken', 42, align: TextAlign.left),
    _Col('Stars', 46),
    _Col('FWHM', 46, unit: 'px'),
    _Col('Ecc.', 38),
    _Col('Bkg', 52, unit: 'ADU'),
    _Col('Noise', 46, unit: 'ADU'),
    _Col('Shift', 46, unit: 'px'),
    _Col('Resid.', 46, unit: 'px'),
    _Col('Weight', 78),
  ];

  static const List<_Col> _narrow = <_Col>[
    _Col('#', 22, align: TextAlign.left),
    _Col('Stars', 44),
    _Col('FWHM', 42, unit: 'px'),
    _Col('Shift', 44, unit: 'px'),
    _Col('Weight', 64),
  ];

  /// The wide set without capture time, eccentricity and noise, for a column
  /// too narrow to keep a readable status beside all ten.
  static final List<_Col> _medium = <_Col>[
    for (final c in _wide)
      if (c.label != 'Taken' && c.label != 'Ecc.' && c.label != 'Noise') c,
  ];

  @override
  Widget build(BuildContext context) {
    if (compact) return _build(context, _narrow);
    return LayoutBuilder(
      builder: (context, c) =>
          _build(context, c.maxWidth < 660 ? _medium : _wide),
    );
  }

  Widget _build(BuildContext context, List<_Col> cols) {
    final colors = context.skotiqColors;
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final weighed = snapshot.weighed(lane);
    final measured = <PassFrame>[
      for (final f in lane.frames)
        if (snapshot.measured(lane, f)) f,
    ];
    final fwhms = measured.map((f) => f.fwhm);
    final eccs = measured.map((f) => f.eccentricity);
    final residuals = measured.where((f) => !f.isReference).map((f) => f.rmsPx);

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
      final rejected = m && !f.accepted;
      String v(num? x, int d) => !m || x == null
          ? ''
          : (d == 0 ? passGrouped(x) : x.toStringAsFixed(d));
      final values = <Widget>[];
      for (final c in cols) {
        final Widget w = switch (c.label) {
          '#' => cell(c, '${f.index}',
              color: m ? colors.textSecondary : colors.textMuted),
          'Taken' => cell(
              c,
              f.capturedAt == null ? '' : _hm.format(f.capturedAt!),
              color: colors.textMuted,
            ),
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
          'Resid.' => cell(
              c,
              f.isReference ? (m ? '0' : '') : v(f.rmsPx, 2),
              color: m && !f.isReference && passHighOutlier(f.rmsPx, residuals)
                  ? colors.warning
                  : null,
            ),
          'Weight' => SizedBox(
              width: c.width,
              child: weighed && m && f.accepted && f.weight != null
                  ? _WeightBar(
                      weight: f.weight!,
                      color: passFilterColor(lane.lane, colors),
                    )
                  : (rejected
                      ? Text(
                          compact ? 'rejected' : '0',
                          textAlign: TextAlign.right,
                          style: mono.copyWith(color: colors.error),
                        )
                      : const SizedBox.shrink()),
            ),
          _ => const SizedBox.shrink(),
        };
        values
          ..add(w)
          ..add(const SizedBox(width: 6));
      }
      final row = Container(
        height: rowHeight,
        decoration: BoxDecoration(
          color: active
              ? colors.primary.withValues(alpha: 0.10)
              : (rejected ? colors.error.withValues(alpha: 0.07) : null),
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
                  rejected ? 'rejected, see below' : status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.captionSm
                      .copyWith(color: statusColor, height: 1),
                ),
              ),
          ],
        ),
      );
      final reason = f.reason;
      rows.add(
        rejected && reason != null
            ? Tooltip(message: passReadableReason(reason), child: row)
            : row,
      );
    }
    final rejectedFrames = <PassFrame>[
      for (final f in measured)
        if (!f.accepted) f,
    ];
    if (rejectedFrames.isNotEmpty) {
      rows.add(const SizedBox(height: 8));
      for (final f in rejectedFrames) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(
                    text: 'Sub ${f.index} rejected: ',
                    style: SkotiqTypography.captionSm.copyWith(
                        color: colors.error, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: passReadableReason(f.reason ?? 'no reason recorded'),
                  ),
                ],
              ),
              style: SkotiqTypography.captionSm
                  .copyWith(color: colors.textSecondary),
            ),
          ),
        );
      }
    }
    return Semantics(
      label: '${lane.lane} subs, ${measured.length} of ${lane.frames.length} '
          'measured, ${rejectedFrames.length} rejected',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
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
                  color: color,
                ),
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
