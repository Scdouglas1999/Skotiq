import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../accessible_dropdown.dart';

/// Provides descriptions for each stretch method, used in tooltips.
const Map<AutoStretchMethod, String> _methodDescriptions = {
  AutoStretchMethod.stf:
      'Screen Transfer Function - adaptive stretch preserving detail',
  AutoStretchMethod.histogram: 'Histogram equalization for even distribution',
  AutoStretchMethod.asinh: 'Arcsinh stretch - good for high dynamic range',
  AutoStretchMethod.log: 'Logarithmic stretch - reveals faint detail',
  AutoStretchMethod.gamma: 'Simple gamma correction',
};

/// Display names for each stretch method.
const Map<AutoStretchMethod, String> _methodNames = {
  AutoStretchMethod.stf: 'STF',
  AutoStretchMethod.histogram: 'Histogram',
  AutoStretchMethod.asinh: 'Asinh',
  AutoStretchMethod.log: 'Log',
  AutoStretchMethod.gamma: 'Gamma',
};

/// Auto-stretch controls for the imaging screen.
///
/// Can display in compact mode (for toolbar) or expanded mode (for panel/dialog).
/// Compact mode shows a toggle, method dropdown, and settings button.
/// Expanded mode shows all parameters including sliders for fine-tuning.
class StretchControls extends ConsumerStatefulWidget {
  /// When true, shows minimal toolbar-friendly controls.
  /// When false, shows full expanded controls with all sliders.
  final bool compact;

  const StretchControls({
    super.key,
    this.compact = true,
  });

  @override
  ConsumerState<StretchControls> createState() => _StretchControlsState();
}

class _StretchControlsState extends ConsumerState<StretchControls> {
  Future<bool> _save(AutoStretchSettings settings) async {
    try {
      await ref.read(autoStretchSettingsProvider.notifier).update(settings);
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the auto-stretch settings.'),
          ),
        );
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final settings = ref.watch(autoStretchSettingsProvider);
    final rawLoading =
        ref.watch(currentImageProvider)?.rawLoadStatus == RawLoadStatus.loading;

    if (widget.compact) {
      return _CompactStretchControls(
        settings: settings,
        colors: colors,
        rawLoading: rawLoading,
        onSettingsChanged: _save,
      );
    }

    return _ExpandedStretchControls(
      settings: settings,
      colors: colors,
      onSettingsChanged: _save,
    );
  }
}

/// Compact controls for toolbar display.
class _CompactStretchControls extends StatelessWidget {
  final AutoStretchSettings settings;
  final SkotiqColors colors;
  final bool rawLoading;
  final FutureOr<bool> Function(AutoStretchSettings) onSettingsChanged;

  const _CompactStretchControls({
    required this.settings,
    required this.colors,
    required this.rawLoading,
    required this.onSettingsChanged,
  });

  void _showAdvancedDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => _StretchSettingsDialog(
        settings: settings,
        colors: colors,
        onSettingsChanged: onSettingsChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Toggle switch with label
        SkotiqTooltip(
          message: rawLoading
              ? 'Loading HQ raw — stretch will apply when ready'
              : 'On: the frame stretched to show faint detail. Off: linear, '
                  'as recorded.',
          position: SkotiqTooltipPosition.bottom,
          child: SkotiqSwitchRow(
            label: rawLoading ? 'Stretch (HQ…)' : 'Stretch',
            expanded: false,
            compact: true,
            value: settings.enabled,
            labelStyle: SkotiqTypography.caption.copyWith(
                color: settings.enabled
                    ? colors.textPrimary
                    : colors.textSecondary),
            onChanged: (value) {
              unawaited(
                Future<bool>.sync(
                  () => onSettingsChanged(settings.copyWith(enabled: value)),
                ),
              );
            },
          ),
        ),

        const SizedBox(width: 12),

        // Method dropdown
        if (settings.enabled) ...[
          SkotiqTooltip(
            message: _methodDescriptions[settings.method] ?? '',
            position: SkotiqTooltipPosition.bottom,
            child: _MethodDropdown(
              value: settings.method,
              colors: colors,
              onChanged: (method) {
                if (method != null) {
                  unawaited(
                    Future<bool>.sync(
                      () => onSettingsChanged(
                        settings.copyWith(method: method),
                      ),
                    ),
                  );
                }
              },
            ),
          ),

          const SizedBox(width: 8),

          // Settings button
          SkotiqTooltip(
            message: 'Advanced stretch settings',
            position: SkotiqTooltipPosition.bottom,
            child: _CompactIconButton(
              icon: SkotiqIcons.settings2,
              colors: colors,
              onPressed: () => _showAdvancedDialog(context),
            ),
          ),
        ],
      ],
    );
  }
}

/// Full expanded controls for panel or dialog.
class _ExpandedStretchControls extends StatelessWidget {
  final AutoStretchSettings settings;
  final SkotiqColors colors;
  final FutureOr<bool> Function(AutoStretchSettings) onSettingsChanged;

  const _ExpandedStretchControls({
    required this.settings,
    required this.colors,
    required this.onSettingsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Enable toggle and method selection
        SkotiqSwitchRow(
          label: 'Auto-Stretch',
          value: settings.enabled,
          labelStyle:
              SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary),
          onChanged: (value) {
            onSettingsChanged(settings.copyWith(enabled: value));
          },
        ),

        const SizedBox(height: 16),

        // Method selection
        _SettingRow(
          label: 'Method',
          tooltip: 'Select the stretch algorithm to use',
          colors: colors,
          child: _MethodDropdown(
            value: settings.method,
            colors: colors,
            isExpanded: true,
            onChanged: settings.enabled
                ? (method) {
                    if (method != null) {
                      onSettingsChanged(settings.copyWith(method: method));
                    }
                  }
                : null,
          ),
        ),

        const SizedBox(height: 12),

        // Shadow clip slider
        _SliderSetting(
          label: 'Shadow clip',
          tooltip:
              'Controls shadow clipping in standard deviations from median. '
              'Lower values clip more shadows.',
          value: settings.shadowClip,
          min: -5.0,
          max: 0.0,
          divisions: 50,
          enabled: settings.enabled,
          colors: colors,
          formatValue: (v) => v.toStringAsFixed(2),
          onChanged: (value) {
            onSettingsChanged(settings.copyWith(shadowClip: value));
          },
        ),

        const SizedBox(height: 12),

        // Highlight clip slider
        _SliderSetting(
          label: 'Highlight clip',
          tooltip:
              'Controls highlight clipping in standard deviations from median. '
              'Lower values clip more highlights.',
          value: settings.highlightClip,
          min: -3.0,
          max: 0.0,
          divisions: 30,
          enabled: settings.enabled,
          colors: colors,
          formatValue: (v) => v.toStringAsFixed(2),
          onChanged: (value) {
            onSettingsChanged(settings.copyWith(highlightClip: value));
          },
        ),

        const SizedBox(height: 12),

        // Target median slider
        _SliderSetting(
          label: 'Target median',
          tooltip: 'Target brightness level for the stretched image midtones. '
              'Higher values produce brighter images.',
          value: settings.targetMedian,
          min: 0.1,
          max: 0.5,
          divisions: 40,
          enabled: settings.enabled,
          colors: colors,
          formatValue: (v) => v.toStringAsFixed(2),
          onChanged: (value) {
            onSettingsChanged(settings.copyWith(targetMedian: value));
          },
        ),

        const SizedBox(height: 12),

        // Linked channels toggle
        SkotiqSwitchRow(
          label: 'Linked channels',
          tooltip:
              'When enabled, uses the same stretch for all RGB channels to preserve color balance. '
              'Disable for independent channel stretching.',
          value: settings.linkedChannels,
          enabled: settings.enabled,
          onChanged: settings.enabled
              ? (value) {
                  onSettingsChanged(settings.copyWith(linkedChannels: value));
                }
              : null,
        ),

        // Gamma value slider (only shown for gamma method)
        if (settings.method == AutoStretchMethod.gamma) ...[
          const SizedBox(height: 12),
          _SliderSetting(
            label: 'Gamma value',
            tooltip: 'Gamma correction factor. Standard display gamma is 2.2. '
                'Lower values brighten the image, higher values darken it.',
            value: settings.gammaValue,
            min: 1.0,
            max: 4.0,
            divisions: 30,
            enabled: settings.enabled,
            colors: colors,
            formatValue: (v) => v.toStringAsFixed(1),
            onChanged: (value) {
              onSettingsChanged(settings.copyWith(gammaValue: value));
            },
          ),
        ],

        const SizedBox(height: 16),

        // Reset to defaults button
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _TextButton(
              label: 'Reset to Defaults',
              colors: colors,
              enabled: settings.enabled,
              onPressed: () {
                onSettingsChanged(AutoStretchSettings.defaults().copyWith(
                  enabled: settings.enabled,
                ));
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Dialog for advanced stretch settings.
class _StretchSettingsDialog extends StatefulWidget {
  final AutoStretchSettings settings;
  final SkotiqColors colors;
  final FutureOr<bool> Function(AutoStretchSettings) onSettingsChanged;

  const _StretchSettingsDialog({
    required this.settings,
    required this.colors,
    required this.onSettingsChanged,
  });

  @override
  State<_StretchSettingsDialog> createState() => _StretchSettingsDialogState();
}

class _StretchSettingsDialogState extends State<_StretchSettingsDialog> {
  /// Settings as the user is editing them in this dialog. Held locally so
  /// Close discards changes and Apply explicitly commits them, so there is a
  /// way to back out of a live-pushed preview.
  late AutoStretchSettings _localSettings;

  /// Snapshot of the provider settings at dialog open, so Close can restore
  /// the user's prior state if the dialog briefly drove a live preview.
  late final AutoStretchSettings _initialSettings;
  bool _applying = false;

  /// Tracks whether the local edits diverge from the committed (initial)
  /// settings, so the Apply button reflects whether there's anything to apply.
  bool get _hasChanges => _localSettings != _initialSettings;

  @override
  void initState() {
    super.initState();
    _localSettings = widget.settings;
    _initialSettings = widget.settings;
  }

  bool _updateLocalSettings(AutoStretchSettings newSettings) {
    setState(() {
      _localSettings = newSettings;
    });
    return true;
  }

  void _close() {
    Navigator.of(context).pop();
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() => _applying = true);
    final saved = await widget.onSettingsChanged(_localSettings);
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return SkotiqDialog(
      title: 'Auto-Stretch Settings',
      icon: SkotiqIcons.sliders,
      width: 420,
      closeEnabled: !_applying,
      onClose: _close,
      scrollableBody: false,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: _applying ? null : _close,
        ),
        SkotiqButton(
          label: 'Apply',
          variant: ButtonVariant.primary,
          isLoading: _applying,
          onPressed: _hasChanges && !_applying ? () => _apply() : null,
        ),
      ],
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 400,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Configure how auto-stretch processes your images',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textMuted,
              ),
            ),

            const SizedBox(height: SkotiqTokens.spaceLg),

            Divider(color: colors.border, height: 1),

            const SizedBox(height: SkotiqTokens.spaceLg),

            // Expanded controls — these mutate local state only; the
            // provider isn't updated until the user presses Apply.
            _ExpandedStretchControls(
              settings: _localSettings,
              colors: colors,
              onSettingsChanged: _updateLocalSettings,
            ),

            // Footer: explicit Close + Apply. Apply is
          ],
        ),
      ),
    );
  }
}

/// Method dropdown with custom styling.
class _MethodDropdown extends StatelessWidget {
  final AutoStretchMethod value;
  final SkotiqColors colors;
  final ValueChanged<AutoStretchMethod?>? onChanged;
  final bool isExpanded;

  const _MethodDropdown({
    required this.value,
    required this.colors,
    this.onChanged,
    this.isExpanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onChanged != null;

    return Opacity(
      opacity: isEnabled ? 1.0 : 0.5,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(color: colors.border),
        ),
        child: DropdownButtonHideUnderline(
          child: AccessibleDropdown<AutoStretchMethod>(
            value: value,
            isExpanded: isExpanded,
            isDense: true,
            icon: Icon(
              SkotiqIcons.chevronDown,
              size: 14,
              color: colors.textSecondary,
            ),
            dropdownColor: colors.surface,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
            items: AutoStretchMethod.values.map((method) {
              return DropdownMenuItem<AutoStretchMethod>(
                value: method,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _methodNames[method] ?? method.name,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textPrimary),
                    ),
                  ],
                ),
              );
            }).toList(),
            onChanged: isEnabled ? onChanged : null,
          ),
        ),
      ),
    );
  }
}

/// A compact icon button for the toolbar.
class _CompactIconButton extends StatefulWidget {
  final IconData icon;
  final SkotiqColors colors;
  final VoidCallback onPressed;

  const _CompactIconButton({
    required this.icon,
    required this.colors,
    required this.onPressed,
  });

  @override
  State<_CompactIconButton> createState() => _CompactIconButtonState();
}

class _CompactIconButtonState extends State<_CompactIconButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _isHovered ? widget.colors.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: _isHovered
                ? widget.colors.textPrimary
                : widget.colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// A row with label, optional tooltip, and a child widget.
class _SettingRow extends StatelessWidget {
  final String label;
  final String? tooltip;
  final SkotiqColors colors;
  final Widget child;

  const _SettingRow({
    required this.label,
    this.tooltip,
    required this.colors,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final labelWidget = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        if (tooltip != null) ...[
          const SizedBox(width: 4),
          SkotiqTooltip(
            message: tooltip!,
            position: SkotiqTooltipPosition.top,
            child: Icon(
              SkotiqIcons.help,
              size: 12,
              color: colors.textMuted,
            ),
          ),
        ],
      ],
    );

    return Row(
      children: [
        Expanded(child: labelWidget),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    );
  }
}

/// A slider setting with label, tooltip, and value display.
class _SliderSetting extends StatelessWidget {
  final String label;
  final String? tooltip;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final bool enabled;
  final SkotiqColors colors;
  final String Function(double) formatValue;
  final ValueChanged<double> onChanged;

  const _SliderSetting({
    required this.label,
    this.tooltip,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.enabled,
    required this.colors,
    required this.formatValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 4),
                SkotiqTooltip(
                  message: tooltip!,
                  position: SkotiqTooltipPosition.top,
                  child: Icon(
                    SkotiqIcons.help,
                    size: 12,
                    color: colors.textMuted,
                  ),
                ),
              ],
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  formatValue(value),
                  style: SkotiqTypography.monoCaption.copyWith(
                      fontFamily: 'JetBrains Mono', color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: enabled ? colors.primary : colors.textMuted,
              inactiveTrackColor: colors.surfaceAlt,
              thumbColor: enabled ? colors.primary : colors.textMuted,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayColor: colors.primary.withValues(alpha: 0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// A simple text button.
class _TextButton extends StatefulWidget {
  final String label;
  final SkotiqColors colors;
  final bool enabled;
  final VoidCallback onPressed;

  const _TextButton({
    required this.label,
    required this.colors,
    required this.enabled,
    required this.onPressed,
  });

  @override
  State<_TextButton> createState() => _TextButtonState();
}

class _TextButtonState extends State<_TextButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: widget.enabled ? (_) => setState(() => _isHovered = true) : null,
      onExit: widget.enabled ? (_) => setState(() => _isHovered = false) : null,
      cursor:
          widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.enabled ? widget.onPressed : null,
        child: Opacity(
          opacity: widget.enabled ? 1.0 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color:
                  _isHovered ? widget.colors.surfaceHover : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Text(
              widget.label,
              style: SkotiqTypography.caption.copyWith(
                  color: _isHovered
                      ? widget.colors.primary
                      : widget.colors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
