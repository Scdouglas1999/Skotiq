import 'package:flutter/material.dart';

/// Semantic color palette registered as a [ThemeExtension].
///
/// Resolve at runtime with [of]. Prefer this over static presets in widgets.
///
/// The values mirror `docs/design/overhaul/design-tokens.json`, which is the
/// source of truth for the Observatory design language;
/// `test/design_tokens_sync_test.dart` fails the build if the two drift. The
/// contrast figures quoted below are the ones
/// `docs/design/overhaul/tools/check_tokens.py` prints.
class SkotiqColors extends ThemeExtension<SkotiqColors> {
  final Color primary;
  final Color accent;
  final Color background;
  final Color surface;

  /// Deep inset inside a panel: charts, image areas, empty areas, number
  /// fields. The fifth step of the tonal ladder, BELOW [surface] on the dark
  /// palettes — depth comes from tone, not from borders.
  final Color well;

  @Deprecated('Use well (inset) or surface (container). Removed in wave 4.')
  final Color surfaceAlt;
  final Color surfaceHover;
  final Color surfaceElevated;
  final Color surfaceOverlay;
  final Color border;
  final Color borderHighlight;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color success;
  final Color warning;
  final Color error;
  final Color info;

  /// The mark's warm peach, used sparingly for BRAND and decoration only:
  /// the Trails logo's warm lane and pole star, the "now" marker, and the
  /// running sequence step's progress highlight.
  ///
  /// It must never carry status meaning — a filled chip, a toast, a link — so
  /// `check_tokens.py` keeps it at CIEDE2000 DeltaE >= 15 from [warning] and
  /// holds it to the non-text 3:1 floor on every surface rather than the
  /// text 4.5:1 floor.
  final Color brandWarm;

  /// Fill of the one Start-sequence button. Green rather than [primary] on the
  /// two colour palettes, because starting a run is the night's committing
  /// action and it should not read as "the selected thing".
  final Color startFill;

  /// Ink on [startFill].
  final Color onStart;

  /// The night-band gradient stops: sunset, twilight, astronomical dark, dawn.
  ///
  /// These paint the sky rather than chrome, so they are outside the text
  /// contrast floor. Red night still keeps them on the red axis (G == B),
  /// because the band is the largest coloured area on Tonight.
  final Color bandDusk;
  final Color bandTwilight;
  final Color bandDark;
  final Color bandDawn;

  /// Set only when [primary] is a user-chosen accent that fails the 4.5:1 text
  /// floor for this theme. See [link].
  final Color? linkOverride;

  /// When true, [onPrimary] uses [background] instead of white — e.g. red night
  /// vision mode where white thumbs/checkmarks would ruin dark adaptation.
  final bool useDarkOnPrimary;

  /// True only for the red-night set.
  ///
  /// Needed because red night is a WAVELENGTH constraint, not just a dark
  /// palette, and some surfaces pick colours outside this class — notably
  /// [SkotiqChartColors], whose series are `static const` and therefore
  /// theme-blind. A blue chart series beside a red UI is exactly the
  /// dark-adaptation loss the mode exists to prevent. [useDarkOnPrimary] cannot
  /// stand in for this: it is also true for light and for custom accents that
  /// want dark ink.
  final bool isRedNight;

  const SkotiqColors({
    required this.primary,
    required this.accent,
    required this.background,
    required this.surface,
    required this.well,
    // ignore: deprecated_member_use_from_same_package
    required this.surfaceAlt,
    required this.surfaceHover,
    required this.surfaceElevated,
    required this.surfaceOverlay,
    required this.border,
    required this.borderHighlight,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.success,
    required this.warning,
    required this.error,
    required this.info,
    required this.brandWarm,
    required this.startFill,
    required this.onStart,
    required this.bandDusk,
    required this.bandTwilight,
    required this.bandDark,
    required this.bandDawn,
    this.linkOverride,
    this.useDarkOnPrimary = false,
    this.isRedNight = false,
  });

  /// Foreground color for content on [primary] fills (switches, buttons).
  Color get onPrimary =>
      useDarkOnPrimary ? background : const Color(0xFFFFFFFF);

  /// [primary] as TEXT — links and the selected rail label.
  ///
  /// A dark-safe accent is not light-safe: the dark palette's old #6EB3EC
  /// blue is 8.1:1 as link text on its own canvas but 2.4:1 on white. A stored accent
  /// outlives a theme switch, so [darkWithAccent] / [lightWithAccent] set
  /// [linkOverride] to that theme's own primary when the chosen colour misses
  /// the floor — the fill keeps the user's choice, only the text steps aside.
  Color get link => linkOverride ?? primary;

  /// Deep graphite / blue-black palette with restrained brand-violet accents.
  static const dark = SkotiqColors(
    // The brand violet — the mark's cool lanes run #6E56CF through #E4DEFF and
    // this sits mid-ramp at 7.04:1 as text on the canvas. The old blue
    // (#6EB3EC) survives as the second Appearance swatch and as `info`.
    primary: Color(0xFFA48CF2),
    // Hover/hot step, one lightness notch above primary — the mark's
    // #B9ABFF lane, 9.56:1 under dark ink.
    accent: Color(0xFFB9ABFF),
    background: Color(0xFF0B0D12),
    surface: Color(0xFF12151B),
    well: Color(0xFF0E1116),
    // ignore: deprecated_member_use_from_same_package
    surfaceAlt: Color(0xFF161A21),
    surfaceHover: Color(0xFF1A1E26),
    surfaceElevated: Color(0xFF1C2129),
    surfaceOverlay: Color(0xFF222831),
    border: Color(0xFF232830),
    borderHighlight: Color(0xFF343B46),
    textPrimary: Color(0xFFEDEFF3),
    textSecondary: Color(0xFFB3BAC5),
    // WCAG AA: textMuted carries the 11px eyebrows, readout labels and
    // timestamps, so it is the role the floor is decided by. #8E97A4 measures
    // 5.02:1 worst case (on surfaceOverlay, the dialog ground) and stays
    // dimmer than textSecondary's 7.59:1, so the three-level ladder survives.
    textMuted: Color(0xFF8E97A4),
    success: Color(0xFF43B67A),
    warning: Color(0xFFE0A53E),
    // 4.73:1 worst case, on surfaceOverlay — the tightest colour in this
    // palette, and the first one to re-measure if a surface is ever lifted.
    error: Color(0xFFE86A6A),
    // Deliberately stays the OLD primary blue: status (download captions,
    // NodeStatus.running) must remain distinguishable from selection now that
    // selection is violet.
    info: Color(0xFF6EB3EC),
    // The mark's warm lane and pole star, #FFD9A8 — 11.12:1 on the worst
    // surface and DeltaE 15.61 from warning, so a decoration never reads as
    // a caution.
    brandWarm: Color(0xFFFFD9A8),
    startFill: Color(0xFF43B67A),
    // 7.38:1 on startFill.
    onStart: Color(0xFF06140B),
    bandDusk: Color(0xFF3A3F66),
    bandTwilight: Color(0xFF151A2C),
    bandDark: Color(0xFF0D1015),
    bandDawn: Color(0xFF4A4160),
    // This palette's primary/accent/error/success/warning are all LIGHT tones,
    // so white label text on a filled button scored 2.94:1 (primary), 2.18:1
    // (accent) and 3.75:1 (error — the mount STOP and every destructive
    // button). Dark ink on a light fill is the correct pairing: onPrimary
    // measures 7.04:1 on primary and 9.56:1 on accent.
    useDarkOnPrimary: true,
  );

  /// Cool light palette with a deeper brand-violet primary for contrast.
  static const light = SkotiqColors(
    // 5.75:1 under white ink and 5.27:1 as link text on the canvas. The old
    // blue (#256F9E) survives as the second Appearance swatch and as `info`.
    primary: Color(0xFF6A4FD1),
    // Hover DARKENS in a light palette, so the accent sits one lightness
    // notch below primary; white ink on it measures 7.00:1.
    accent: Color(0xFF5B41C4),
    background: Color(0xFFF3F5F8),
    surface: Color(0xFFFFFFFF),
    well: Color(0xFFEEF1F5),
    // ignore: deprecated_member_use_from_same_package
    surfaceAlt: Color(0xFFF7F8FA),
    surfaceHover: Color(0xFFE6EAEF),
    surfaceElevated: Color(0xFFFFFFFF),
    surfaceOverlay: Color(0xFFFFFFFF),
    border: Color(0xFFDCE1E7),
    borderHighlight: Color(0xFFC6CED8),
    textPrimary: Color(0xFF14181F),
    textSecondary: Color(0xFF4F5966),
    // WCAG AA: #8A939E was only 3.11:1 on the white surface — the worst
    // offender in any palette. #616873 clears the floor on every surface here,
    // 4.65:1 worst case on surfaceHover, which is the darkest ground a light
    // theme puts text on.
    textMuted: Color(0xFF616873),
    // The four status roles are consumed as small STATUS TEXT — the Darkroom
    // step card's "Applied by the last render", an in-progress "Downloading…"
    // caption — and they were originally tuned against `surface` alone, which
    // is the LIGHTEST thing they land on. Darkened, hue and saturation
    // preserved, until each clears 4.5:1 on every surface in this palette;
    // surfaceHover is the one that decides it (4.61–4.66:1).
    // `light_contrast_test.dart` measures all of them so the floor fails a
    // build instead of a review.
    success: Color(0xFF277549),
    warning: Color(0xFF8F5D14),
    error: Color(0xFFBC3838),
    // Keeps its blue, darker than the dark palette's — same reasoning: status
    // must not collide with a violet selection.
    info: Color(0xFF256E99),
    // Deepened peach for a white ground — the logo's #FFD9A8 would sit at
    // 1.7:1 here. The "now" label and frame countdown set it as TEXT, so it
    // is taken down to a burnt orange that clears the 4.5:1 text floor on
    // every light surface (4.87:1 worst, on surfaceHover) and stays DeltaE
    // 16.86 from warning.
    brandWarm: Color(0xFF8A3200),
    startFill: Color(0xFF1E7A47),
    // White ink, 5.34:1 on startFill.
    onStart: Color(0xFFFFFFFF),
    bandDusk: Color(0xFFC9CFE8),
    bandTwilight: Color(0xFF4A5680),
    bandDark: Color(0xFF1B2238),
    bandDawn: Color(0xFFE2C9C0),
  );

  /// Create a dark theme with custom accent color
  /// True when dark ink reads better than white on [fill].
  ///
  /// 0.1791 is the WCAG crossover: solve 1.05/(L+0.05) == (L+0.05)/0.05 and a
  /// fill above it contrasts better with black than with white. A user-chosen
  /// accent can be any colour, so neither ink is safe as a blanket default —
  /// white on a light accent measures as low as 1.32:1 (yellow), while dark ink
  /// on a dark accent is 1.89:1 (navy). Picking per-fill keeps every accent
  /// legible instead of leaving it to chance.
  static bool _prefersDarkInk(Color fill) => fill.computeLuminance() > 0.1791;

  /// WCAG 2.x contrast ratio between two opaque colours.
  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// The stand-in [link] colour for [accentColor], or null when it needs none.
  static Color? _linkFallback(Color accentColor, SkotiqColors base) {
    const floor = 4.5;
    final onBackground = _contrast(accentColor, base.background);
    final onSurface = _contrast(accentColor, base.surface);
    if (onBackground >= floor && onSurface >= floor) return null;
    return base.primary;
  }

  static SkotiqColors darkWithAccent(Color accentColor) {
    return dark.copyWith(
      primary: accentColor,
      accent: _lightenColor(accentColor, 0.15),
      linkOverride: _linkFallback(accentColor, dark),
      useDarkOnPrimary: _prefersDarkInk(accentColor),
    );
  }

  /// Create a light theme with custom accent color
  static SkotiqColors lightWithAccent(Color accentColor) {
    return light.copyWith(
      primary: accentColor,
      accent: _lightenColor(accentColor, 0.15),
      linkOverride: _linkFallback(accentColor, light),
      useDarkOnPrimary: _prefersDarkInk(accentColor),
    );
  }

  /// Helper to lighten a color for accent
  static Color _lightenColor(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + amount).clamp(0.0, 1.0))
        .toColor();
  }

  /// Red night vision theme - designed to preserve dark-adapted eyes
  /// Uses only red wavelengths which minimally affect scotopic (night) vision
  static const redNight = SkotiqColors(
    // 5.29:1 under dark ink and as text on the canvas. The previous #DC2626
    // measured 4.29:1, and #B91C1C as the hover fill 3.20:1 — in this palette
    // hover LIGHTENS, because there is no legible room below.
    primary: Color(0xFFEF3B3B),
    accent: Color(0xFFFF5A5A),
    background: Color(0xFF0A0000),
    surface: Color(0xFF140808),
    well: Color(0xFF0F0404),
    // ignore: deprecated_member_use_from_same_package
    surfaceAlt: Color(0xFF1C0C0C),
    surfaceHover: Color(0xFF241010),
    surfaceElevated: Color(0xFF281212),
    surfaceOverlay: Color(0xFF301616),
    border: Color(0xFF2E1414),
    borderHighlight: Color(0xFF3A1A1A),
    // The red-only constraint is about WAVELENGTH, not dimness, so the text
    // ladder still has to clear the 4.5:1 contrast floor against these
    // surfaces: these three measure 9.86 / 7.46 / 5.35 worst case, stay
    // strictly ordered, and keep red the dominant channel.
    textPrimary: Color(0xFFFFB3B3),
    textSecondary: Color(0xFFF59191),
    textMuted: Color(0xFFE86A6A),
    // The status semantics are read as TEXT, so the same floor binds them. The
    // old pair could not clear it: #B91C1C measured 2.93:1 on surfaceAlt and
    // 2.79:1 on its own 15%-alpha chip (the System Health pill, sampled off the
    // running app), #DC2626 3.93:1.
    //
    // Two rules bracket the repair. Red night is a WAVELENGTH constraint, so
    // the hue stays on the red axis (G == B) and red keeps over half the
    // emitted energy — `success` also reaches the scrubber's selected frame bar
    // through [SkotiqChartColors.selectedFrame], where the red-dominance
    // rule is enforced. And the floor is 4.5:1 on every surface. Between those
    // two the legible red band is narrow, so colour cannot also encode severity
    // ORDER here; the icon and the word carry that, and these three are simply
    // the furthest-apart legal triple.
    //
    // success #FF7373 is the soft end at 6.35:1 worst case; warning #FF4040 is
    // the pure end at 4.84:1. `error` moved #EF5350 -> #EF5252 to put G == B:
    // the old value sat three units off the red axis in BLUE, which is the one
    // channel this palette may not spend.
    success: Color(0xFFFF7373),
    warning: Color(0xFFFF4040),
    error: Color(0xFFEF5252),
    info: Color(0xFFE57373),
    // Red night cannot spend a warm hue: the decoration folds onto the red
    // axis like every other role, a pale red kept DeltaE 18.34 from warning
    // and at 8.26:1 on the worst surface.
    brandWarm: Color(0xFFFF9A9A),
    // Red night has no green to spend on Start, so the button is the palette's
    // own primary; its label and position tell it apart, not its hue.
    startFill: Color(0xFFEF3B3B),
    onStart: Color(0xFF0A0000),
    bandDusk: Color(0xFF3A1414),
    bandTwilight: Color(0xFF140808),
    bandDark: Color(0xFF0A0000),
    bandDawn: Color(0xFF3A1414),
    useDarkOnPrimary: true,
    isRedNight: true,
  );

  @override
  SkotiqColors copyWith({
    Color? primary,
    Color? accent,
    Color? background,
    Color? surface,
    Color? well,
    @Deprecated('Use well (inset) or surface (container). Removed in wave 4.')
    Color? surfaceAlt,
    Color? surfaceHover,
    Color? surfaceElevated,
    Color? surfaceOverlay,
    Color? border,
    Color? borderHighlight,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? success,
    Color? warning,
    Color? error,
    Color? info,
    Color? brandWarm,
    Color? startFill,
    Color? onStart,
    Color? bandDusk,
    Color? bandTwilight,
    Color? bandDark,
    Color? bandDawn,
    Color? linkOverride,
    bool? useDarkOnPrimary,
    bool? isRedNight,
  }) {
    return SkotiqColors(
      primary: primary ?? this.primary,
      accent: accent ?? this.accent,
      background: background ?? this.background,
      surface: surface ?? this.surface,
      well: well ?? this.well,
      // ignore: deprecated_member_use_from_same_package
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
      border: border ?? this.border,
      borderHighlight: borderHighlight ?? this.borderHighlight,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      info: info ?? this.info,
      brandWarm: brandWarm ?? this.brandWarm,
      startFill: startFill ?? this.startFill,
      onStart: onStart ?? this.onStart,
      bandDusk: bandDusk ?? this.bandDusk,
      bandTwilight: bandTwilight ?? this.bandTwilight,
      bandDark: bandDark ?? this.bandDark,
      bandDawn: bandDawn ?? this.bandDawn,
      linkOverride: linkOverride ?? this.linkOverride,
      useDarkOnPrimary: useDarkOnPrimary ?? this.useDarkOnPrimary,
      isRedNight: isRedNight ?? this.isRedNight,
    );
  }

  /// Resolve the active [SkotiqColors] from [context].
  ///
  /// Falls back to [dark] or [light] when the nearest [Theme] has no
  /// extension — e.g. mobile connection [MaterialApp] shells that predate
  /// a theme rebuild, or routes pushed before the parent theme applies.
  static SkotiqColors of(BuildContext context) {
    final extension = Theme.of(context).extension<SkotiqColors>();
    if (extension != null) {
      return extension;
    }
    return Theme.of(context).brightness == Brightness.light
        ? SkotiqColors.light
        : SkotiqColors.dark;
  }

  @override
  SkotiqColors lerp(ThemeExtension<SkotiqColors>? other, double t) {
    if (other is! SkotiqColors) return this;
    return SkotiqColors(
      primary: Color.lerp(primary, other.primary, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      well: Color.lerp(well, other.well, t)!,
      // ignore: deprecated_member_use_from_same_package
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderHighlight: Color.lerp(borderHighlight, other.borderHighlight, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      error: Color.lerp(error, other.error, t)!,
      info: Color.lerp(info, other.info, t)!,
      brandWarm: Color.lerp(brandWarm, other.brandWarm, t)!,
      startFill: Color.lerp(startFill, other.startFill, t)!,
      onStart: Color.lerp(onStart, other.onStart, t)!,
      bandDusk: Color.lerp(bandDusk, other.bandDusk, t)!,
      bandTwilight: Color.lerp(bandTwilight, other.bandTwilight, t)!,
      bandDark: Color.lerp(bandDark, other.bandDark, t)!,
      bandDawn: Color.lerp(bandDawn, other.bandDawn, t)!,
      linkOverride: Color.lerp(linkOverride, other.linkOverride, t),
      useDarkOnPrimary: t < 0.5 ? useDarkOnPrimary : other.useDarkOnPrimary,
      isRedNight: t < 0.5 ? isRedNight : other.isRedNight,
    );
  }

  /// Value equality — load-bearing, not boilerplate.
  ///
  /// [ThemeData.==] compares its extensions by value, so without this an
  /// accent-derived palette (a fresh instance out of [darkWithAccent] every
  /// call) never equals the previous frame's. `Theme.updateShouldNotify` then
  /// fires on every root rebuild and every widget reading this palette rebuilds
  /// with it. Only the const [dark] path is safe without it.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SkotiqColors &&
        other.runtimeType == runtimeType &&
        other.primary == primary &&
        other.accent == accent &&
        other.background == background &&
        other.surface == surface &&
        other.well == well &&
        // ignore: deprecated_member_use_from_same_package
        other.surfaceAlt == surfaceAlt &&
        other.surfaceHover == surfaceHover &&
        other.surfaceElevated == surfaceElevated &&
        other.surfaceOverlay == surfaceOverlay &&
        other.border == border &&
        other.borderHighlight == borderHighlight &&
        other.textPrimary == textPrimary &&
        other.textSecondary == textSecondary &&
        other.textMuted == textMuted &&
        other.success == success &&
        other.warning == warning &&
        other.error == error &&
        other.info == info &&
        other.brandWarm == brandWarm &&
        other.startFill == startFill &&
        other.onStart == onStart &&
        other.bandDusk == bandDusk &&
        other.bandTwilight == bandTwilight &&
        other.bandDark == bandDark &&
        other.bandDawn == bandDawn &&
        other.linkOverride == linkOverride &&
        other.useDarkOnPrimary == useDarkOnPrimary &&
        other.isRedNight == isRedNight;
  }

  /// [Object.hash] takes at most 20 positional arguments and this palette now
  /// carries 28 fields, so the list form is the one that compiles.
  @override
  int get hashCode => Object.hashAll(<Object?>[
    primary,
    accent,
    background,
    surface,
    well,
    // ignore: deprecated_member_use_from_same_package
    surfaceAlt,
    surfaceHover,
    surfaceElevated,
    surfaceOverlay,
    border,
    borderHighlight,
    textPrimary,
    textSecondary,
    textMuted,
    success,
    warning,
    error,
    info,
    brandWarm,
    startFill,
    onStart,
    bandDusk,
    bandTwilight,
    bandDark,
    bandDawn,
    linkOverride,
    useDarkOnPrimary,
    isRedNight,
  ]);
}

/// Shorthand for [SkotiqColors.of] on a [BuildContext].
extension SkotiqThemeContext on BuildContext {
  /// Active semantic palette from the nearest [Theme].
  SkotiqColors get skotiqColors => SkotiqColors.of(this);
}
