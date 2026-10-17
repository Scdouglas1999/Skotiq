// Component C8 (attribution half) — the HiPS survey attribution badge.
//
// CDS and the survey publishers ask HiPS clients to display the survey's
// `obs_copyright` credit whenever its imagery is shown (it is part of the data
// licence, e.g. the STScI Digitized Sky Survey acknowledgement that must
// accompany any DSS-derived image). This badge renders that credit, parsed from
// the survey `properties` document into [HipsProperties.obsCopyright] /
// [HipsProperties.creator], in the design system's quiet on-canvas chrome style
// — and only while HiPS imagery is actually visible.
//
// It is a small, pure presentation widget: it takes the resolved
// [HipsProperties] (or `null` when none is resolved) and whether the layer is
// currently showing imagery, and renders the credit pill or nothing. It owns no
// fetch logic and no provider reads, so it composes cleanly into the framing
// `Stack` next to the tile layer and is trivially testable.
//
// When the survey publishes an [HipsProperties.obsCopyrightUrl] the badge is
// tappable and opens it in the external browser (the canonical
// attribution-page link), matching how the settings screens launch external
// URLs. When no URL is published the badge is non-interactive text.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
// HipsProperties is the parsed survey metadata carrying the attribution fields.
// It is exported from skotiq_core's public barrel, but the framing widgets
// import the core src models directly (matching the painters' convention), so
// it is imported via the barrel here where it is public.
import 'package:skotiq_core/skotiq_core.dart' show HipsProperties;
import 'package:url_launcher/url_launcher.dart';

/// A quiet on-canvas pill crediting the HiPS survey whose imagery is currently
/// displayed, shown only while [visible] is true and [properties] carries an
/// attribution.
///
/// Renders [HipsProperties.obsCopyright] when present, else falls back to the
/// publisher [HipsProperties.creator]; if neither is published the badge renders
/// nothing (an empty [SizedBox]) rather than inventing a credit. When
/// [HipsProperties.obsCopyrightUrl] is present the pill is tappable and opens it
/// externally.
class HipsAttributionBadge extends StatelessWidget {
  /// The resolved survey metadata, or `null` when no HiPS survey is resolved.
  final HipsProperties? properties;

  /// Whether HiPS imagery is currently visible. The credit is only shown while
  /// the imagery it credits is on screen (the licence requirement), so the
  /// screen passes its "layer active and has imagery" condition here.
  final bool visible;

  /// A static publisher acknowledgement to show when no `properties` document
  /// is resolved (see [HipsSurveyEntry.attributionCredit]).
  ///
  /// Attribution attaches to the IMAGERY, so it cannot be contingent on a
  /// metadata fetch. Six of the eight framing surveys have no verified pyramid,
  /// so no `properties` is fetched for them — yet their imagery still streams
  /// through the hips2fits cutout path, and it rendered with no credit at all.
  /// The caller passes the registry's static credit here as the floor.
  final String? fallbackCredit;

  /// Attribution page paired with [fallbackCredit].
  final String? fallbackCreditUrl;

  const HipsAttributionBadge({
    super.key,
    required this.properties,
    required this.visible,
    this.fallbackCredit,
    this.fallbackCreditUrl,
  });

  /// The credit text to display: the survey copyright, else the creator, else
  /// the caller's static [fallbackCredit], else `null` when nothing is known.
  ///
  /// A live `properties` document is preferred because it is the publisher's
  /// current wording; the static credit is the guarantee that *some* correct
  /// credit is always shown.
  String? get _creditText {
    final props = properties;
    final copyright = props?.obsCopyright;
    if (copyright != null && copyright.isNotEmpty) return copyright;
    final creator = props?.creator;
    if (creator != null && creator.isNotEmpty) return creator;
    final fallback = fallbackCredit;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    return null;
  }

  /// The attribution URL matching whichever credit [_creditText] resolved to.
  String? get _creditUrl {
    final props = properties;
    final copyright = props?.obsCopyright;
    final creator = props?.creator;
    final fromProperties = (copyright != null && copyright.isNotEmpty) ||
        (creator != null && creator.isNotEmpty);
    if (fromProperties) {
      final url = props?.obsCopyrightUrl;
      // A resolved credit with no published URL must not borrow the static
      // entry's link — it could point at a different publisher's page.
      return (url != null && url.isNotEmpty) ? url : null;
    }
    return fallbackCreditUrl;
  }

  Future<void> _openAttributionUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // External browser, matching the about/settings screens' link handling.
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final credit = _creditText;
    if (!visible || credit == null) {
      return const SizedBox.shrink();
    }

    final colors = context.skotiqColors;
    final url = _creditUrl;
    final hasUrl = url != null && url.isNotEmpty;

    // The credit cap has to be derived from the space actually available, not
    // fixed. `maxWidth: 360` was a constant, so on a 360 px phone the pill came
    // to 360 + icon + gap + padding + border and overflowed the canvas by 44 px
    // (34 px landscape, 14 px at 390 px). 360 survives only as an UPPER bound so
    // a long DSS copyright still ellipsizes rather than running the full width of
    // a desktop canvas.
    //
    // Chrome subtracted below = the pill's own horizontal padding (both sides),
    // the leading icon, the gap after it, and the 1 px border on each side.
    const chromeWidth = SkotiqTokens.spaceMd * 2 +
        SkotiqTokens.iconXs +
        SkotiqTokens.spaceXs +
        2;
    const preferredCreditWidth = 360.0;

    final pill = LayoutBuilder(
      builder: (context, constraints) {
        // An unbounded width (an unconstrained Row/Stack parent) means "take
        // what you need", so fall back to the preferred cap rather than
        // producing Infinity.
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth - chromeWidth
            : preferredCreditWidth;
        // Never below a legible floor: at that point ellipsizing to a few
        // characters is worse than letting the pill be the widest thing in the
        // band, and the canvas is too narrow to be showing this chrome anyway.
        final creditMaxWidth =
            math.max(64.0, math.min(preferredCreditWidth, available));

        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceXs,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceOverlay
                .withValues(alpha: SkotiqTokens.opacityHoverBorder),
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: Border.all(
              color: colors.border
                  .withValues(alpha: SkotiqTokens.opacitySubtle),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                SkotiqIcons.info,
                size: SkotiqTokens.iconXs,
                color: colors.textMuted,
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              // Constrain the credit so a long copyright string wraps/ellipsizes
              // rather than overflowing the canvas chrome.
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: creditMaxWidth),
                child: Text(
                  credit,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.overline.copyWith(
                    color: hasUrl ? colors.textSecondary : colors.textMuted,
                    decoration: hasUrl ? TextDecoration.underline : null,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (!hasUrl) return pill;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _openAttributionUrl(url),
        child: Tooltip(
          message: url,
          child: pill,
        ),
      ),
    );
  }
}
