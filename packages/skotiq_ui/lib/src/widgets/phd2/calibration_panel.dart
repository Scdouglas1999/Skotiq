import '../../theme/skotiq_tokens.dart';
import '../../theme/skotiq_typography.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../../theme/skotiq_colors.dart';

/// Calibration state for PHD2
enum CalibrationState { notCalibrated, calibrating, calibrated }

/// Calibration data from PHD2
class CalibrationData {
  final bool hasCalibration;
  final double? raAngle;
  final double? decAngle;
  final double? raRate;
  final double? decRate;
  final DateTime? calibrationTime;

  const CalibrationData({
    this.hasCalibration = false,
    this.raAngle,
    this.decAngle,
    this.raRate,
    this.decRate,
    this.calibrationTime,
  });
}

/// Panel for viewing and controlling PHD2 calibration
class CalibrationPanel extends StatelessWidget {
  /// Current calibration state
  final CalibrationState state;

  /// Calibration data
  final CalibrationData data;

  /// Whether PHD2 is connected
  final bool isConnected;

  /// Calibration progress (0.0 to 1.0)
  final double? progress;

  /// Callbacks
  final VoidCallback? onStartCalibration;
  final VoidCallback? onClearCalibration;
  final VoidCallback? onFlipCalibration;

  const CalibrationPanel({
    super.key,
    required this.state,
    required this.data,
    required this.isConnected,
    this.progress,
    this.onStartCalibration,
    this.onClearCalibration,
    this.onFlipCalibration,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(colors),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state == CalibrationState.calibrating)
                    _buildCalibrationProgress(colors)
                  else if (data.hasCalibration)
                    _buildCalibrationData(colors)
                  else
                    _buildNotCalibrated(colors),
                  const SizedBox(height: 16),
                  _buildActions(context, colors),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors) {
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (state) {
      case CalibrationState.notCalibrated:
        statusColor = colors.warning;
        statusText = 'Not Calibrated';
        statusIcon = LucideIcons.alertTriangle;
        break;
      case CalibrationState.calibrating:
        statusColor = colors.info;
        statusText = 'Calibrating...';
        statusIcon = LucideIcons.settings;
        break;
      case CalibrationState.calibrated:
        statusColor = colors.success;
        statusText = 'Calibrated';
        statusIcon = LucideIcons.checkCircle;
        break;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Compact layout for narrow panels
        final isCompact = constraints.maxWidth < 280;
        final iconSize = isCompact ? 14.0 : 16.0;
        final iconPadding = isCompact ? 4.0 : 6.0;
        final titleFontSize = isCompact ? 12.0 : 14.0;
        final statusFontSize = isCompact ? 10.0 : 11.0;
        final horizontalPadding = isCompact ? 10.0 : 16.0;
        final statusPadding = isCompact
            ? const EdgeInsets.symmetric(horizontal: 6, vertical: 3)
            : const EdgeInsets.symmetric(horizontal: 10, vertical: 4);

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(SkotiqTokens.radiusLg),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(iconPadding),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                ),
                child: Icon(statusIcon, color: statusColor, size: iconSize),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Calibration',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: titleFontSize,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Container(
                  padding: statusPadding,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: statusFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCalibrationProgress(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              valueColor: AlwaysStoppedAnimation(colors.primary),
              backgroundColor: colors.surfaceHover,
            ),
          ),
          const SizedBox(height: 16),
          if (progress != null) ...[
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: colors.surfaceHover,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
              child: FractionallySizedBox(
                widthFactor: progress!,
                alignment: Alignment.centerLeft,
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${(progress! * 100).toStringAsFixed(0)}%',
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: SkotiqTypography.fontSize16,
              ),
            ),
          ] else
            Text(
              'Calibrating mount...',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: SkotiqTypography.fontSize13,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCalibrationData(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.success.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.checkCircle, color: colors.success, size: 16),
              const SizedBox(width: 8),
              Text(
                'Mount Calibrated',
                style: TextStyle(
                  color: colors.success,
                  fontWeight: FontWeight.w600,
                  fontSize: SkotiqTypography.fontSize13,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _buildDataRow(
            'RA Angle',
            '${data.raAngle?.toStringAsFixed(1) ?? '-'}°',
            colors,
          ),
          const SizedBox(height: 8),
          _buildDataRow(
            'Dec Angle',
            '${data.decAngle?.toStringAsFixed(1) ?? '-'}°',
            colors,
          ),
          const SizedBox(height: 8),
          _buildDataRow(
            'RA Rate',
            '${data.raRate?.toStringAsFixed(2) ?? '-'} px/s',
            colors,
          ),
          const SizedBox(height: 8),
          _buildDataRow(
            'Dec Rate',
            '${data.decRate?.toStringAsFixed(2) ?? '-'} px/s',
            colors,
          ),
          if (data.calibrationTime != null) ...[
            const SizedBox(height: 12),
            Divider(color: colors.border.withValues(alpha: 0.5), height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(LucideIcons.clock, size: 12, color: colors.textMuted),
                const SizedBox(width: 6),
                Text(
                  _formatTime(data.calibrationTime!),
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: SkotiqTypography.fontSize11,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNotCalibrated(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.warning.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.alertTriangle,
              color: colors.warning,
              size: 24,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Mount not calibrated',
            style: TextStyle(
              color: colors.warning,
              fontWeight: FontWeight.w600,
              fontSize: SkotiqTypography.fontSize14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'PHD2 will calibrate your mount automatically when you start guiding.',
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value, SkotiqColors colors) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: SkotiqTypography.fontSize12,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!data.hasCalibration &&
            state != CalibrationState.calibrating &&
            onStartCalibration != null)
          _buildActionButton(
            context: context,
            icon: LucideIcons.settings,
            label: 'Calibrate',
            color: colors.warning,
            colors: colors,
            onPressed: isConnected ? onStartCalibration : null,
            isPrimary: true,
          ),
        if (data.hasCalibration) ...[
          Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  context: context,
                  icon: LucideIcons.trash2,
                  label: 'Clear',
                  color: colors.error,
                  colors: colors,
                  onPressed: isConnected ? onClearCalibration : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildActionButton(
                  context: context,
                  icon: LucideIcons.flipHorizontal,
                  label: 'Flip',
                  color: colors.info,
                  colors: colors,
                  onPressed: isConnected ? onFlipCalibration : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.info, size: 12, color: colors.textMuted),
              const SizedBox(width: 6),
              Text(
                'Use "Flip" after a meridian flip',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: SkotiqTypography.fontSize10,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required Color color,
    required SkotiqColors colors,
    VoidCallback? onPressed,
    bool isPrimary = false,
  }) {
    final isDisabled = onPressed == null;
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return Semantics(
      // A hand-rolled button: the InkWell carries the tap and nothing else, so
      // assistive tech was told a live control was an inert disabled panel.
      button: true,
      enabled: !isDisabled,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          child: ConstrainedBox(
            // Ensure minimum 44px touch target height for accessibility
            constraints: const BoxConstraints(minHeight: 44),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isPrimary
                    ? (isDisabled ? colors.surfaceAlt : color)
                    : (isDisabled
                          ? colors.surfaceAlt
                          : color.withValues(alpha: 0.15)),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                border: Border.all(
                  color: isDisabled
                      ? colors.border
                      : (isPrimary ? color : color.withValues(alpha: 0.3)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: isPrimary
                        ? (isDisabled ? colors.textMuted : onPrimary)
                        : (isDisabled ? colors.textMuted : color),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        fontWeight: FontWeight.w600,
                        color: isPrimary
                            ? (isDisabled ? colors.textMuted : onPrimary)
                            : (isDisabled ? colors.textMuted : color),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 60) {
      return '${diff.inMinutes} min ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} hours ago';
    } else {
      return '${diff.inDays} days ago';
    }
  }
}
