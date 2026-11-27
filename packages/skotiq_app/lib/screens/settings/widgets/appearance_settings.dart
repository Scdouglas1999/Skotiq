import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/red_night_filter.dart';
import '../../../tours/tour_target.dart';
import 'settings_widgets.dart';

/// The stored value of each theme, and how it is offered.
const List<(String value, String label)> _themeChoices = [
  ('dark', 'Dark'),
  ('light', 'Light'),
  ('redNight', 'Red night'),
];

/// The five stored UI-scale values (`app.dart`) and their labels. The VALUES
/// are the contract with the settings store and must not change; only the way
/// they read does.
const List<String> _uiScaleValues = [
  'Auto',
  'Small (0.8x)',
  'Normal (1.0x)',
  'Large (1.2x)',
  'Extra Large (1.4x)',
];
const List<String> _uiScaleLabels = [
  'Auto',
  'Compact 0.8×',
  'Comfortable 1.0×',
  'Large 1.2×',
  'Extra large 1.4×',
];

class AppearanceSettings extends ConsumerWidget {
  const AppearanceSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final glanceMode = ref.watch(glanceModeProvider);

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final mode = switch (settings.theme) {
          'light' => AppThemeMode.light,
          'redNight' => AppThemeMode.redNight,
          _ => AppThemeMode.dark,
        };
        return SettingsPage(
          key: TourTarget.settingsAppearance.key,
          title: 'Appearance',
          // The one lead line a settings page may carry, and it earns it: red
          // night is the mode nobody guesses the reason for.
          description: 'Theme, accent and density. Red night keeps every pixel '
              'on the red axis so your dark adaptation survives.',
          children: [
            SettingsSection(
              title: 'Theme',
              children: [
                SettingRow(
                  title: 'Theme',
                  subtitle: 'Dark is the default at the telescope. Light suits '
                      'daytime planning. Red night for the field.',
                  trailing: _ThemePicker(
                    selected: settings.theme,
                    onSelected: (value) =>
                        ref.read(appSettingsProvider.notifier).setTheme(value),
                  ),
                  // Three 132 px cards plus two 10 px gaps is 416 px; an even
                  // split of an 880 px page leaves 412 and drops Red night onto
                  // a second row.
                  controlFlex: 2,
                  stackWhenNarrow: true,
                ),
                // In red night the swatch row was two defects at once. The
                // picker is INERT — `resolveSkotiqThemeData` returns the
                // fixed `SkotiqTheme.redNight` before it ever looks at the
                // accent — and it painted seven full-saturation circles
                // (emerald, amber, cyan, magenta) onto a page whose every other
                // pixel is red-shifted, so checking the theme at the telescope
                // was the thing that ruined your dark adaptation. State the
                // scope instead of rendering a control that does nothing.
                if (mode == AppThemeMode.redNight)
                  const SettingRow(
                    title: 'Accent',
                    subtitle: 'Red night is monochrome red, so the accent has '
                        'no effect while it is selected. Your accent applies '
                        'again on the Dark and Light themes.',
                    trailing: SizedBox.shrink(),
                  )
                else
                  SettingRow(
                    title: 'Accent',
                    subtitle: 'Used for the primary action, selection and '
                        'links. Nothing else.',
                    trailing: SettingsColorPicker(
                      selectedColor: settings.accentColor,
                      // Per theme: a dark-safe accent is not light-safe
                      // (03 §1.4).
                      swatches: SettingsColorPicker.swatchesFor(mode),
                      onColorSelected: (color) => ref
                          .read(appSettingsProvider.notifier)
                          .setAccentColor(color),
                    ),
                    stackWhenNarrow: true,
                  ),
              ],
            ),
            SettingsSection(
              title: 'Display',
              children: [
                SettingRow(
                  title: context.l10n.text('generalLanguage'),
                  // The app chrome: menus, the navigation rail, the status
                  // bar and Settings. Both locales state that scope.
                  subtitle: context.l10n.text('generalLanguageDesc'),
                  trailing: SettingsDropdown(
                    key: const ValueKey('appearance.language'),
                    value: settings.language == 'es' ? 'es' : 'en',
                    items: const ['en', 'es'],
                    itemLabels: [
                      context.l10n.text('languageEnglish'),
                      // An unqualified "Español" reads as a finished
                      // translation.
                      '${context.l10n.text('languageSpanish')} (beta)',
                    ],
                    onChanged: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setLanguage(value == 'es' ? 'es' : 'en'),
                    width: 150,
                  ),
                ),
                SettingRow(
                  title: 'Text size',
                  subtitle: 'Scales every label and readout.',
                  trailing: SettingsDropdown(
                    value: settings.fontSize,
                    items: const ['Small', 'Medium', 'Large'],
                    onChanged: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setFontSize(value),
                  ),
                ),
                SettingRow(
                  title: 'UI scale',
                  subtitle: 'Auto follows the display. Compact (0.8×) for a '
                      'laptop at the scope, Large (1.2×) or Extra large (1.4×) '
                      'for a wall display.',
                  trailing: SettingsDropdown(
                    value: settings.uiScale,
                    items: _uiScaleValues,
                    itemLabels: _uiScaleLabels,
                    onChanged: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setUiScale(value),
                  ),
                ),
                // `sidebar_collapsed` is intentionally non-remotable (host-only);
                // hide the row over a remote session so it can't throw.
                if (!isRemoteMode)
                  SettingRow(
                    title: 'Start with the navigation rail collapsed',
                    trailing: SettingsSwitch(
                      value: settings.sidebarCollapsed,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setSidebarCollapsed(value),
                    ),
                  ),
                // Moved off the dashboard (06 §Settings): it is a display
                // preference, and it applied to the sequencer run panels too,
                // so a toggle living on one screen was already the wrong home.
                SettingRow(
                  title: 'Glance mode',
                  subtitle:
                      'Enlarges status readouts so they read from across the '
                      'room.',
                  trailing: SettingsSwitch(
                    value: glanceMode,
                    onChanged: (value) =>
                        ref.read(glanceModeProvider.notifier).setEnabled(value),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The three theme choices as preview cards (06 §Settings: "three 132 px
/// preview cards with a check on the selected one").
///
/// A card shows the theme it names — its own canvas with two panels on it —
/// rather than describing it, which is the whole reason this replaced a
/// dropdown whose three words gave no idea what "Red night" would do to the
/// screen.
class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.selected, required this.onSelected});

  final String selected;
  final void Function(String value) onSelected;

  static const double _gap = 10;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Too narrow for three design-width cards (a phone, where the row
        // stacks under its title): the three share the width in one row
        // rather than wrapping one onto a second row.
        final count = _themeChoices.length;
        final fullRow = count * _ThemeCard.designWidth + (count - 1) * _gap;
        final shared =
            constraints.maxWidth.isFinite && constraints.maxWidth < fullRow
                ? (constraints.maxWidth - (count - 1) * _gap) / count
                : null;
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          alignment: shared == null ? WrapAlignment.end : WrapAlignment.start,
          children: [
            for (final (value, label) in _themeChoices)
              _ThemeCard(
                value: value,
                label: label,
                isSelected: selected == value,
                onTap: () => onSelected(value),
                width: shared ?? _ThemeCard.designWidth,
              ),
          ],
        );
      },
    );
  }
}

class _ThemeCard extends StatefulWidget {
  const _ThemeCard({
    required this.value,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.width = _ThemeCard.designWidth,
  });

  final String value;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final double width;

  /// Card width and preview height, from the mockup.
  static const double designWidth = 132;
  static const double previewHeight = 64;

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _focused = false;

  /// The palette the card is a picture OF — not the one the app is wearing.
  SkotiqColors get _preview => switch (widget.value) {
        'light' => SkotiqColors.light,
        'redNight' => SkotiqColors.redNight,
        _ => SkotiqColors.dark,
      };

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final preview = _preview;
    final ring = widget.isSelected || _focused
        ? colors.primary
        : colors.textPrimary.withValues(
            alpha: SkotiqTokens.opacityPanelOutline,
          );

    return MergeSemantics(
      child: Semantics(
        // Semantics publishes isEnabled only when this field is given; omitting
        // it makes assistive tech announce a live control as disabled.
        enabled: true,
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: widget.isSelected,
        label: widget.label,
        child: InkWell(
          key: ValueKey('settings-theme-${widget.value}'),
          onTap: widget.onTap,
          onFocusChange: (value) => setState(() => _focused = value),
          borderRadius: SkotiqTokens.borderRadiusLg,
          child: Container(
            width: widget.width,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: SkotiqTokens.borderRadiusLg,
              border: Border.all(
                color: ring,
                width: widget.isSelected || _focused ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The Light and Dark previews are pictures of other
                // palettes; in red night they go through the image filter.
                // Through the filter, the Light picture is a block of full
                // red, the brightest thing on the screen; dim it to a hint.
                RedNightImage(
                  child: Opacity(
                    opacity:
                        colors.isRedNight && widget.value == 'light' ? 0.25 : 1,
                    child: _ThemePreview(preview: preview),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: SkotiqTokens.spaceXs + 2,
                  ),
                  child: Row(
                    children: [
                      if (widget.isSelected) ...[
                        Icon(
                          LucideIcons.check,
                          size: SkotiqTokens.spaceMd,
                          color: colors.primary,
                        ),
                        const SizedBox(width: SkotiqTokens.spaceXs + 2),
                      ],
                      Flexible(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.caption.copyWith(
                            color: widget.isSelected
                                ? colors.textPrimary
                                : colors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A miniature of a theme: its canvas, with a rail stripe and a panel on it.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.preview});

  final SkotiqColors preview;

  @override
  Widget build(BuildContext context) {
    Widget block() => Container(
          margin: const EdgeInsets.all(SkotiqTokens.spaceSm),
          decoration: BoxDecoration(
            color: preview.surface,
            borderRadius: SkotiqTokens.borderRadiusXs,
            border: Border.all(color: preview.border),
          ),
        );

    return Container(
      height: _ThemeCard.previewHeight,
      color: preview.background,
      child: Row(
        children: [
          SizedBox(width: SkotiqTokens.spaceXl, child: block()),
          Expanded(child: block()),
        ],
      ),
    );
  }
}
