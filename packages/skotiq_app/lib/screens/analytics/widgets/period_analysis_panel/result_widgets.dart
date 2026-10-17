part of '../period_analysis_panel.dart';

class _ResultColumn extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final String detail;
  final _Verdict? verdict;

  const _ResultColumn({
    required this.colors,
    required this.label,
    required this.value,
    required this.detail,
    this.verdict,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.readoutMd.copyWith(
                color: colors.textPrimary, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            textAlign: TextAlign.center,
          ),
          if (verdict != null) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            _VerdictChip(colors: colors, verdict: verdict!),
          ],
        ],
      ),
    );
  }
}

enum _Verdict { significant, strong, noteworthy }

class _VerdictChip extends StatelessWidget {
  final SkotiqColors colors;
  final _Verdict verdict;

  const _VerdictChip({required this.colors, required this.verdict});

  @override
  Widget build(BuildContext context) {
    final (label, color, filled) = switch (verdict) {
      _Verdict.strong => ('Strong', colors.success, true),
      _Verdict.significant => ('Significant', colors.success, false),
      _Verdict.noteworthy => ('Noteworthy', colors.warning, false),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: 2,
      ),
      decoration: filled
          ? BoxDecoration(
              color: color,
              borderRadius: SkotiqTokens.borderRadiusLg,
            )
          : SkotiqDecorations.chip(colors, tone: color),
      child: Text(
        label,
        style: SkotiqTypography.caption.copyWith(
            color: filled ? colors.surface : color,
            fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _BlsStat extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;

  const _BlsStat({
    required this.colors,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        Text(
          value,
          style: SkotiqTypography.readoutXs
              .copyWith(color: colors.textPrimary, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
