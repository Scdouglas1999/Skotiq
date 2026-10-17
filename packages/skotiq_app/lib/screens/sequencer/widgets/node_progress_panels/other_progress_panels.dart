part of '../node_progress_panels.dart';

class _SlewProgressPanel extends StatelessWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;
  final bool isCentering;

  const _SlewProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
    required this.isCentering,
  });

  @override
  Widget build(BuildContext context) {
    // Parse detail for separation info in centering
    final sepMatch = RegExp(r'(\d+\.?\d*)"?').firstMatch(detail);
    final separation = double.tryParse(sepMatch?.group(1) ?? '');

    return _ProgressPanelContainer(
      colors: colors,
      accentColor: colors.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isCentering ? LucideIcons.locateFixed : LucideIcons.navigation,
                size: 16,
                color: colors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isCentering ? 'Centering Target' : 'Slewing to Target',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (separation != null && isCentering)
                Text(
                  '${separation.toStringAsFixed(1)}" remaining',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    color: colors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _AnimatedProgressBar(
            colors: colors,
            progress: progressPercent / 100.0,
            color: colors.warning,
          ),
        ],
      ),
    );
  }
}

/// Progress panel for filter change operations
class _FilterProgressPanel extends StatelessWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;

  const _FilterProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return _ProgressPanelContainer(
      colors: colors,
      accentColor: colors.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.filter, size: 16, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detail.isNotEmpty ? detail : 'Changing Filter',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _AnimatedProgressBar(
            colors: colors,
            progress: progressPercent / 100.0,
            color: colors.accent,
          ),
        ],
      ),
    );
  }
}

/// Default progress panel for nodes without specific visualization
class _DefaultProgressPanel extends StatelessWidget {
  final SkotiqColors colors;
  final double progressPercent;
  final String detail;

  const _DefaultProgressPanel({
    required this.colors,
    required this.progressPercent,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final isError = detail.toLowerCase().startsWith('error');
    final accentColor = isError ? colors.error : colors.info;

    return _ProgressPanelContainer(
      colors: colors,
      accentColor: accentColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  if (isError)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        SkotiqIcons.error,
                        size: 14,
                        color: colors.error,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      detail,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize11,
                        color: isError ? colors.error : colors.textPrimary,
                        fontWeight:
                            isError ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!isError)
            _AnimatedProgressBar(
              colors: colors,
              progress: progressPercent / 100.0,
              color: accentColor,
            ),
        ],
      ),
    );
  }
}
