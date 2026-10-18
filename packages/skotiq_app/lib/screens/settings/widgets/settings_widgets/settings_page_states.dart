part of '../settings_widgets.dart';

class SettingsPage extends StatelessWidget {
  final String title;

  final String description;

  final List<Widget> children;

  final bool isMobile;

  /// If true, don't show title/description (used when mobile header already shows title)

  final bool hideHeader;

  /// When false, the page renders without its own scroll view — used when it's
  /// embedded inside another scrolling container (e.g. a merged section) so two
  /// same-axis viewports don't fight and split the view into independent panes.

  final bool scrollable;

  const SettingsPage({
    super.key,
    required this.title,
    required this.description,
    required this.children,
    this.isMobile = false,
    this.hideHeader = false,
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final padding = isMobile ? SkotiqTokens.paddingLg : settingsPagePadding;

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
    // Mobile keeps the full width (it is never wider than the cap anyway).
    final bounded = isMobile
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

/// A settings leaf's desktop padding.
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
/// scan. Mobile keeps the full width (it is never wider than the cap anyway).
const double settingsContentMaxWidth = 880;

class SettingsLoadingState extends StatelessWidget {
  final bool isMobile;

  final String message;

  /// See [SettingsPage.scrollable] — false when embedded in another scroll view.
  final bool scrollable;

  const SettingsLoadingState({
    super.key,
    this.isMobile = false,
    this.message = 'Loading settings...',
    this.scrollable = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final padding = isMobile ? SkotiqTokens.paddingLg : settingsPagePadding;

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
              height: isMobile ? 164 : 188,
              decoration: SkotiqDecorations.panel(colors),
            ),
            const SizedBox(height: SkotiqTokens.space2xl),
          ],
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Text(
                message,
                style: (isMobile
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
  final bool isMobile;

  final Object error;

  final VoidCallback? onRetry;

  const SettingsErrorState({
    super.key,
    required this.error,
    this.isMobile = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // The ONE error pattern (05 §12): glyph, title, one sentence, one button.
    // No panel around it — the detail pane already is the container.
    return EmptyState(
      icon: LucideIcons.alertTriangle,
      title: 'Settings did not load',
      body: error.toString(),
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
