// The guiding panel — Tonight's c4 tile, row 2 (06 §Tonight).
//
// A 96 px `well` chart over a `ReadoutRow` of RA / Dec / Total / SNR.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';

/// The chart's height (06 §Tonight, row 2).
const double _chartHeight = 96;

/// Full-scale deflection of the guide chart, in guide-camera pixels. Two pixels
/// either side of zero covers a normal night and still shows a spike as a
/// spike rather than clipping it flat.
const double _chartScalePx = 2.0;

class TonightGuidingPanel extends ConsumerWidget {
  const TonightGuidingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final guider = ref.watch(guiderStateProvider);
    final stats = ref.watch(guideStatsProvider);
    final points = ref.watch(guideGraphProvider);

    final connected = guider.connectionState == DeviceConnectionState.connected;
    final guiding = guider.isGuiding;

    // Every RMS number is a claim about guiding happening NOW. The values
    // linger in guider state after a session stops, so they are blanked unless
    // the guider is actually guiding — the em dash is the honest answer.
    String? rms(double? value) =>
        guiding && value != null ? value.toStringAsFixed(2) : null;

    return SkotiqPanel(
      head: PanelHead(
        icon: LucideIcons.crosshair,
        label: l10n.text('tnGuiding'),
        trailing: <Widget>[
          SkotiqChip(
            label: !connected
                ? l10n.text('tnDisconnected')
                : (guiding ? l10n.text('tnGuiding') : l10n.text('tnIdle')),
            tone: guiding ? ChipTone.success : ChipTone.neutral,
            dot: guiding,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: _chartHeight,
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
            child: points.isEmpty
                ? Center(
                    child: Text(
                      connected
                          ? l10n.text('tnNoGuideData')
                          : l10n.text('tnConnectGuider'),
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  )
                : CustomPaint(
                    painter: _GuideChartPainter(points: points, colors: colors),
                    child: const SizedBox.expand(),
                  ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          ReadoutRow(
            gap: SkotiqTokens.space2xl,
            children: <Readout>[
              Readout(
                value: rms(guider.rmsRa),
                unit: '"',
                label: l10n.text('tnRaRms'),
              ),
              Readout(
                value: rms(guider.rmsDec),
                unit: '"',
                label: l10n.text('tnDecRms'),
              ),
              Readout(
                value: rms(guider.rmsTotal),
                unit: '"',
                label: l10n.text('tnTotal'),
              ),
              Readout(
                value: guiding && stats.snr > 0
                    ? stats.snr.toStringAsFixed(1)
                    : null,
                label: l10n.text('tnSnr'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Two traces — RA in `error`, Dec in `primary` — over a hairline zero line.
class _GuideChartPainter extends CustomPainter {
  _GuideChartPainter({required this.points, required this.colors});

  final List<GuideGraphPoint> points;
  final SkotiqColors colors;

  static const double strokeWidth = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = colors.textPrimary.withValues(
          alpha: SkotiqTokens.opacityHairline,
        )
        ..strokeWidth = 1,
    );

    if (points.length < 2) return;

    void trace(double Function(GuideGraphPoint) value, Color color) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final x = size.width * (i / (points.length - 1));
        final normalised = (value(points[i]) / _chartScalePx).clamp(-1.0, 1.0);
        final y = mid - normalised * mid;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = color,
      );
    }

    trace((p) => p.ra, colors.error);
    trace((p) => p.dec, colors.primary);
  }

  @override
  bool shouldRepaint(covariant _GuideChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.colors != colors;
}
