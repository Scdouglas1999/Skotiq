import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/tutorial_keys/settings_keys.dart';
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
  final bool isMobile;

  const AppearanceSettings({super.key, this.isMobile = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final glanceMode = ref.watch(glanceModeProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(isMobile: isMobile),
      error: (error, stack) => SettingsErrorState(
        isMobile: isMobile,
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
          key: SettingsTutorialKeys.appearance,
          title: 'Appearance',
          // The one lead line a settings page may carry, and it earns it: red
          // night is the mode nobody guesses the reason for.
          description: 'Theme, accent and density. Red night keeps every pixel '
              'on the red axis so your dark adaptation survives.',
          isMobile: isMobile,
          hideHeader: isMobile,
          children: [
            SettingsSection(
              title: 'Theme',
              isMobile: isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.moon,
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
                  isMobile: isMobile,
                  stackOnMobile: isMobile,
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
                  SettingRow(
                    icon: LucideIcons.palette,
                    title: 'Accent',
                    subtitle: 'Red night is monochrome red, so the accent has '
                        'no effect while it is selected. ${settings.accentColor} '
                        'applies again on the Dark and Light themes.',
                    trailing: const SizedBox.shrink(),
                    isMobile: isMobile,
                  )
                else
                  SettingRow(
                    icon: LucideIcons.palette,
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
                      isMobile: isMobile,
                    ),
                    isMobile: isMobile,
                    stackOnMobile: isMobile,
                  ),
              ],
            ),
            SettingsSection(
              title: 'Display',
              isMobile: isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.type,
                  title: 'Text size',
                  subtitle: 'Scales every label and readout.',
                  trailing: SettingsDropdown(
                    value: settings.fontSize,
                    items: const ['Small', 'Medium', 'Large'],
                    onChanged: (value) => ref
                        .read(appSettingsProvider.notifier)
                        .setFontSize(value),
                    isMobile: isMobile,
                  ),
                  isMobile: isMobile,
                ),
                SettingRow(
                  icon: LucideIcons.zoomIn,
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
                    isMobile: isMobile,
                  ),
                  isMobile: isMobile,
                ),
                // `sidebar_collapsed` is intentionally non-remotable (host-only);
                // hide the row over a remote session so it can't throw.
                if (!isRemoteMode)
                  SettingRow(
                    icon: LucideIcons.panelLeft,
                    title: 'Start with the navigation rail collapsed',
                    trailing: SettingsSwitch(
                      value: settings.sidebarCollapsed,
                      onChanged: (value) => ref
                          .read(appSettingsProvider.notifier)
                          .setSidebarCollapsed(value),
                    ),
                    isMobile: isMobile,
                  ),
                // Moved off the dashboard (06 §Settings): it is a display
                // preference, and it applied to the sequencer run panels too,
                // so a toggle living on one screen was already the wrong home.
                SettingRow(
                  icon: LucideIcons.eye,
                  title: 'Glance mode',
                  subtitle:
                      'Enlarges status readouts so they read from across the '
                      'room.',
                  trailing: SettingsSwitch(
                    value: glanceMode,
                    onChanged: (value) =>
                        ref.read(glanceModeProvider.notifier).setEnabled(value),
                  ),
                  isMobile: isMobile,
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

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      alignment: WrapAlignment.end,
      children: [
        for (final (value, label) in _themeChoices)
          _ThemeCard(
            value: value,
            label: label,
            isSelected: selected == value,
            onTap: () => onSelected(value),
          ),
      ],
    );
  }
}

class _ThemeCard extends StatefulWidget {
  const _ThemeCard({
    required this.value,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String value;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  /// Card width and preview height, from the mockup.
  static const double width = 132;
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
            width: _ThemeCard.width,
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
                _ThemePreview(preview: preview),
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
