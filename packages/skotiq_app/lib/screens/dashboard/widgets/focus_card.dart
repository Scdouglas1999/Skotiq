import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focuser_controls.dart';
import 'glass_card.dart';
import 'session_progress_card.dart';

class FocusCard extends ConsumerWidget {
  final SkotiqColors colors;

  const FocusCard({super.key, required this.colors});

  static const double _expandedThreshold = 280.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final focuserState = ref.watch(focuserStateProvider);
    final hfr = ref.watch(lastImageStatsProvider.select((s) => s?.hfr));
    final focusHistory = ref.watch(focusPositionHistoryProvider);
    final isConnected =
        focuserState.connectionState == DeviceConnectionState.connected;

    final positionText = focuserState.position != null
        ? '${focuserState.position}'
        : kReadoutUnknown;
    final tempText = focuserState.temperature != null
        ? '${focuserState.temperature!.toStringAsFixed(1)}°C'
        : kReadoutUnknown;
    final hfrText = hfr != null ? hfr.toStringAsFixed(2) : kReadoutUnknown;

    return DashboardGlassCard(
      colors: colors,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isExpanded = constraints.maxWidth >= _expandedThreshold;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DashboardCardHeader(
                colors: colors,
                icon: LucideIcons.focus,
                title: l10n.text('focus'),
                accent: isConnected ? colors.accent : null,
                trailing: DashboardStatusChip(
                  colors: colors,
                  label: isConnected ? l10n.text('ok') : l10n.text('off'),
                  active: isConnected,
                ),
              ),
              const SizedBox(height: DashboardCardStyle.headerGap),
              Row(
                children: [
                  DashboardMiniStat(
                    label: l10n.text('pos'),
                    value: positionText,
                    colors: colors,
                  ),
                  DashboardMiniStat(
                    label: l10n.text('temp'),
                    value: tempText,
                    colors: colors,
                  ),
                  DashboardMiniStat(
                    label: l10n.text('hfr'),
                    value: hfrText,
                    colors: colors,
                  ),
                ],
              ),

              // Expanded mode: Show sparkline and fine focus controls
              if (isExpanded && isConnected) ...[
                const SizedBox(height: 10),

                // Focus position history sparkline
                if (focusHistory.length >= 2)
                  _FocusPositionSparkline(
                    positions: focusHistory,
                    colors: colors,
                  )
                else
                  Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt.withValues(alpha: 0.5),
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                    ),
                    child: Center(
                      child: Text(
                        l10n.text('moveFocuserToSeeHistory'),
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted),
                      ),
                    ),
                  ),

                const SizedBox(height: 10),

                // Fine focus controls (+1/-1, +10/-10)
                Builder(builder: (context) {
                  final autofocusRunning = ref.watch(
                    sessionStateProvider.select(
                      (session) => session.isAutofocusing,
                    ),
                  );
                  return _FineFocusControls(
                    colors: colors,
                    isEnabled: isConnected &&
                        !focuserState.isMoving &&
                        !autofocusRunning,
                    onMove: (steps) async {
                      try {
                        await ref
                            .read(deviceServiceProvider)
                            .moveFocuserRelative(steps);
                      } catch (e) {
                        if (context.mounted) {
                          context.showErrorSnackBar(
                            'Failed to move focuser: $e',
                          );
                        }
                      }
                    },
                  );
                }),
              ],

              const SizedBox(height: 12),

              // Autofocus button (always shown) or full controls in expanded
              if (!isExpanded)
                SizedBox(
                  width: double.infinity,
                  child: SkotiqButton(
                    label: l10n.text('autofocus'),
                    icon: LucideIcons.focus,
                    size: ButtonSize.small,
                    onPressed: isConnected
                        ? () {
                            context.showInfoSnackBar(
                                l10n.text('useFocusTabForAutofocus'));
                          }
                        : null,
                  ),
                )
              else
                const FocuserControls(
                  compact: true,
                  showAutofocus: true,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Sparkline widget showing focus position history with min/max labels.
class _FocusPositionSparkline extends StatelessWidget {
  final List<int> positions;
  final SkotiqColors colors;

  const _FocusPositionSparkline({
    required this.positions,
    required this.colors,
  });

  /// Format position value compactly (e.g., 12345 -> "12.3k")
  String _formatPosition(int position) {
    if (position >= 10000) {
      return '${(position / 1000).toStringAsFixed(1)}k';
    }
    return position.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (positions.isEmpty) {
      return Container(
        height: 40,
        decoration: BoxDecoration(
          color: colors.surfaceAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        ),
        child: Center(
          child: Text(
            context.l10n.text('noData'),
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ),
      );
    }

    final minVal = positions.reduce(math.min);
    final maxVal = positions.reduce(math.max);
    final currentVal = positions.last;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Stack(
        children: [
          // Sparkline chart with left padding for labels
          Positioned.fill(
            child: Padding(
              padding:
                  const EdgeInsets.only(left: 28, right: 4, top: 4, bottom: 4),
              child: CustomPaint(
                size: const Size(double.infinity, 32),
                painter: _SparklinePainter(
                  values: positions.map((p) => p.toDouble()).toList(),
                  lineColor: colors.accent,
                  fillColor: colors.accent.withValues(alpha: 0.2),
                ),
              ),
            ),
          ),

          // Max label (top-left)
          Positioned(
            left: 4,
            top: 2,
            child: Text(
              _formatPosition(maxVal),
              style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),

          // Min label (bottom-left)
          Positioned(
            left: 4,
            bottom: 2,
            child: Text(
              _formatPosition(minVal),
              style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),

          // Current value badge (right side)
          Positioned(
            right: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surfaceOverlay.withValues(alpha: 0.9),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
                child: Text(
                  _formatPosition(currentVal),
                  style: SkotiqTypography.caption.copyWith(
                      color: colors.accent,
                      fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for sparkline chart.
class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color lineColor;
  final Color fillColor;

  _SparklinePainter({
    required this.values,
    required this.lineColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    const padding = 4.0;
    final chartWidth = size.width - (padding * 2);
    final chartHeight = size.height - (padding * 2);

    // Find min/max for scaling
    final minVal = values.reduce(math.min);
    final maxVal = values.reduce(math.max);
    final range = maxVal - minVal;

    // If all values are the same, draw a flat line in the middle
    final normalizedValues = range == 0
        ? List.filled(values.length, 0.5)
        : values.map((v) => (v - minVal) / range).toList();

    // Build path
    final path = Path();
    final fillPath = Path();

    for (int i = 0; i < normalizedValues.length; i++) {
      final x = padding + (i / (normalizedValues.length - 1)) * chartWidth;
      final y = padding + (1 - normalizedValues[i]) * chartHeight;

      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height - padding);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    // Complete fill path
    fillPath.lineTo(padding + chartWidth, size.height - padding);
    fillPath.close();

    // Draw fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, linePaint);

    // Draw current position dot (last point)
    if (normalizedValues.isNotEmpty) {
      final lastX = padding + chartWidth;
      final lastY = padding + (1 - normalizedValues.last) * chartHeight;
      final dotPaint = Paint()
        ..color = lineColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(lastX, lastY), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.fillColor != fillColor;
  }
}

/// Fine focus controls for step-by-step movement.
class _FineFocusControls extends StatelessWidget {
  final SkotiqColors colors;
  final bool isEnabled;
  final void Function(int steps) onMove;

  const _FineFocusControls({
    required this.colors,
    required this.isEnabled,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _FineStepButton(
            label: '-10',
            colors: colors,
            isEnabled: isEnabled,
            onPressed: () => onMove(-10),
          ),
          // Touch areas now adjacent - no spacer needed
          _FineStepButton(
            label: '-1',
            colors: colors,
            isEnabled: isEnabled,
            onPressed: () => onMove(-1),
          ),
          const SizedBox(width: 4),
          Text(
            'Fine',
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
          const SizedBox(width: 4),
          _FineStepButton(
            label: '+1',
            colors: colors,
            isEnabled: isEnabled,
            onPressed: () => onMove(1),
          ),
          // Touch areas now adjacent - no spacer needed
          _FineStepButton(
            label: '+10',
            colors: colors,
            isEnabled: isEnabled,
            onPressed: () => onMove(10),
          ),
        ],
      ),
    );
  }
}

/// Individual button for fine focus steps.
///
/// Uses expanded touch target (48x40px) for field use with gloves while
/// maintaining compact visual appearance.
class _FineStepButton extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  final bool isEnabled;
  final VoidCallback onPressed;

  const _FineStepButton({
    required this.label,
    required this.colors,
    required this.isEnabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // Expanded touch target: 48x40px for glove-friendly field use
    return SizedBox(
      width: 48,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? onPressed : null,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Center(
            // Visual element stays compact
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Text(
                label,
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: isEnabled ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
