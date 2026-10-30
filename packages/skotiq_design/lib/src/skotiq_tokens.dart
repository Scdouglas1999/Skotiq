import 'package:flutter/material.dart';

/// Design tokens for consistent spacing, sizing, and timing across the app.
///
/// Usage:
/// ```dart
/// Padding(padding: SkotiqTokens.paddingMd)
/// Container(margin: SkotiqTokens.marginLg)
/// AnimatedContainer(duration: SkotiqTokens.durationNormal)
/// ```
abstract final class SkotiqTokens {
  SkotiqTokens._();

  // Spacing scale (based on 4px grid)

  /// 4px - Tight spacing for dense UIs
  static const double spaceXs = 4.0;

  /// 8px - Small spacing
  static const double spaceSm = 8.0;

  /// 12px - Medium-small spacing
  static const double spaceMd = 12.0;

  /// 16px - Default spacing
  static const double spaceLg = 16.0;

  /// 20px - Medium-large spacing
  static const double spaceXl = 20.0;

  /// 24px - Large spacing (screen padding)
  static const double space2xl = 24.0;

  /// 32px - Extra large spacing
  static const double space3xl = 32.0;

  /// 48px - Section spacing
  static const double space4xl = 48.0;

  /// 64px - Large section spacing
  static const double space5xl = 64.0;

  // Edge insets (padding/margin)

  static const EdgeInsets paddingXs = EdgeInsets.all(spaceXs);
  static const EdgeInsets paddingSm = EdgeInsets.all(spaceSm);
  static const EdgeInsets paddingMd = EdgeInsets.all(spaceMd);
  static const EdgeInsets paddingLg = EdgeInsets.all(spaceLg);
  static const EdgeInsets paddingXl = EdgeInsets.all(spaceXl);
  static const EdgeInsets padding2xl = EdgeInsets.all(space2xl);

  /// Standard screen padding (24px horizontal, 20px vertical)
  static const EdgeInsets screenPadding = EdgeInsets.symmetric(
    horizontal: space2xl,
    vertical: spaceXl,
  );

  /// Compact screen padding for smaller screens
  static const EdgeInsets screenPaddingCompact = EdgeInsets.symmetric(
    horizontal: spaceLg,
    vertical: spaceMd,
  );

  /// Card internal padding
  static const EdgeInsets cardPadding = EdgeInsets.all(spaceLg);

  /// Dialog internal padding
  static const EdgeInsets dialogPadding = EdgeInsets.all(space2xl);

  /// Horizontal padding inside a button, per size: 10 / 12 / 18 (05 section 6).
  /// The label, not the box, sets a button's width, so the padding scales with
  /// the height rather than staying constant.
  static const double buttonPaddingSm = 10.0;
  static const double buttonPaddingMd = spaceMd;
  static const double buttonPaddingLg = 18.0;

  /// Horizontal padding inside a field (05 section 8). A field is 32 tall and
  /// carries a 14px leading icon, so 12 crowds the glyph and 8 loses the edge.
  static const double inputPaddingHorizontal = 10.0;

  /// Button internal padding (horizontal, vertical), for the Material
  /// fallbacks in the Material theme. Skotiq's own buttons read
  /// [buttonPaddingSm]/[buttonPaddingMd]/[buttonPaddingLg] and their height.
  static const EdgeInsets buttonPadding = EdgeInsets.symmetric(
    horizontal: buttonPaddingMd,
    vertical: spaceSm,
  );

  /// Input field internal padding, for the Material fallbacks.
  static const EdgeInsets inputPadding = EdgeInsets.symmetric(
    horizontal: inputPaddingHorizontal,
    vertical: spaceSm,
  );

  // Border radius scale

  // There are four radii in the Observatory language and no others: 4 for
  // chips, 6 for controls, 8 for panels, 12 for the floating layer. The
  // previous scale (3/5/6/7/10/13) had six values and no rule, so a reviewer
  // could not tell 5 from 6 from 7 by looking, and neither could a designer.
  // The names are unchanged so all 979 existing call sites take the new value
  // without an edit.

  /// 4px - chips, badges, thumbnails, kbd
  static const double radiusXs = 4.0;

  /// 6px - buttons, fields, wells, segmented control
  static const double radiusSm = 6.0;

  /// 6px - inputs. Deliberately equal to [radiusSm]: both mean "a control".
  static const double radiusMd = 6.0;

  /// 6px - alias of [radiusSm], kept for the filled-button call sites.
  static const double radiusButton = 6.0;

  /// 8px - panels, rail items, device cards, score badges
  static const double radiusLg = 8.0;

  /// 12px - dialogs, popovers, command palette
  static const double radiusXl = 12.0;

  /// Fully rounded (for circular elements)
  static const double radiusFull = 999.0;

  // In-use migration radii — now ALIASES of the semantic scale
  //
  // These were value-named constants that let 979 call sites keep their exact
  // literal while losing the magic number. The design pass they were waiting
  // for has happened (`docs/design/overhaul/03-tokens.md` §3.2), so each one
  // now forwards to the semantic radius it maps to and the call sites take the
  // new value without an edit. Wave 4 sed-replaces the names and deletes these.
  //
  // Do NOT add new call sites at these names in fresh code — reach for the
  // semantic scale (radiusXs..radiusXl) instead.

  /// Folds into [radiusXs]. Wave 4 sed-replaces the call sites and deletes it.
  static const double radiusInline2 = radiusXs;

  /// Equals [radiusXs].
  static const double radiusInline4 = radiusXs;

  /// Equals [radiusLg] — the single most common radius in the app.
  static const double radiusInline8 = radiusLg;

  /// Rounds to [radiusLg].
  static const double radiusInline9 = radiusLg;

  /// Rounds to [radiusXl].
  static const double radiusInline11 = radiusXl;

  // Convenience BorderRadius objects
  static final BorderRadius borderRadiusXs = BorderRadius.circular(radiusXs);
  static final BorderRadius borderRadiusSm = BorderRadius.circular(radiusSm);
  static final BorderRadius borderRadiusMd = BorderRadius.circular(radiusMd);
  static final BorderRadius borderRadiusButton = BorderRadius.circular(
    radiusButton,
  );
  static final BorderRadius borderRadiusLg = BorderRadius.circular(radiusLg);
  static final BorderRadius borderRadiusXl = BorderRadius.circular(radiusXl);
  static final BorderRadius borderRadiusFull = BorderRadius.circular(
    radiusFull,
  );

  // Convenience BorderRadius objects for the in-use migration radii above.
  static final BorderRadius borderRadiusInline2 = BorderRadius.circular(
    radiusInline2,
  );
  static final BorderRadius borderRadiusInline4 = BorderRadius.circular(
    radiusInline4,
  );
  static final BorderRadius borderRadiusInline8 = BorderRadius.circular(
    radiusInline8,
  );
  static final BorderRadius borderRadiusInline9 = BorderRadius.circular(
    radiusInline9,
  );
  static final BorderRadius borderRadiusInline11 = BorderRadius.circular(
    radiusInline11,
  );

  // Animation durations
  //
  // Three durations do all the work: 120 for hover, 160 for a state change,
  // 220 for a panel. The rest are aliases kept so call sites compile, and wave
  // 4 folds them in. Motion here CONFIRMS an action; it never decorates one.

  /// 80ms - icon colour on hover
  static const Duration durationMicro = Duration(milliseconds: 80);

  /// 120ms - hover fills
  static const Duration durationFast = Duration(milliseconds: 120);

  /// 160ms - alias of [durationNormal]
  static const Duration durationQuick = Duration(milliseconds: 160);

  /// 160ms - selected state, switch, chip
  static const Duration durationNormal = Duration(milliseconds: 160);

  /// 220ms - rail expand, side panel, discovery drawer, dialog in
  static const Duration durationSmooth = Duration(milliseconds: 220);

  /// 300ms - immersive mode enter/exit only
  static const Duration durationSlow = Duration(milliseconds: 300);

  /// 300ms - alias of [durationSlow]. Deprecated; folded in wave 4.
  static const Duration durationCinematic = durationSlow;

  /// 300ms - alias of [durationSlow]. Deprecated; folded in wave 4.
  static const Duration durationSluggish = durationSlow;

  /// 1500ms - Shimmer/loading animation cycle. The only continuous animation
  /// in the app.
  static const Duration durationShimmer = Duration(milliseconds: 1500);

  /// 2000ms - Pulse animation cycle (status indicators)
  static const Duration durationPulse = Duration(milliseconds: 2000);

  // Animation curves
  //
  // One curve. `Curves.easeOutCubic` is the cubic-bezier(0.215, 0.61, 0.355, 1)
  // the design tokens name, and the eight names below are all pointed at it:
  // no bounce, no overshoot, no spring anywhere in the chrome. Wave 4 deletes
  // every alias and keeps [curveStandard].

  /// The one easing curve.
  static const Curve curveStandard = Curves.easeOutCubic;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveDecelerate = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveAccelerate = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveBounce = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveSharp = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveSnappy = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curvePrecise = curveStandard;

  /// Alias of [curveStandard]. Deprecated; deleted in wave 4.
  static const Curve curveSettle = curveStandard;

  // Icon sizes

  /// 14px - Inline icons
  static const double iconXs = 14.0;

  /// 16px - Small icons
  static const double iconSm = 16.0;

  /// 20px - Default icons
  static const double iconMd = 20.0;

  /// 24px - Large icons
  static const double iconLg = 24.0;

  /// 32px - Extra large icons
  static const double iconXl = 32.0;

  /// 48px - Hero icons
  static const double icon2xl = 48.0;

  // Glyph sizes
  //
  // The icon SCALE above (14 / 16 / 20 / 24 / 32 / 48) sizes an icon that
  // stands on its own. The glyph sizes below size an icon that sits INSIDE a
  // control, where the control's height sets the glyph and the scale has no
  // step for it: 03 section 6 puts the rail at 18, the top bar at 17, buttons
  // and panel heads at 15, chips and instrument pills at 12-13. Each name says
  // which control it belongs to, so a reader never has to ask why a 15 is a 15.

  /// 17px - the glyph in a medium icon button (top bar, page header, capture
  /// bar).
  static const double iconGlyphMd = 17.0;

  /// 15px - the glyph in a small icon button (toolbars).
  static const double iconGlyphSm = 15.0;

  /// 17px - the glyph in a side panel's section strip.
  static const double iconGlyphStrip = 17.0;

  /// 15px - the leading glyph in a button (16 in the large size, which the button
  /// applies itself).
  static const double iconGlyphButton = 15.0;

  /// 15px - the leading glyph in an underline tab.
  static const double iconGlyphTab = 15.0;

  /// 15px - the leading glyph in a list row.
  static const double iconGlyphRow = 15.0;

  /// 15px - the leading glyph in a section title.
  static const double iconGlyphSection = 15.0;

  /// 15px - the leading glyph in a panel head.
  static const double iconGlyphPanelHead = 15.0;

  /// 12px - the glyph inside a chip.
  static const double iconChipGlyph = 12.0;

  /// 13px - the glyph inside an instrument pill and the filter chip's trailing
  /// chevron. A pill's glyph carries state, so it is a step above a chip's.
  static const double iconPillGlyph = 13.0;

  /// 18px - the rail destination glyph and the page-header title glyph.
  static const double iconRail = 18.0;

  /// 17px - the top bar's glyph. Between the toolbar (15) and the rail (18),
  /// because the top bar sits between them.
  static const double iconTopBar = 17.0;

  /// 15px - the leading glyph inside the top bar's command field. The field is
  /// 30 tall and 16 crowds it.
  static const double iconField = 15.0;

  // Responsive breakpoints

  /// Mobile: 0 - 480px
  static const double breakpointMobile = 480.0;

  /// Tablet: 480 - 768px
  static const double breakpointTablet = 768.0;

  /// Small desktop: 768 - 1024px
  static const double breakpointDesktop = 1024.0;

  /// Large desktop: 1024 - 1440px
  static const double breakpointDesktopLg = 1440.0;

  /// Ultra-wide: 1440px+
  static const double breakpointUltraWide = 1920.0;

  // Component sizes

  /// 32px - the standard button height (03 section 3.3).
  static const double buttonHeight = 32.0;

  /// 28px - the small button, and any control inside a dense row.
  static const double buttonHeightSm = 28.0;

  /// 40px - the large button (the hero's Start).
  static const double buttonHeightLg = 40.0;

  /// 32px - the standard field height. Equal to [buttonHeight] on purpose: a
  /// field and a button on the same row have to share a baseline.
  static const double inputHeight = 32.0;

  /// 28px - the dense field, inside a toolbar or a side panel row.
  static const double inputHeightSm = 28.0;

  /// Navigation sidebar width (collapsed)
  static const double sidebarCollapsed = 64.0;

  /// Navigation sidebar width (expanded)
  static const double sidebarExpanded = 220.0;

  /// In-screen Material [AppBar] height (56px).
  ///
  /// Frameless desktop window chrome uses 40px (`ShellChromeMetrics.titleBarHeight`)
  /// instead — do not substitute this value for the custom title bar.
  static const double appBarHeight = 56.0;

  /// Minimum touch target, in logical pixels.
  ///
  /// 48, not 44: the iOS HIG figure is 44 and Material's minimum is 48, so 48
  /// satisfies both platforms — which is the point of having one token. Touch
  /// only; a desktop POINTER target may be 28-32 (see [iconButtonSize]).
  static const double minTouchTarget = 48.0;

  /// 32px - square hit area of a chrome icon button (top bar, toolbar, panel
  /// head). A pointer target, not a touch target.
  static const double iconButtonSize = 32.0;

  /// 28px - the small icon button, inside dense rows and chips.
  static const double iconButtonSizeSm = 28.0;

  /// 36px - the icon button in a side panel's vertical section strip.
  static const double iconButtonSizeStrip = 36.0;

  // Shadows & elevation
  //
  // Cards use borders for separation — not box shadows.
  // Shadows are reserved for floating overlays (menus, toasts, modals, drag
  // feedback) where tonal lift is needed above the base surface.

  /// Subtle shadow for floating menus and toasts
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> shadowSm = [
    BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2)),
  ];

  /// Medium shadow for dropdowns and popovers
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> shadowMd = [
    BoxShadow(color: Color(0x1F000000), blurRadius: 10, offset: Offset(0, 4)),
  ];

  /// Large shadow for dialogs/modals
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> shadowLg = [
    BoxShadow(color: Color(0x33000000), blurRadius: 20, offset: Offset(0, 8)),
  ];

  // Elevation system (dark theme)

  /// Level 1 - Reserved for tonal separation; cards rely on borders instead.
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> elevationLevel1 = [];

  /// Level 2 - Light hover emphasis on interactive panels and drag feedback
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> elevationLevel2 = [
    BoxShadow(color: Color(0x14000000), blurRadius: 5, offset: Offset(0, 2)),
  ];

  /// Level 3 - Floating elevation for modals and dialogs only
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static List<BoxShadow> elevationLevel3(Color accentColor) => shadowLg;

  /// Inset shadow for recessed elements (input fields, wells)
  /// Creates depth by appearing pressed into the surface
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> elevationInset = [
    BoxShadow(
      color: Color(0x66000000), // 40% opacity
      blurRadius: 4,
      offset: Offset(0, 2),
      blurStyle: BlurStyle.inner,
    ),
  ];

  /// Transition shadow from level 1 to level 2 (for hover animations)
  @Deprecated('Use SkotiqDecorations.popover/dialog. Removed in wave 4.')
  static const List<BoxShadow> elevationLevel1to2 = elevationLevel2;

  // Opacity levels
  //
  // The nine below are the Observatory set; everything after them is kept only
  // so the pre-overhaul call sites compile and is deleted in wave 4.

  /// 12% - selected rail item, selected strip item, selected settings item.
  static const double opacityAccentTint = 0.12;

  /// 18% - the checklist "next" disc, and hover on an already-selected row.
  static const double opacityAccentTintHover = 0.18;

  /// 14% - chip fills, score badges, the checklist "done" disc.
  static const double opacityStatusFill = 0.14;

  /// 40% - disabled state.
  static const double opacityDisabled = 0.40;

  /// 8% - dividers: white on the dark palettes, black on light.
  static const double opacityHairline = 0.08;

  /// 22% - the night band's dashed verticals and the "now" line on a chart.
  static const double opacityHairlineStrong = 0.22;

  /// 4% - the almost-invisible 1px ring on a dark panel or field. Tone does
  /// the separating; this only stops an edge vanishing on a poor monitor.
  static const double opacityPanelOutline = 0.04;

  /// 50% - the `primary` ring on a selected panel, step or candidate.
  static const double opacitySelectedRing = 0.50;

  /// 22% - the STATIC 3px halo on a live dot, in `success`. It does not pulse.
  static const double opacityLiveHalo = 0.22;

  /// 50% - the black scrim behind a dialog or the command palette.
  static const double opacityScrim = 0.50;

  /// Muted/secondary content opacity
  static const double opacityMuted = 0.6;

  /// Subtle background overlay. Deprecated; use [opacityStatusFill] or
  /// [opacityAccentTint].
  static const double opacitySubtle = 0.1;

  /// Medium overlay (hover states). Deprecated; deleted in wave 4.
  static const double opacityMedium = 0.2;

  /// Strong overlay (pressed states). Deprecated; deleted in wave 4.
  static const double opacityStrong = 0.3;

  /// Very light primary/accent tint (4%). Deprecated; use
  /// [opacityPanelOutline] for a ring or [opacityAccentTint] for a fill.
  static const double opacityTint = 0.04;

  /// Icon chip and medium-strength accent borders (25%). Deprecated.
  static const double opacityBorderMedium = 0.25;

  /// Selected nav/card accent border emphasis (45%). Deprecated; use
  /// [opacitySelectedRing].
  static const double opacityEmphasisBorder = 0.45;

  /// Half-opacity for disabled filled buttons (50%). Deprecated.
  static const double opacityHalf = 0.5;

  /// Hover border emphasis on interactive cards (85%). Deprecated: a panel has
  /// no hover, and a tappable ROW takes a `surfaceHover` fill instead.
  static const double opacityHoverBorder = 0.85;

  /// KPI/score badge border strength (40%). Deprecated: a chip has no border.
  static const double opacityBadgeBorder = 0.4;

  /// Lighten amount for filled button hover state. Deprecated.
  static const double buttonHoverLighten = 0.04;

  /// Darken amount for filled button border. Deprecated: buttons have no
  /// border.
  static const double buttonBorderDarken = 0.12;

  // Panel row layout (imaging side panel)

  /// Internal padding for grouped panel sections in the imaging side panel.
  static const double panelSectionPadding = 14.0;

  /// Flex weight for label column in label/control row pairs.
  static const int panelRowLabelFlex = 2;

  /// Flex weight for control column in label/control row pairs.
  static const int panelRowControlFlex = 3;

  /// Font size for panel section titles and row labels.
  static const double fontSizePanelLabel = 12.0;

  /// Font size for compact panel captions and section headers.
  static const double fontSizePanelCaption = 10.0;
}
