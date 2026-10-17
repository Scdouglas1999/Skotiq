part of '../diagnostics_screen.dart';

class _IssuesCard extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final SkotiqColors colors;

  const _IssuesCard({
    required this.diagnostics,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return _DiagCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.clipboardList, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Text(
                'Findings',
                style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
              ),
              const Spacer(),
              Text(
                '${diagnostics.issues.length} item${diagnostics.issues.length == 1 ? '' : 's'}',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (diagnostics.issues.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'No issues detected',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted),
                ),
              ),
            )
          else
            ...diagnostics.issues.map(
              (issue) => _IssueRow(issue: issue, colors: colors),
            ),
        ],
      ),
    );
  }
}

class _IssueRow extends StatelessWidget {
  final OpticalDiagnosticIssue issue;
  final SkotiqColors colors;

  const _IssueRow({
    required this.issue,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (issue.severity) {
      OpticalIssueSeverity.critical => (LucideIcons.alertOctagon, colors.error),
      OpticalIssueSeverity.warning => (
          LucideIcons.alertTriangle,
          colors.warning
        ),
      OpticalIssueSeverity.info => (LucideIcons.info, colors.info),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issue.title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  issue.detail,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Shared card container

class _DiagCard extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _DiagCard({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: SkotiqCard(
        variant: CardVariant.subtle,
        borderRadius: SkotiqTokens.radiusInline8,
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    );
  }
}

/// Skeleton placeholder for the diagnostics grid. Mirrors the rough card
/// dimensions so the layout doesn't reflow when the analysis stream resolves.
class _DiagnosticsLoadingSkeleton extends StatelessWidget {
  const _DiagnosticsLoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    Widget card(double height) => ShimmerLoading(
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(color: colors.border),
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: card(220)),
            const SizedBox(width: 12),
            Expanded(child: card(220)),
            const SizedBox(width: 12),
            Expanded(child: card(220)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: card(280)),
            const SizedBox(width: 12),
            Expanded(child: card(280)),
          ],
        ),
        const SizedBox(height: 12),
        card(140),
      ],
    );
  }
}
