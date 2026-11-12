part of '../settings_widgets.dart';

class SettingsPage extends StatelessWidget {
  final String title;

  final String description;

  final List<Widget> children;

  /// Whether to leave out the title and lead line. Null decides from the
  /// enclosing [SettingsFormScope]: hidden in the narrow layout, where the
  /// screen's own header already names the section, and when embedded in
  /// another page, which has its own.
  final bool? hideHeader;

  /// When false, the page renders without its own scroll view: it sits inside
  /// another scrolling container (a merged section), and two same-axis
  /// viewports would split the view into independent panes. Defaults to the
  /// enclosing [SettingsFormScope]'s `embedded` flag.
  final bool? scrollable;

  const SettingsPage({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.hideHeader,
    this.scrollable,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final narrow = SettingsFormScope.narrowOf(context);
    final embedded = SettingsFormScope.embeddedOf(context);
    final scrollable = this.scrollable ?? !embedded;
    final hideHeader = this.hideHeader ?? (narrow || embedded);

    final padding = settingsPagePaddingOf(context);

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hideHeader) ...[
          // `sectionTitle`, not `pageTitle`: the page header above already
          // says "Settings" at page scale and the nav beside this highlights
          // the same name, so a second page-scale title stacked two headings
          // over the first row.
          Text(
            title,
            style: SkotiqTypography.sectionTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          // The ONE lead line a Settings page is allowed (06 §Settings): it
          // carries a fact the rows do not, not a description of the screen.
          Text(
            description,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
        ...children,
      ],
    );

    // Cap the reading width on wide monitors. Settings rows are label-left /
    // control-right, so an unbounded card on a 5120px-wide window put metres of
    // empty space between the two and made every line a sentence-long scan.
    // The narrow layout keeps the full width (it is never wider than the cap).
    final bounded = narrow
        ? content
        : Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: settingsContentMaxWidth,
              ),
              child: content,
            ),
          );

    if (!scrollable) {
      return Padding(padding: padding, child: bounded);
    }
    return SingleChildScrollView(padding: padding, child: bounded);
  }
}

/// The padding of a settings leaf in the layout [context] is in.
EdgeInsets settingsPagePaddingOf(BuildContext context) =>
    SettingsFormScope.narrowOf(context)
        ? SkotiqTokens.paddingLg
        : settingsPagePadding;

/// A settings leaf's padding in the split view.
///
/// The top inset matches the nav column's, so the page's title starts level
/// with the search field beside it instead of a row lower.
const EdgeInsets settingsPagePadding = EdgeInsets.fromLTRB(
  SkotiqTokens.space3xl,
  SkotiqTokens.spaceMd,
  SkotiqTokens.space3xl,
  SkotiqTokens.space2xl,
);

/// Widest a settings leaf's content column may get on desktop.
///
/// 880 px, from the mockup (`mockups/settings.html` `.page`). Settings rows are
/// label-left / control-right, so an unbounded column on a wide window put
/// metres of empty space between the two and made every line a sentence-long
/// scan. The narrow layout keeps the full width (it is never wider than the cap).
const double settingsContentMaxWidth = 880;

class SettingsLoadingState extends StatelessWidget {
  final String message;

  /// See [SettingsPage.scrollable].
  final bool? scrollable;

  const SettingsLoadingState({
    super.key,
    this.message = 'Loading settings...',
    this.scrollable,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final narrow = SettingsFormScope.narrowOf(context);
    final scrollable =
        this.scrollable ?? !SettingsFormScope.embeddedOf(context);

    final padding = settingsPagePaddingOf(context);

    // The skeleton is the loaded page's own anatomy (title, lead line, then
    // eyebrow + panel groups) drawn in `well`, so nothing jumps when the real
    // rows arrive.
    final shimmer = ShimmerLoading(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 220,
            height: SkotiqTokens.spaceXl,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Container(
            width: 320,
            height: SkotiqTokens.spaceMd + 2,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          for (var i = 0; i < 2; i++) ...[
            Container(
              width: 140,
              height: SkotiqTokens.spaceMd,
              decoration: BoxDecoration(
                color: colors.well,
                borderRadius: SkotiqTokens.borderRadiusXs,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Container(
              width: double.infinity,
              height: narrow ? 164 : 188,
              decoration: SkotiqDecorations.panel(colors),
            ),
            const SizedBox(height: SkotiqTokens.space2xl),
          ],
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Text(
                message,
                style: (narrow
                        ? SkotiqTypography.caption
                        : SkotiqTypography.bodySm)
                    .copyWith(color: colors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );

    if (!scrollable) {
      return Padding(padding: padding, child: shimmer);
    }
    return SingleChildScrollView(padding: padding, child: shimmer);
  }
}

class SettingsErrorState extends StatelessWidget {
  final Object error;

  final VoidCallback? onRetry;

  const SettingsErrorState({
    super.key,
    required this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // The ONE error pattern (05 §12): glyph, title, one sentence, one button.
    // No panel around it — the detail pane already is the container.
    return EmptyState(
      icon: LucideIcons.alertTriangle,
      title: 'Settings did not load',
      body: userFacingError(error),
      action: onRetry == null
          ? null
          : SkotiqButton(
              label: 'Try again',
              icon: LucideIcons.refreshCw,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onRetry,
            ),
    );
  }
}

/// A section container with a title and grouped settings rows.
