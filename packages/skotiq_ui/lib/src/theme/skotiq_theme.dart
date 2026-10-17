import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../components/skotiq_switch_style.dart';
import 'skotiq_colors.dart';
import 'skotiq_tokens.dart';
import 'skotiq_typography.dart';

/// App-specific theme modes including red night for astronomy.
enum AppThemeMode {
  /// Standard dark theme
  dark,

  /// Light theme
  light,

  /// Red night vision theme - preserves dark-adapted eyes
  redNight,

  /// Follow system setting (maps to light/dark only)
  system,
}

/// The accent swatches Settings › Appearance offers, PER THEME.
///
/// A dark-safe accent is not light-safe. The dark set's #6EB3EC measures 8.1:1
/// as link text on the dark canvas and 2.4:1 on white, so one shared row of
/// swatches would hand half of them to a theme that cannot read them.
/// `docs/design/overhaul/tools/check_tokens.py` validates every entry twice —
/// as a FILL under the ink [SkotiqColors] would pick for it, and as link
/// TEXT on that theme's `background` and `surface` — and every value below
/// clears 4.5:1 on both counts.
///
/// Red night returns an empty list on purpose: its palette is fixed by the
/// wavelength rule, so the picker is hidden rather than filled with colours
/// that would undo the mode.
abstract final class AppearanceAccents {
  AppearanceAccents._();

  /// Ink 5.83–9.23:1, as link text 5.83–8.68:1 on the dark canvas.
  static const List<Color> dark = <Color>[
    Color(0xFF6EB3EC),
    Color(0xFF43B67A),
    Color(0xFFE0A53E),
    Color(0xFFE86A6A),
    Color(0xFFA48CF2),
    Color(0xFFE77FB3),
    Color(0xFF4FC3C8),
  ];

  /// The same seven hues taken down to where white ink and a white ground both
  /// work: ink 5.46–5.75:1, as link text 5.00–5.27:1.
  static const List<Color> light = <Color>[
    Color(0xFF256F9E),
    Color(0xFF277549),
    Color(0xFF8F5D14),
    Color(0xFFBC3838),
    Color(0xFF6A4FD1),
    Color(0xFFB03A7A),
    Color(0xFF1B7278),
  ];

  /// Swatches for [mode]. Empty means "hide the picker".
  static List<Color> forTheme(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.dark:
        return dark;
      case AppThemeMode.light:
        return light;
      case AppThemeMode.redNight:
        return const <Color>[];
      case AppThemeMode.system:
        // The system row follows the platform brightness at paint time; the
        // caller resolves that before asking. Dark is the app's default.
        return dark;
    }
  }
}

/// Parse a hex accent color (`#RRGGBB` or `RRGGBB`). Returns null if invalid.
Color? parseSkotiqAccentColor(String? hexColor) {
  if (hexColor == null || hexColor.isEmpty) return null;
  try {
    final hex = hexColor.replaceFirst('#', '');
    if (hex.length != 6) return null;
    return Color(int.parse('0xFF$hex'));
  } catch (_) {
    return null;
  }
}

/// Resolve persisted settings (`dark` | `light` | `redNight`) to [ThemeData].
///
/// Shared by desktop [MaterialApp.router], mobile connection UI, and tests so
/// accent + red-night modes stay consistent across entry points.
ThemeData resolveSkotiqThemeData({
  required String themeSetting,
  String? accentColorHex,
}) {
  if (themeSetting == 'redNight') {
    return SkotiqTheme.redNight;
  }

  final accentColor = parseSkotiqAccentColor(accentColorHex);
  if (accentColor == null) {
    switch (themeSetting) {
      case 'light':
        return SkotiqTheme.light;
      case 'dark':
      default:
        return SkotiqTheme.dark;
    }
  }

  switch (themeSetting) {
    case 'light':
      return SkotiqTheme.lightWithAccent(accentColor);
    case 'dark':
    default:
      return SkotiqTheme.darkWithAccent(accentColor);
  }
}

/// Status bar / navigation bar colors aligned with [SkotiqColors.surface].
SystemUiOverlayStyle systemUiOverlayStyleFor(ThemeData theme) {
  final colors = theme.extension<SkotiqColors>();
  final isDark = theme.brightness == Brightness.dark;
  final base = isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
  final surface = colors?.surface ?? theme.colorScheme.surface;
  return base.copyWith(
    statusBarColor: surface,
    systemNavigationBarColor: surface,
    systemNavigationBarIconBrightness: isDark
        ? Brightness.light
        : Brightness.dark,
  );
}

/// Get the appropriate ThemeData for the current app theme mode
ThemeData getThemeForMode(AppThemeMode mode, Brightness systemBrightness) {
  switch (mode) {
    case AppThemeMode.dark:
      return SkotiqTheme.dark;
    case AppThemeMode.light:
      return SkotiqTheme.light;
    case AppThemeMode.redNight:
      return SkotiqTheme.redNight;
    case AppThemeMode.system:
      return systemBrightness == Brightness.dark
          ? SkotiqTheme.dark
          : SkotiqTheme.light;
  }
}

/// Assembles Flutter [ThemeData] from [SkotiqColors], [SkotiqTokens],
/// and [SkotiqTypography] for dark, light, and red-night modes.
class SkotiqTheme {
  SkotiqTheme._();

  /// Built once. `resolveSkotiqThemeData` runs inside the root widget's
  /// `build()`, so a getter here re-derives a `ColorScheme`, a full `TextTheme`
  /// and ~30 sub-themes on every root rebuild only to have `ThemeData.==`
  /// discard the result. The inputs are compile-time constants.
  static final ThemeData dark = _buildTheme(
    SkotiqColors.dark,
    Brightness.dark,
  );

  static final ThemeData light = _buildTheme(
    SkotiqColors.light,
    Brightness.light,
  );

  /// Red night vision theme - uses only red wavelengths for dark adaptation
  static final ThemeData redNight = _buildTheme(
    SkotiqColors.redNight,
    Brightness.dark,
  );

  /// Accent themes are cached one deep per brightness: a user has exactly one
  /// accent at a time, so a single slot absorbs the whole per-frame call rate
  /// and never grows.
  static Color? _darkAccentKey;
  static ThemeData? _darkAccentTheme;
  static Color? _lightAccentKey;
  static ThemeData? _lightAccentTheme;

  /// Generate a dark theme with custom accent color
  static ThemeData darkWithAccent(Color accentColor) {
    final cached = _darkAccentTheme;
    if (cached != null && _darkAccentKey == accentColor) return cached;
    final theme = _buildTheme(
      SkotiqColors.darkWithAccent(accentColor),
      Brightness.dark,
    );
    _darkAccentKey = accentColor;
    _darkAccentTheme = theme;
    return theme;
  }

  /// Generate a light theme with custom accent color
  static ThemeData lightWithAccent(Color accentColor) {
    final cached = _lightAccentTheme;
    if (cached != null && _lightAccentKey == accentColor) return cached;
    final theme = _buildTheme(
      SkotiqColors.lightWithAccent(accentColor),
      Brightness.light,
    );
    _lightAccentKey = accentColor;
    _lightAccentTheme = theme;
    return theme;
  }

  static ThemeData _buildTheme(SkotiqColors colors, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final onPrimary = colors.onPrimary;
    final textTheme = SkotiqTypography.textTheme(colors);
    final shape = RoundedRectangleBorder(
      borderRadius: SkotiqTokens.borderRadiusMd,
    );

    final colorScheme = isDark
        ? ColorScheme.dark(
            primary: colors.primary,
            onPrimary: onPrimary,
            secondary: colors.accent,
            onSecondary: onPrimary,
            surface: colors.surface,
            onSurface: colors.textPrimary,
            error: colors.error,
            onError: onPrimary,
            outline: colors.border,
            outlineVariant: colors.borderHighlight,
            surfaceContainerHighest: colors.surfaceElevated,
          )
        : ColorScheme.light(
            primary: colors.primary,
            onPrimary: onPrimary,
            secondary: colors.accent,
            onSecondary: onPrimary,
            surface: colors.surface,
            onSurface: colors.textPrimary,
            error: colors.error,
            onError: onPrimary,
            outline: colors.border,
            outlineVariant: colors.borderHighlight,
            surfaceContainerHighest: colors.surfaceElevated,
          );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: SkotiqTypography.fontFamily,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      disabledColor: colors.textMuted.withValues(
        alpha: SkotiqTokens.opacityDisabled,
      ),
      unselectedWidgetColor: colors.textMuted,
      splashColor: colors.primary.withValues(alpha: 0.08),
      highlightColor: colors.primary.withValues(alpha: 0.06),
      hoverColor: colors.surfaceHover,
      focusColor: colors.primary.withValues(alpha: 0.35),
      dividerColor: colors.border,
      colorScheme: colorScheme,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      iconTheme: IconThemeData(
        color: colors.textSecondary,
        size: SkotiqTokens.iconMd,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: systemUiOverlayStyleFor(
          ThemeData(brightness: brightness, extensions: [colors]),
        ),
        titleTextStyle: SkotiqTypography.h4.copyWith(
          color: colors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceAlt,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(
          side: BorderSide(color: colors.border.withValues(alpha: 0.7)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surfaceElevated,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        alignment: Alignment.center,
        shape: shape.copyWith(side: BorderSide(color: colors.border)),
        titleTextStyle: SkotiqTypography.h4.copyWith(
          color: colors.textPrimary,
        ),
        contentTextStyle: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceAlt,
        // Flutter's default for helperMaxLines is null, which means a helper
        // that overflows the field width is ELLIPSISED rather than wrapped.
        // Our helpers are sentences that explain a choice ("Broadcast only
        // keeps memory clean; Record also writes JPEG snapshots to disk"), and
        // the half that names the alternative is exactly the half that got
        // cut. Every field carrying one lives in a scrolling panel or dialog,
        // so letting them wrap costs nothing.
        helperMaxLines: 4,
        border: OutlineInputBorder(
          borderRadius: SkotiqTokens.borderRadiusMd,
          borderSide: BorderSide(color: colors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: SkotiqTokens.borderRadiusMd,
          borderSide: BorderSide(color: colors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: SkotiqTokens.borderRadiusMd,
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: SkotiqTokens.borderRadiusMd,
          borderSide: BorderSide(color: colors.error),
        ),
        contentPadding: SkotiqTokens.inputPadding,
        hintStyle: SkotiqTypography.body.copyWith(color: colors.textMuted),
        labelStyle: SkotiqTypography.label.copyWith(
          color: colors.textSecondary,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colors.surfaceAlt;
          }
          if (states.contains(WidgetState.selected)) {
            return colors.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(onPrimary),
        side: BorderSide(color: colors.border, width: 2),
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusXs,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: colors.primary,
        inactiveTrackColor: colors.border,
        thumbColor: colors.primary,
        overlayColor: colors.primary.withValues(alpha: 0.12),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      ),
      // Fallback for Material `Switch` only — prefer [SkotiqSwitch].
      switchTheme: SkotiqSwitchStyle.switchThemeData(colors, onPrimary),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: colors.surfaceAlt,
          disabledForegroundColor: colors.textMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: SkotiqTokens.buttonPadding,
          textStyle: SkotiqTypography.button,
          shape: shape,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.primary,
          foregroundColor: onPrimary,
          disabledBackgroundColor: colors.surfaceAlt,
          disabledForegroundColor: colors.textMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: SkotiqTokens.buttonPadding,
          textStyle: SkotiqTypography.button,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.textPrimary,
          disabledForegroundColor: colors.textMuted,
          side: BorderSide(color: colors.border),
          padding: SkotiqTokens.buttonPadding,
          textStyle: SkotiqTypography.button,
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.primary,
          disabledForegroundColor: colors.textMuted,
          padding: SkotiqTokens.buttonPadding,
          textStyle: SkotiqTypography.button,
          shape: shape,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.border,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: SkotiqTokens.borderRadiusSm,
          border: Border.all(color: colors.border),
        ),
        textStyle: SkotiqTypography.caption.copyWith(
          color: colors.textPrimary,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceElevated,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: shape.copyWith(side: BorderSide(color: colors.border)),
        textStyle: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceElevated,
        contentTextStyle: SkotiqTypography.body.copyWith(
          color: colors.textPrimary,
        ),
        shape: shape.copyWith(side: BorderSide(color: colors.border)),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(SkotiqTokens.radiusLg),
          ),
          side: BorderSide(color: colors.border),
        ),
      ),
      extensions: [colors],
    );
  }
}
