part of '../session_report_dialog.dart';

class _Header extends StatelessWidget {
  final SessionReport report;
  final SkotiqColors colors;
  final DateFormat dateFormat;
  final VoidCallback onCopyMarkdown;
  final VoidCallback onExportTxt;

  const _Header({
    required this.report,
    required this.colors,
    required this.dateFormat,
    required this.onCopyMarkdown,
    required this.onExportTxt,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.sessionName} - ${runStatusLabel(report.status)}',
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
              if (report.endTime != null)
                Text(
                  '${dateFormat.format(report.startTime)} - ${dateFormat.format(report.endTime!)}',
                  style: SkotiqTypography.captionSm
                      .copyWith(color: colors.textMuted),
                ),
            ],
          ),
        ),
        IconButton(
          onPressed: onCopyMarkdown,
          icon: const Icon(LucideIcons.clipboardCopy,
              size: SkotiqTokens.iconSm),
          tooltip: 'Copy as Markdown',
        ),
        IconButton(
          onPressed: onExportTxt,
          icon: const Icon(LucideIcons.fileText, size: SkotiqTokens.iconSm),
          tooltip: 'Export to .txt',
        ),
      ],
    );
  }
}

class _OverviewGrid extends StatelessWidget {
  final SessionReport report;
  final SkotiqColors colors;

  const _OverviewGrid({required this.report, required this.colors});

  @override
  Widget build(BuildContext context) {
    final efficiencyPct =
        (report.effectiveImagingFraction * 100).toStringAsFixed(1);
    return Wrap(
      spacing: SkotiqTokens.spaceLg,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        _OverviewTile(
          label: 'Wall clock',
          value: DurationFormat.of(report.wallClockDuration,
              style: DurationStyle.hoursMinutes),
          colors: colors,
        ),
        _OverviewTile(
          // "Light integration", not "Integration": `report.totalIntegration`
          // has always been the LIGHT-frame total, and a dark-library night
          // read "Integration 0s" as if nothing had been exposed. The
          // calibration tile beside it carries the rest of the shutter-open
          // time.
          label: 'Light integration',
          value: DurationFormat.of(report.totalIntegration,
              style: DurationStyle.hoursMinutes),
          colors: colors,
        ),
        if (report.calibration.isNotEmpty)
          _OverviewTile(
            label: 'Calibration',
            value: '${report.calibrationFramesAccepted} frames · '
                '${DurationFormat.of(Duration(milliseconds: (report.calibrationIntegrationSecs * 1000).round()), style: DurationStyle.hoursMinutes)}',
            colors: colors,
          ),
        _OverviewTile(
          label: 'Effective imaging',
          value: '$efficiencyPct%',
          colors: colors,
        ),
        _OverviewTile(
          label: 'Downtime',
          value: DurationFormat.of(report.downtime,
              style: DurationStyle.hoursMinutes),
          colors: colors,
        ),
        _OverviewTile(
          label: 'Frames accepted',
          value: '${report.totalFramesAccepted}/${report.totalFramesAttempted}',
          colors: colors,
        ),
        _OverviewTile(
          label: 'Frames rejected',
          value: report.totalFramesRejected.toString(),
          colors: colors,
          valueColor: report.totalFramesRejected > 0 ? colors.warning : null,
        ),
      ],
    );
  }
}

class _OverviewTile extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final Color? valueColor;

  const _OverviewTile({
    required this.label,
    required this.value,
    required this.colors,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: SkotiqCard(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd,
          vertical: SkotiqTokens.spaceSm + 2,
        ),
        borderRadius: SkotiqTokens.radiusLg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: SkotiqTypography.captionSm
                  .copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: SkotiqTokens.spaceXs),
            Text(
              value,
              style: SkotiqTypography.h4.copyWith(
                color: valueColor ?? colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final SkotiqColors colors;
  final Color? titleColor;

  const _SectionTitle({
    required this.title,
    required this.icon,
    required this.colors,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
      child: Row(
        children: [
          Icon(icon,
              size: SkotiqTokens.iconXs,
              color: titleColor ?? colors.primary),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            title,
            style: SkotiqTypography.labelStrong
                .copyWith(color: titleColor ?? colors.textPrimary),
          ),
        ],
      ),
    );
  }
}
