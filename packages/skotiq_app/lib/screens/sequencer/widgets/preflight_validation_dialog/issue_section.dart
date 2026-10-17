// A pre-flight category: a section title over a well of issue rows.
//
// 05 §15 gives the heading, §9 gives the rows and 02's second rule caps the
// nesting at panel → well, so the group is NOT a card inside the dialog card:
// the title sits on the dialog's own surface and only the rows are inset.
part of '../preflight_validation_dialog.dart';

class _PreflightSection extends StatefulWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final List<ValidationIssue> issues;

  /// One action for the whole group, e.g. "Capture missing darks".
  final Widget? trailing;

  /// Show each issue's category beside its title. True only for the General
  /// bucket, where the rows come from several categories; inside a named
  /// section the chip would repeat the heading on every row.
  final bool showCategory;

  const _PreflightSection({
    required this.colors,
    required this.icon,
    required this.title,
    required this.issues,
    this.trailing,
    this.showCategory = false,
  });

  @override
  State<_PreflightSection> createState() => _PreflightSectionState();
}

class _PreflightSectionState extends State<_PreflightSection> {
  bool _expanded = true;

  /// The count chip's tone: the worst severity in the group. Info-only groups
  /// take the neutral face — a count is not a status.
  ChipTone _worstTone() {
    if (widget.issues.any((i) => i.severity == ValidationSeverity.error)) {
      return ChipTone.error;
    }
    if (widget.issues.any((i) => i.severity == ValidationSeverity.warning)) {
      return ChipTone.warning;
    }
    return ChipTone.neutral;
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final lowerTitle = widget.title.toLowerCase();
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionTitle(
            icon: widget.icon,
            title: widget.title,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SkotiqChip(
                  label: '${widget.issues.length}',
                  tone: _worstTone(),
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                SkotiqIconButton(
                  icon: _expanded
                      ? SkotiqIcons.chevronUp
                      : SkotiqIcons.chevronDown,
                  tooltip:
                      _expanded ? 'Collapse $lowerTitle' : 'Expand $lowerTitle',
                  size: IconButtonSize.sm,
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
          ),
          if (_expanded)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
                vertical: SkotiqTokens.spaceXs,
              ),
              decoration: SkotiqDecorations.well(colors),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.issues.length; i++)
                    _IssueRow(
                      colors: colors,
                      issue: widget.issues[i],
                      showCategory: widget.showCategory,
                      showDivider: i < widget.issues.length - 1,
                    ),
                  if (widget.trailing != null)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: SkotiqTokens.spaceSm,
                        bottom: SkotiqTokens.spaceXs,
                      ),
                      child: Row(
                        children: [
                          const Spacer(),
                          widget.trailing!,
                        ],
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

/// One validation issue, on the [ListRow] metrics: 8px vertical padding, a
/// 15px muted-scale leading glyph in the severity tone, a hairline underneath,
/// and the description and resolution hint beneath the title.
class _IssueRow extends StatelessWidget {
  final SkotiqColors colors;
  final ValidationIssue issue;
  final bool showCategory;
  final bool showDivider;

  const _IssueRow({
    required this.colors,
    required this.issue,
    this.showCategory = false,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final Color issueColor;
    final IconData issueIcon;
    switch (issue.severity) {
      case ValidationSeverity.error:
        issueColor = colors.error;
        issueIcon = SkotiqIcons.error;
        break;
      case ValidationSeverity.warning:
        issueColor = colors.warning;
        issueIcon = SkotiqIcons.warning;
        break;
      case ValidationSeverity.info:
        issueColor = colors.info;
        issueIcon = SkotiqIcons.info;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: ListRow.verticalPadding,
        horizontal: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: colors.border))
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            issueIcon,
            size: SkotiqTokens.iconGlyphRow,
            color: issueColor,
          ),
          const SizedBox(width: ListRow.gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        issue.title,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (showCategory) ...[
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      SkotiqChip(label: issue.category.label),
                    ],
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  issue.description,
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
                if (issue.resolutionHint != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        SkotiqIcons.idea,
                        size: SkotiqTokens.iconXs,
                        color: colors.primary,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceXs),
                      Expanded(
                        child: Text(
                          issue.resolutionHint!,
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.primary),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
