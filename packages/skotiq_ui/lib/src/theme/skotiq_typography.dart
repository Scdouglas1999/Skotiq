import 'package:flutter/material.dart';

import 'skotiq_colors.dart';

/// Typography system for consistent text styling across the app.
///
/// Usage:
/// ```dart
/// Text('Tonight', style: SkotiqTypography.pageTitle)
/// Text('Body text', style: SkotiqTypography.body)
/// Text('12.5"', style: SkotiqTypography.readoutSm)
/// ```
abstract final class SkotiqTypography {
  SkotiqTypography._();

  // Font families

  /// Primary font for UI text — Hanken Grotesk (bundled variable font).
  ///
  /// A quiet, clean grotesque chosen to give the UI a precision-instrument
  /// character without the generic "Inter template" look. Bundled as an asset
  /// (see `skotiq_ui/pubspec.yaml`) so it renders offline in the field.
  static const String fontFamily = 'HankenGrotesk';

  /// Monospace font for technical displays, code, and numeric values —
  /// Spline Sans Mono (bundled variable font). Pairs with [fontFamily] and
  /// renders offline (no runtime font fetch).
  static const String fontFamilyMono = 'SplineSansMono';

  // Font-size scale (numeric tokens)
  //
  // The named TextStyle scale below (h1..h6, body*, label*, mono*, ...) is the
  // GO-FORWARD typography intent — a migrating screen should prefer adopting a
  // full named style (e.g. `SkotiqTypography.bodySm`) over re-specifying a
  // bare fontSize. But the screen layer still carries ~580 inline
  // `TextStyle(fontSize: N, ...)` literals whose surrounding properties
  // (custom weight/height/color/family) don't always line up with a single
  // named style. For those, replacing the bare `fontSize: 13` with
  // `fontSize: SkotiqTypography.fontSize13` is an EXACT-valued,
  // zero-visual-change swap that still kills the magic number.
  //
  // Every fontSize literal currently used in `skotiq_app/lib/screens` has a
  // token here (8, 9, 9.5, 10, 11, 11.5, 12, 12.5, 13, 14, 15, 16, 17, 18, 20,
  // 22, 24, 26, 28). They are value-named on purpose: their job is to enable a
  // mechanical, look-preserving migration, after which a design pass can fold
  // call sites onto the semantic named styles. Do NOT introduce new off-scale
  // sizes in fresh code — adopt a named style instead. Full literal→token
  // mapping table: docs/design/overhaul/archive/token-migration-map.md.

  static const double fontSize8 = 8.0;
  static const double fontSize9 = 9.0;
  static const double fontSize9_5 = 9.5;
  static const double fontSize10 = 10.0;
  static const double fontSize11 = 11.0;
  static const double fontSize11_5 = 11.5;
  static const double fontSize12 = 12.0;
  static const double fontSize12_5 = 12.5;
  static const double fontSize13 = 13.0;
  static const double fontSize14 = 14.0;
  static const double fontSize15 = 15.0;
  static const double fontSize16 = 16.0;
  static const double fontSize17 = 17.0;
  static const double fontSize18 = 18.0;
  static const double fontSize20 = 20.0;
  static const double fontSize22 = 22.0;
  static const double fontSize24 = 24.0;
  static const double fontSize26 = 26.0;
  static const double fontSize28 = 28.0;

  // Observatory scale
  //
  // The go-forward named styles (`docs/design/overhaul/03-tokens.md` §2, and
  // `design-tokens.json` for the numbers). There are no other sizes: 13.5,
  // 12.5, 9 and 16 do not exist in this scale. Rail labels and settings items
  // are [button] (14), settings descriptions are [caption] (12), dialog and
  // empty-state titles are [sectionTitle] (15), checklist titles are
  // [bodyStrong]. A readout is ALWAYS a `readout*` for the value plus
  // [readoutLabel] for the label, never a bare `TextStyle(fontFamily: mono)`.
  //
  // `.copyWith(fontSize:)` is forbidden exactly as `TextStyle(fontSize:)` is;
  // `design_tokens_audit.dart` matches both.

  /// Display - the Tonight hero line, and nothing else.
  /// 28px, Semi-bold
  static const TextStyle display = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: -0.4,
  );

  /// Page title - the screen title in the page header.
  /// 20px, Semi-bold
  static const TextStyle pageTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.3,
    letterSpacing: -0.2,
  );

  /// Section title - section titles inside side panels and settings pages,
  /// dialog titles, empty-state titles.
  /// 15px, Semi-bold
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: 0,
  );

  /// Eyebrow - panel labels, rail group labels, list column headers.
  /// 11px, Semi-bold, UPPERCASE at the call site.
  ///
  /// Pair with [SkotiqColors.textMuted]; the label never competes with the
  /// value beneath it.
  static const TextStyle eyebrow = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: 0.7,
  );

  /// Body strong - names in lists, checklist titles.
  /// 14px, Semi-bold
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.5,
    letterSpacing: 0,
  );

  /// Readout large - hero numbers (camera temperature on Equipment, HFR in the
  /// HUD in glance mode).
  /// 28px, Medium, tabular
  static const TextStyle readoutLg = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 28,
    fontWeight: FontWeight.w500,
    height: 1.15,
    letterSpacing: -0.6,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Readout medium - the standard readout value.
  /// 20px, Medium, tabular
  static const TextStyle readoutMd = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    height: 1.2,
    letterSpacing: -0.3,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Readout small - readouts in dense rows and key/value lists.
  /// 14px, Medium, tabular
  static const TextStyle readoutSm = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Readout extra small - instrument-bar clock and LST, chip counts.
  /// 12px, Medium, tabular
  static const TextStyle readoutXs = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Readout badge - Plan score badge, checklist step number.
  /// 16px, Semi-bold, tabular
  static const TextStyle readoutBadge = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.2,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Readout label - the label under a readout value.
  /// 11px, Medium, UPPERCASE at the call site. Sans, not mono: it is a word.
  static const TextStyle readoutLabel = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.3,
    letterSpacing: 0.5,
  );

  /// Mono caption - night-band legend, `kbd` hints, thumbnail timestamps,
  /// discovery "sim"/"ascom" tags.
  /// 11px, Regular, tabular
  static const TextStyle monoCaption = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.3,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Button large - the hero Start button.
  /// 15px, Medium
  static const TextStyle buttonLg = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    height: 1.4,
    letterSpacing: 0,
  );

  /// Wordmark - the brand mark in the top bar, and nothing else.
  /// 12px, Bold, +1.6 tracking.
  ///
  /// Wider tracking and a heavier weight than any label in the ramp, because
  /// it is a logotype rather than text. It is deliberately NOT reachable from
  /// the type scale: nothing else in the app is allowed to look like the brand.
  static const TextStyle wordmark = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    height: 1.3,
    letterSpacing: 1.6,
  );

  // Heading styles

  /// H1 - Page titles, hero text
  /// 32px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h1 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: -0.5,
  );

  /// H2 - Section titles
  /// 24px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h2 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.33,
    letterSpacing: -0.25,
  );

  /// H3 - Card titles, subsection headers
  /// 20px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h3 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    fontWeight: FontWeight.w600,
    height: 1.4,
    letterSpacing: 0,
  );

  /// H4 - Small headers, widget titles
  /// 16px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h4 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.5,
    letterSpacing: 0,
  );

  /// H5 - Labels, small titles
  /// 14px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h5 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.43,
    letterSpacing: 0,
  );

  /// H6 - Smallest heading
  /// 12px, Semi-bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle h6 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.5,
    letterSpacing: 0.25,
  );

  // Body styles

  /// Body large - Primary reading text
  /// 16px, Regular
  static const TextStyle bodyLg = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
    letterSpacing: 0,
  );

  /// Body - Standard body text
  /// 14px, Regular
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.5,
    letterSpacing: 0,
  );

  /// Body medium - Emphasized body text
  /// 14px, Medium
  static const TextStyle bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: 0,
  );

  /// Body small - Secondary content
  /// 13px, Regular
  static const TextStyle bodySm = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.46,
    letterSpacing: 0,
  );

  // Label styles

  /// Label large - Button text, navigation items
  /// 14px, Medium
  static const TextStyle labelLg = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.43,
    letterSpacing: 0.1,
  );

  /// Label - Form labels, list items
  /// 13px, Medium
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.38,
    letterSpacing: 0.1,
  );

  /// Label small - Helper text, badges
  /// 12px, Medium
  static const TextStyle labelSm = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.33,
    letterSpacing: 0.1,
  );

  /// Label quiet - Sidebar descriptions, de-emphasized helpers
  /// 11px, Medium — pair with [SkotiqColors.textMuted] at the call site
  static const TextStyle labelQuiet = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.27,
    letterSpacing: 0.1,
  );

  /// Label strong - Emphasized small label / inline value (13px, Semi-bold).
  ///
  /// The semibold-small style for a strong key/value label or list-row title:
  /// it fills the 13/w600 gap between [label] (13/w500) and [h6] (12/w600).
  /// Apply the call-site color with `.copyWith(color:)` / `.colored(…)`.
  static const TextStyle labelStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    height: 1.38,
    letterSpacing: 0.1,
  );

  /// Label strong small - Emphasized tiny label (11px, Semi-bold).
  ///
  /// The 11/w600 sibling of [labelStrong] — small section headers and emphasized
  /// chips/badges. Folds the ~29 inline `TextStyle(fontSize: 11, fontWeight:
  /// w600, …)` literals in the screens (same folding caveat as [labelStrong]).
  static const TextStyle labelStrongSm = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.27,
    letterSpacing: 0.1,
  );

  // Caption & utility styles

  /// Caption - Metadata, timestamps
  /// 12px, Regular
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0.1,
  );

  /// Caption small - Very small text
  /// 11px, Regular
  static const TextStyle captionSm = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.27,
    letterSpacing: 0.1,
  );

  /// Overline - Section dividers, category labels
  /// 10px, Semi-bold, uppercase
  ///
  /// Tight tracking (0.6) so uppercased labels read as crisp instrument etching
  /// rather than wide-tracked caps. Hanken Grotesk's even uppercase already
  /// carries the small-label rhythm without exaggerated letter spacing.
  static const TextStyle overline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    height: 1.6,
    letterSpacing: 0.6,
  );

  // Monospace styles (technical displays)

  /// Mono large - Large numeric values, coordinates
  /// 18px, Regular (non-tabular; use [telemetryMd] for live-updating values)
  static const TextStyle monoLg = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 18,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0,
  );

  /// Telemetry large - Hero live numeric displays (countdowns, scores)
  /// 22px, Medium, tabular figures
  static const TextStyle telemetryLg = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.0,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Telemetry medium - Secondary live numeric highlights (ETA, gauges)
  /// 18px, Regular, tabular figures
  static const TextStyle telemetryMd = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 18,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Mono - Standard technical text, code
  /// 14px, Regular
  static const TextStyle mono = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
    letterSpacing: 0,
  );

  /// Mono small - Small numeric displays
  /// 12px, Regular
  static const TextStyle monoSm = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0,
  );

  /// Mono tiny - Very small numeric values
  /// 11px, Regular
  static const TextStyle monoXs = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.27,
    letterSpacing: 0,
  );

  // Special styles

  /// Stat value - Large statistic displays
  /// 36px, Bold
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle statValue = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 36,
    fontWeight: FontWeight.w700,
    height: 1.2,
    letterSpacing: -1,
  );

  /// Stat label - Labels for stat values
  /// 12px, Medium, uppercase
  @Deprecated('Use pageTitle/sectionTitle/display/readout*')
  static const TextStyle statLabel = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.33,
    letterSpacing: 0.3,
  );

  /// Button text
  /// 14px, Medium
  static const TextStyle button = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.43,
    letterSpacing: 0.1,
  );

  /// Button text small
  /// 13px, Medium
  static const TextStyle buttonSm = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.38,
    letterSpacing: 0.1,
  );

  /// Input text
  /// 14px, Regular
  static const TextStyle input = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
    letterSpacing: 0,
  );

  /// Input numeric (monospace)
  /// 14px, Regular
  static const TextStyle inputMono = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
    letterSpacing: 0,
  );

  // Theme integration

  /// Material [TextTheme] wired to Skotiq semantic colors.
  static TextTheme textTheme(SkotiqColors colors) {
    return TextTheme(
      displayLarge: h1.copyWith(color: colors.textPrimary),
      displayMedium: h2.copyWith(color: colors.textPrimary),
      displaySmall: h3.copyWith(color: colors.textPrimary),
      headlineLarge: h2.copyWith(color: colors.textPrimary),
      headlineMedium: h3.copyWith(color: colors.textPrimary),
      headlineSmall: h4.copyWith(color: colors.textPrimary),
      titleLarge: h4.copyWith(color: colors.textPrimary),
      titleMedium: h5.copyWith(color: colors.textPrimary),
      titleSmall: label.copyWith(color: colors.textPrimary),
      bodyLarge: bodyLg.copyWith(color: colors.textPrimary),
      bodyMedium: body.copyWith(color: colors.textPrimary),
      bodySmall: bodySm.copyWith(color: colors.textSecondary),
      labelLarge: labelLg.copyWith(color: colors.textPrimary),
      labelMedium: label.copyWith(color: colors.textSecondary),
      labelSmall: labelSm.copyWith(color: colors.textMuted),
    );
  }

  // Helper methods

  /// Apply a color to any text style
  static TextStyle withColor(TextStyle style, Color color) {
    return style.copyWith(color: color);
  }

  /// Make any style bold
  static TextStyle bold(TextStyle style) {
    return style.copyWith(fontWeight: FontWeight.w700);
  }

  /// Make any style medium weight
  static TextStyle medium(TextStyle style) {
    return style.copyWith(fontWeight: FontWeight.w500);
  }

  /// Make any style italic
  static TextStyle italic(TextStyle style) {
    return style.copyWith(fontStyle: FontStyle.italic);
  }

  /// Enable tabular figures so updating numeric values do not shift layout.
  static TextStyle withTabular(TextStyle style) {
    return style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
  }

  /// Minimum on-screen size, in logical pixels, for secondary-status text when
  /// "glance mode" is active. Below this the readout is too small to parse from
  /// across the room (the couch-grade remote use case). Secondary-status type in
  /// the resting layout sits at 9–13px; glance mode lifts the smallest of those
  /// to a comfortably legible floor while leaving anything already larger alone.
  static const double glanceMinFontSize = 14.0;

  /// Conditionally enlarge a secondary-status [style] for glance mode.
  ///
  /// When [enabled] is false this returns [style] unchanged (zero visual change
  /// — the dense default layout). When true, the style's font size is raised to
  /// at least [glanceMinFontSize] so small telemetry/warning readouts stay
  /// legible at a distance; styles already at or above the floor are returned
  /// untouched so headings don't balloon.
  ///
  /// A null `style.fontSize` (inherit-from-theme) is treated as already large
  /// enough — there's no concrete size to floor against, and the inherited body
  /// size is comfortably above the threshold — so it passes through unchanged.
  static TextStyle glanceStyle(TextStyle style, {required bool enabled}) {
    if (!enabled) return style;
    final size = style.fontSize;
    if (size == null || size >= glanceMinFontSize) return style;
    return style.copyWith(fontSize: glanceMinFontSize);
  }

  /// Add underline to any style
  static TextStyle underline(TextStyle style) {
    return style.copyWith(decoration: TextDecoration.underline);
  }

  /// Convert to uppercase
  static String uppercase(String text) => text.toUpperCase();
}

/// Extension for easy color application
extension TextStyleColorExtension on TextStyle {
  TextStyle colored(Color color) => copyWith(color: color);
}
