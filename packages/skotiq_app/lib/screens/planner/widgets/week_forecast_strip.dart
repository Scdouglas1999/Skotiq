import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// "This Week" planner tab content — a ranked, at-a-glance forecast strip of
/// the upcoming nights for the active campaign's still-incomplete targets.
///
/// Renders one [SkotiqCard] per [NightForecast] in a horizontally
/// scrollable row, ordered chronologically. Each card shows the weekday/date,
/// a clarity score visual mapped to the semantic status colors, the clear-vs-
/// total dark hours, and the one or two targets that are most up that night.
/// The single best-scoring night ([WeekForecast.bestNight]) is highlighted via
/// the card's selected accent.
///
/// Fail-closed is structural: the widget never fabricates a clear night.
///   * A provider error surfaces as a [SkotiqBanner] (the forecast feed /
///     site configuration failed — the operator must see why).
///   * A [WeekForecast] that is not [WeekForecast.available] renders only a
///     warning banner with the honest reason and *no* night cards.
///   * A per-night [NightForecast] that is not [NightForecast.forecastAvailable]
///     renders a muted "No forecast" card rather than an implied clear sky.
class WeekForecastStrip extends ConsumerWidget {
  const WeekForecastStrip({super.key});

  /// Fixed card width — wide enough for the date header, score bar, hours, and
  /// up to two target names without truncating the common case, narrow enough
  /// that several nights are visible at once in the horizontal scroller.
  static const double _cardWidth = 168;

  /// Height of the loading skeleton / card row. Cards size to content, but the
  /// skeleton needs an explicit extent inside the bounded scroller. Sized to
  /// comfortably fit the tallest card body (the per-night "No forecast" card,
  /// whose centered icon + two-line reason is taller than the score-bar layout)
  /// plus the scroller's vertical padding, so no card body overflows.
  static const double _stripHeight = 216;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final forecastAsync = ref.watch(weekForecastProvider);

    return forecastAsync.when(
      loading: () => const _ForecastSkeletonStrip(),
      error: (error, _) => Padding(
        padding: SkotiqTokens.screenPadding,
        child: SkotiqBanner(
            title: 'Forecast unavailable',
            message: error.toString(),
            tone: BannerTone.error,
            action: SkotiqButton(
              label: 'Retry',
              icon: LucideIcons.refreshCw,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => ref.invalidate(weekForecastProvider),
            )),
      ),
      data: (week) {
        if (!week.available) {
          // Whole-lookahead failure — show the honest reason, no night cards.
          // This is the fail-closed contract: never render fabricated nights.
          return Padding(
            padding: SkotiqTokens.screenPadding,
            child: Align(
              alignment: Alignment.topLeft,
              child: SkotiqBanner(
                title: week.unavailableReason ?? 'Forecast unavailable',
                tone: BannerTone.warning,
              ),
            ),
          );
        }

        if (week.nights.isEmpty) {
          // Available but with nothing to rank (no incomplete targets / empty
          // lookahead). Honest empty state rather than a blank strip.
          return const EmptyState(
            icon: LucideIcons.cloudMoon,
            title: 'Nothing to forecast yet',
            body: 'Add targets with integration goals to see the best upcoming '
                'nights for your project.',
          );
        }

        final best = week.bestNight;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceLg,
                SkotiqTokens.spaceLg,
                0,
              ),
              child: SectionHeader(
                title: 'This week',
                subtitle: 'Best nights for your project targets',
              ),
            ),
            SizedBox(
              height: _stripHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: SkotiqTokens.screenPadding,
                itemCount: week.nights.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: SkotiqTokens.spaceMd),
                itemBuilder: (context, index) {
                  final night = week.nights[index];
                  return _NightCard(
                    night: night,
                    // Identity match: the best night is the exact instance
                    // returned by bestNight, so reference equality is safe and
                    // avoids highlighting a tied-but-different night.
                    isBest: best != null && identical(night, best),
                    colors: colors,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One night's forecast card.
class _NightCard extends StatelessWidget {
  const _NightCard({
    required this.night,
    required this.isBest,
    required this.colors,
  });

  final NightForecast night;
  final bool isBest;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: WeekForecastStrip._cardWidth,
      child: SkotiqPanel(
          selected: isBest,
          padding: SkotiqTokens.cardPadding,
          child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Per-night unavailability is honest: a muted "No forecast" card, never a
    // fabricated clear night.
    if (!night.forecastAvailable) {
      return _unavailableBody();
    }

    // A night with no astronomical darkness (e.g. high-latitude summer) is a
    // real, available result — there is simply nothing to image.
    final hasDarkness = night.darkHours > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: SkotiqTokens.spaceMd),
        if (!hasDarkness)
          _noDarknessBody()
        else ...[
          _scoreBar(),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _darkHoursRow(),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Expanded(child: _targets()),
        ],
      ],
    );
  }

  /// Weekday + day-of-month header, with a "best" marker on the highlighted
  /// night so the selection reads clearly even at a glance.
  Widget _header() {
    return Row(
      children: [
        Expanded(
          child: Text(
            _weekdayDate(night.nightDateLocal),
            style:
                SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
          ),
        ),
        if (isBest) ...[
          const SizedBox(width: SkotiqTokens.spaceXs),
          Icon(
            LucideIcons.star,
            size: SkotiqTokens.iconXs,
            color: colors.accent,
          ),
        ],
      ],
    );
  }

  Widget _unavailableBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  LucideIcons.cloudOff,
                  size: SkotiqTokens.iconLg,
                  color: colors.textMuted,
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'No forecast',
                  style:
                      SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
                ),
                if (night.unavailableReason != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    night.unavailableReason!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _noDarknessBody() {
    return Expanded(
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.sun,
              size: SkotiqTokens.iconLg,
              color: colors.textMuted,
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              'No astronomical darkness',
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  /// Clarity score visual: a [StatusDot] in the score's semantic color plus a
  /// filled track whose fill fraction is the score and whose color maps
  /// 0..1 → error/warning/success. Alpha overlays only — no hardcoded colors.
  Widget _scoreBar() {
    final score = night.score;
    final scoreColor = _scoreColor(score, colors);
    return Row(
      children: [
        StatusDot(color: scoreColor),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: ClipRRect(
            borderRadius: SkotiqTokens.borderRadiusFull,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  children: [
                    Container(
                      height: SkotiqTokens.spaceSm,
                      color: scoreColor.withValues(
                        alpha: SkotiqTokens.opacityStatusFill,
                      ),
                    ),
                    Container(
                      height: SkotiqTokens.spaceSm,
                      width: constraints.maxWidth * score.clamp(0.0, 1.0),
                      color: scoreColor,
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Clear vs total dark hours, e.g. "5.1 / 7.0h clear", in mono so the figures
  /// line up across cards.
  Widget _darkHoursRow() {
    final clear = night.clearDarkHours.toStringAsFixed(1);
    final dark = night.darkHours.toStringAsFixed(1);
    return Row(
      children: [
        Icon(
          LucideIcons.moon,
          size: SkotiqTokens.iconXs,
          color: colors.textSecondary,
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Flexible(
          child: Text(
            '$clear / ${dark}h clear',
            style:
                SkotiqTypography.monoSm.copyWith(color: colors.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// The top one-or-two targets that are up this night.
  Widget _targets() {
    if (night.bestTargets.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          'No targets up',
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
      );
    }

    final shown = night.bestTargets.take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final target in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: Row(
              children: [
                Icon(
                  LucideIcons.target,
                  size: SkotiqTokens.iconXs,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Expanded(
                  child: Text(
                    target.targetName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Maps a 0..1 clarity score to a semantic status color:
  /// clear → success, mid → warning, cloudy → error.
  static Color _scoreColor(double score, SkotiqColors colors) {
    if (score >= 0.66) return colors.success;
    if (score >= 0.33) return colors.warning;
    return colors.error;
  }

  /// Formats a local night date as e.g. "Fri 30".
  static String _weekdayDate(DateTime date) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    // DateTime.weekday is 1 (Mon) .. 7 (Sun).
    final name = weekdays[(date.weekday - 1) % 7];
    return '$name ${date.day}';
  }
}

/// Horizontal row of shimmering skeleton cards shown while the forecast loads.
class _ForecastSkeletonStrip extends StatelessWidget {
  const _ForecastSkeletonStrip();

  static const int _skeletonCount = 5;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ShimmerLoading(
      child: SizedBox(
        height: WeekForecastStrip._stripHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: SkotiqTokens.screenPadding,
          itemCount: _skeletonCount,
          separatorBuilder: (_, __) =>
              const SizedBox(width: SkotiqTokens.spaceMd),
          itemBuilder: (_, __) => Container(
            width: WeekForecastStrip._cardWidth,
            padding: SkotiqTokens.cardPadding,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusMd,
              border: Border.all(color: colors.border),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonText(width: 80, height: 14),
                SizedBox(height: SkotiqTokens.spaceMd),
                SkeletonText(height: 8),
                SizedBox(height: SkotiqTokens.spaceSm),
                SkeletonText(width: 110, height: 11),
                SizedBox(height: SkotiqTokens.spaceMd),
                SkeletonText(width: 120, height: 11),
                SizedBox(height: SkotiqTokens.spaceXs),
                SkeletonText(width: 90, height: 11),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
