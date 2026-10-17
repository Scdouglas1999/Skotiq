part of '../session_report_dialog.dart';

class _MountStatsRow extends StatelessWidget {
  final SessionReport report;
  final SkotiqColors colors;

  const _MountStatsRow({required this.report, required this.colors});

  @override
  Widget build(BuildContext context) {
    final mount = report.mountStats;
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        _StatChip(
            label: 'Autofocus runs',
            value: '${mount.autofocusRuns}',
            colors: colors),
        _StatChip(
            label: 'Meridian flips',
            value: '${mount.meridianFlips}',
            colors: colors),
        _StatChip(
            label: 'Dithers', value: '${mount.ditherCount}', colors: colors),
        _StatChip(
            label: 'Trigger fires',
            value: '${mount.triggerFires}',
            colors: colors),
      ],
    );
  }
}

class _GuideStatsBlock extends StatelessWidget {
  final SessionReport report;
  final SkotiqColors colors;

  const _GuideStatsBlock({required this.report, required this.colors});

  String _arcsec(double? v) => v == null ? '-' : '${v.toStringAsFixed(2)}"';

  @override
  Widget build(BuildContext context) {
    final gs = report.guideStats;
    if (gs.isEmpty) {
      return Text(
        'No guide data recorded for this session.',
        style: TextStyle(
            fontSize: SkotiqTypography.fontSize13, color: colors.textMuted),
      );
    }
    final unguidedPct = (gs.percentUnguidedFrames * 100).toStringAsFixed(1);
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        _StatChip(
            label: 'Mean RA RMS',
            value: _arcsec(gs.meanRmsRaArcsec),
            colors: colors),
        _StatChip(
            label: 'Mean Dec RMS',
            value: _arcsec(gs.meanRmsDecArcsec),
            colors: colors),
        _StatChip(
            label: 'Mean total RMS',
            value: _arcsec(gs.meanRmsTotalArcsec),
            colors: colors),
        _StatChip(
            label: 'Max RA RMS',
            value: _arcsec(gs.maxRmsRaArcsec),
            colors: colors),
        _StatChip(
            label: 'Max Dec RMS',
            value: _arcsec(gs.maxRmsDecArcsec),
            colors: colors),
        _StatChip(
            label: 'Max total RMS',
            value: _arcsec(gs.maxRmsTotalArcsec),
            colors: colors),
        _StatChip(
            label: 'Unguided frames', value: '$unguidedPct%', colors: colors),
      ],
    );
  }
}

class _ConditionsRow extends StatelessWidget {
  final SessionReport report;
  final SkotiqColors colors;

  const _ConditionsRow({required this.report, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 6,
      children: [
        if (report.avgTemperatureC != null)
          _StatChip(
            label: 'Mean temp',
            value: '${report.avgTemperatureC!.toStringAsFixed(1)} C',
            colors: colors,
          ),
        if (report.avgHumidityPercent != null)
          _StatChip(
            label: 'Mean humidity',
            value: '${report.avgHumidityPercent!.toStringAsFixed(1)}%',
            colors: colors,
          ),
        if (report.avgSeeingArcsec != null)
          _StatChip(
            label: 'Mean seeing',
            value: '${report.avgSeeingArcsec!.toStringAsFixed(2)}"',
            colors: colors,
          ),
      ],
    );
  }
}

class _TargetBlock extends StatelessWidget {
  final SessionTargetReport target;
  final SkotiqColors colors;

  const _TargetBlock({required this.target, required this.colors});

  String _formatDouble(double? value, int digits) =>
      value == null ? '-' : value.toStringAsFixed(digits);

  @override
  Widget build(BuildContext context) {
    final allReasons = <String, int>{};
    for (final f in target.filters) {
      for (final entry in f.rejectionReasons.entries) {
        allReasons[entry.key] = (allReasons[entry.key] ?? 0) + entry.value;
      }
    }
    return SkotiqCard(
      padding: const EdgeInsets.all(12),
      borderRadius: SkotiqTokens.radiusInline8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                target.targetName,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize14,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${target.framesAccepted}/${target.framesAttempted} frames | ${DurationFormat.seconds(target.totalIntegrationSecs, style: DurationStyle.hoursMinutes, rounding: DurationRounding.truncate)}',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Table(
            columnWidths: const {
              0: IntrinsicColumnWidth(),
              1: IntrinsicColumnWidth(),
              2: IntrinsicColumnWidth(),
              3: IntrinsicColumnWidth(),
              4: IntrinsicColumnWidth(),
              5: IntrinsicColumnWidth(),
              6: IntrinsicColumnWidth(),
              7: IntrinsicColumnWidth(),
              8: IntrinsicColumnWidth(),
            },
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.border)),
                ),
                children: [
                  _headerCell('Filter'),
                  _headerCell('Att.'),
                  _headerCell('Acc.'),
                  _headerCell('Rej.'),
                  _headerCell('Integration'),
                  _headerCell('HFR'),
                  _headerCell('FWHM'),
                  _headerCell('Stars'),
                  _headerCell('RMS'),
                ],
              ),
              for (final f in target.filters)
                TableRow(
                  children: [
                    _bodyCell(f.filter, bold: true),
                    _bodyCell('${f.framesAttempted}'),
                    _bodyCell('${f.framesAccepted}'),
                    _bodyCell(
                      '${f.framesRejected}',
                      color: f.framesRejected > 0 ? colors.warning : null,
                    ),
                    _bodyCell(DurationFormat.seconds(f.totalIntegrationSecs,
                        style: DurationStyle.hoursMinutes,
                        rounding: DurationRounding.truncate)),
                    _bodyCell(_formatDouble(f.meanHfr, 2)),
                    _bodyCell(_formatDouble(f.meanFwhm, 2)),
                    _bodyCell(_formatDouble(f.meanStarCount, 0)),
                    _bodyCell(_formatDouble(f.meanGuidingRmsTotal, 2)),
                  ],
                ),
            ],
          ),
          if (allReasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Rejections: ${_rejectionSummary(allReasons)}',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  String _rejectionSummary(Map<String, int> reasons) {
    final entries = reasons.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries.map((e) => '${e.key} (${e.value})').join(', ');
  }

  Widget _headerCell(String label) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: colors.textSecondary),
        ),
      );

  Widget _bodyCell(String value, {bool bold = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          value,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
            color: color ?? colors.textPrimary,
          ),
        ),
      );
}
