import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'first_light_format.dart';
import 'widgets/cutout_strip.dart';

/// Match radius (degrees) for grouping the same physical transient across
/// nights. ~72" — wide enough to absorb plate-solve / centroid scatter between
/// nights, tight enough not to merge a genuinely different nearby source.
const double _kHistoryRadiusDeg = 0.02;

/// Detail / light-curve view for one First Light transient.
///
/// The card a transient renders on is a terminal tile: the same source over
/// three nights shows as three unrelated cards, and the discoverer's core
/// question — "is it real, and is it changing?" — is unanswerable. This screen
/// groups every persisted detection within [_kHistoryRadiusDeg] of the tapped
/// candidate (across sessions / nights) into one Δmag-vs-time light curve plus a
/// per-night log, so "Confirmed (seen 3 nights)" becomes meaningful.
///
/// Backend-aware: the grouping flows through [firstLightHistoryProvider], which
/// reads the local DB on desktop and the host's `/api/firstlight/near` snapshot
/// on a companion tablet, so the view is identical on desktop and mobile.
class FirstLightDetailScreen extends ConsumerWidget {
  const FirstLightDetailScreen({super.key, required this.detection});

  /// The candidate the user tapped — the anchor for the cross-night grouping.
  final TransientDetectionRow detection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final isUnknown = detection.catalogMatch == null;
    final title = isUnknown ? 'Possible transient' : detection.catalogMatch!;

    final query = (
      raDeg: detection.raDeg,
      decDeg: detection.decDeg,
      radiusDeg: _kHistoryRadiusDeg,
    );
    final historyAsync = ref.watch(firstLightHistoryProvider(query));

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        leading: IconButton(
          icon:
              const Icon(LucideIcons.arrowLeft, size: SkotiqTokens.iconMd),
          color: colors.textPrimary,
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          title,
          style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: SkotiqTokens.screenPadding,
          children: [
            _PositionCard(detection: detection, colors: colors),
            const SizedBox(height: SkotiqTokens.spaceMd),
            CutoutStrip(detection: detection),
            const SizedBox(height: SkotiqTokens.spaceLg),
            const SectionHeader(
              title: 'Light curve',
              subtitle: 'Δmag across every night this position was detected',
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            historyAsync.when(
              data: (rows) => _History(rows: rows, anchor: detection),
              loading: () => const SizedBox(
                height: 160,
                child: Center(
                  child: SkotiqCircularProgress(
                    value: 0,
                    indeterminate: true,
                  ),
                ),
              ),
              error: (error, _) => EmptyState(
                icon: LucideIcons.alertCircle,
                title: 'Could not load history',
                body: describeFirstLightError(error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({required this.detection, required this.colors});

  final TransientDetectionRow detection;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      variant: CardVariant.subtle,
      padding: SkotiqTokens.cardPadding,
      child: Row(
        children: [
          Icon(
            SkotiqIcons.crosshair,
            size: SkotiqTokens.iconSm,
            color: colors.accent,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              '${CoordinateFormat.ra(detection.raDeg / 15.0)}   '
              '${CoordinateFormat.dec(detection.decDeg)}',
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.rows, required this.anchor});

  final List<TransientDetectionRow> rows;
  final TransientDetectionRow anchor;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // Defensive: an empty group should never happen (the anchor itself is at
    // this position), but a stale snapshot could lag — show the anchor alone.
    final points = rows.isEmpty ? [anchor] : rows;
    final nights = _distinctNights(points);

    final withMag = points
        .where((r) => r.deltaMag != null && r.deltaMag!.isFinite)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          points.length == 1
              ? 'Seen once. Chase it again to build a light curve.'
              : 'Detected ${points.length} times across '
                  '${nights == 1 ? '1 night' : '$nights nights'}.',
          style: SkotiqTypography.caption.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (withMag.length >= 2)
          SkotiqCard(
            variant: CardVariant.subtle,
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: SizedBox(
              height: 180,
              child: CustomPaint(
                painter: _LightCurvePainter(
                  points: withMag,
                  lineColor: colors.accent,
                  axisColor: colors.border,
                  textColor: colors.textMuted,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          )
        else
          SkotiqCard(
            variant: CardVariant.subtle,
            padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
            child: Text(
              'A light curve needs at least two nights with a measured Δmag. '
              'Keep re-imaging this position to watch it rise or fade.',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        const SectionHeader(title: 'Detections'),
        const SizedBox(height: SkotiqTokens.spaceSm),
        for (final r in points.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
            child: _DetectionRow(row: r, colors: colors),
          ),
      ],
    );
  }

  int _distinctNights(List<TransientDetectionRow> points) {
    // A "night" keys on the local calendar date of the detection — good enough
    // to count distinct sessions without an observatory-longitude noon roll.
    final days = <String>{};
    for (final r in points) {
      final d = r.detectedAt.toLocal();
      days.add('${d.year}-${d.month}-${d.day}');
    }
    return days.length;
  }
}

class _DetectionRow extends StatelessWidget {
  const _DetectionRow({required this.row, required this.colors});

  final TransientDetectionRow row;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final dm = row.deltaMag;
    final when = row.detectedAt.toLocal();
    final dateStr = '${when.year}-${_two(when.month)}-${_two(when.day)} '
        '${_two(when.hour)}:${_two(when.minute)}';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dateStr,
              style: SkotiqTypography.monoSm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          Text(
            'SNR ${row.snr.toStringAsFixed(1)}',
            style: SkotiqTypography.labelSm.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          if (dm != null && dm.isFinite)
            Text(
              // Native convention: negative = brighter. Show the signed value
              // the way an astronomer reads Δmag (matches the card chip).
              '${dm <= 0 ? '' : '+'}${dm.toStringAsFixed(2)} mag',
              style: SkotiqTypography.labelStrongSm.copyWith(
                color: dm <= 0 ? colors.accent : colors.info,
              ),
            )
          else
            Text(
              'no mag',
              style: SkotiqTypography.labelSm.copyWith(
                color: colors.textMuted,
              ),
            ),
        ],
      ),
    );
  }

  String _two(int v) => v.toString().padLeft(2, '0');
}

/// Paints a simple Δmag-vs-time light curve. Magnitude axis is inverted
/// (brighter = up), the astronomy convention. Plots the [points]
/// oldest-to-newest (they arrive sorted by detectedAt).
class _LightCurvePainter extends CustomPainter {
  _LightCurvePainter({
    required this.points,
    required this.lineColor,
    required this.axisColor,
    required this.textColor,
  });

  final List<TransientDetectionRow> points;
  final Color lineColor;
  final Color axisColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    const pad = 28.0;
    final plot = Rect.fromLTRB(pad, 12, size.width - 8, size.height - pad);

    final tMin = points.first.detectedAt.millisecondsSinceEpoch.toDouble();
    final tMax = points.last.detectedAt.millisecondsSinceEpoch.toDouble();
    final tSpan = (tMax - tMin).abs() < 1 ? 1.0 : tMax - tMin;

    var magMin = double.infinity;
    var magMax = -double.infinity;
    for (final p in points) {
      final m = p.deltaMag!;
      if (m < magMin) magMin = m;
      if (m > magMax) magMax = m;
    }
    final magSpan = (magMax - magMin).abs() < 1e-3 ? 1.0 : magMax - magMin;

    double dx(TransientDetectionRow p) =>
        plot.left +
        ((p.detectedAt.millisecondsSinceEpoch - tMin) / tSpan) * plot.width;
    // Invert: brighter (more negative Δmag) plots higher on the canvas.
    double dy(TransientDetectionRow p) =>
        plot.top + ((p.deltaMag! - magMin) / magSpan) * plot.height;

    final axisPaint = Paint()
      ..color = axisColor
      ..strokeWidth = 1;
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axisPaint);
    canvas.drawLine(plot.topLeft, plot.bottomLeft, axisPaint);

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = dx(points[i]);
      final y = dy(points[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    final dotPaint = Paint()..color = lineColor;
    for (final p in points) {
      canvas.drawCircle(Offset(dx(p), dy(p)), 3, dotPaint);
    }

    _label(canvas, magMax.toStringAsFixed(1), Offset(2, plot.bottom - 6));
    _label(canvas, magMin.toStringAsFixed(1), Offset(2, plot.top - 6));
  }

  void _label(Canvas canvas, String text, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: textColor, fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_LightCurvePainter old) =>
      old.points != points || old.lineColor != lineColor;
}
