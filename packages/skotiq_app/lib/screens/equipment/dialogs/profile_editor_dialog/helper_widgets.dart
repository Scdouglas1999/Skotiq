part of '../profile_editor_dialog.dart';

// Helper widgets

/// Width of the label column shared by every [FormRow] in this editor.
///
/// 05 §8 puts the column at 84–104. This form runs wider because two of its
/// labels do not fit that window in `bodySm`/HankenGrotesk — measured,
/// "Centering exposure" is 114.0 px and "Cover / calibrator" 104.6 — and a
/// column that wraps to two lines on two rows out of twenty-three is a worse
/// defect than one that is 16 px wider and never wraps.
const double profileEditorLabelWidth = 120;

/// Side of the square an emoji profile icon is offered in.
const double _iconOptionSize = SkotiqTokens.inputHeight;

/// Diameter of an accent swatch (03 §1.4).
const double _swatchSize = 22;

/// Ring drawn around the chosen accent swatch.
const double _swatchSelectedRing = 2;

/// Width of a filter row's focus-offset field.
const double _filterOffsetWidth = 104;

/// Width of the ordinal column in the filter table.
const double _filterIndexWidth = 28;

/// A section of the editor: a [SectionTitle] with a collapse control, then
/// either the section's content or, when collapsed, its one-line summary.
///
/// NOT a card. The dialog is already the surface; a panel per section would be
/// a panel inside a panel, which 02 §2 says does not exist.
class _SectionBlock extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String summary;
  final Widget child;
  final SkotiqColors colors;

  const _SectionBlock({
    required this.title,
    required this.icon,
    required this.isExpanded,
    required this.onToggle,
    required this.summary,
    required this.child,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionTitle(
          icon: icon,
          title: title,
          trailing: SkotiqIconButton(
            icon: isExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
            tooltip: isExpanded ? 'Collapse $title' : 'Expand $title',
            size: IconButtonSize.sm,
            onPressed: onToggle,
          ),
        ),
        if (isExpanded)
          child
        else
          Text(
            summary,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
      ],
    );
  }
}

/// One label + control row of the editor's form.
///
/// The label sits to the LEFT in [FormRow]'s fixed column (05 §8) and is also
/// hung on the control as its accessible name — [FormRow] paints the label as a
/// sibling [Text], so without this the field reaches assistive tech as an
/// anonymous text box.
class _EditorRow extends StatelessWidget {
  const _EditorRow({
    required this.label,
    required this.child,
    this.help,
    this.trailing,
  });

  /// The label, in sentence case.
  final String label;

  /// The control.
  final Widget child;

  /// One short line under the control.
  final String? help;

  /// An affordance that belongs after the control (a help icon, a clear
  /// button) rather than inside it.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final named = Semantics(label: label, child: child);
    return FormRow(
      label: label,
      labelWidth: profileEditorLabelWidth,
      help: help,
      child: trailing == null
          ? named
          : Row(
              children: [
                Expanded(child: named),
                const SizedBox(width: SkotiqTokens.spaceSm),
                trailing!,
              ],
            ),
    );
  }
}

/// Vertical gap between two [_EditorRow]s.
const double _rowGap = FormRow.rowGap;

/// Icon selection option
class _IconOption extends StatelessWidget {
  final String icon;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _IconOption({
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: icon.isEmpty ? 'No icon' : 'Icon $icon',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: _iconOptionSize,
          height: _iconOptionSize,
          decoration: BoxDecoration(
            color: isSelected
                ? colors.primary.withValues(
                    alpha: SkotiqTokens.opacityAccentTint,
                  )
                : colors.well,
            borderRadius: SkotiqTokens.borderRadiusSm,
            border: Border.all(
              color: isSelected ? colors.primary : colors.border,
              width: isSelected ? _swatchSelectedRing : 1,
            ),
          ),
          child: Center(
            child: icon.isEmpty
                ? Icon(
                    LucideIcons.ban,
                    size: SkotiqTokens.iconXs,
                    color: colors.textMuted,
                  )
                : Text(icon, style: SkotiqTypography.bodyLg),
          ),
        ),
      ),
    );
  }
}

/// Accent-colour swatch.
class _ColorOption extends StatelessWidget {
  final Color? color;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _ColorOption({
    required this.color,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: color == null ? 'No accent colour' : 'Accent colour',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: _swatchSize,
          height: _swatchSize,
          decoration: BoxDecoration(
            color: color ?? colors.well,
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected ? colors.textPrimary : colors.border,
              width: isSelected ? _swatchSelectedRing : 1,
            ),
          ),
          child: color == null
              ? Icon(
                  LucideIcons.ban,
                  size: SkotiqTokens.iconChipGlyph,
                  color: colors.textMuted,
                )
              : null,
        ),
      ),
    );
  }
}

/// A derived optical value: a [Readout] with an optional line of provenance
/// under it.
class _ComputedValue extends StatelessWidget {
  final String label;

  /// The formatted value, or null when the inputs do not describe a possible
  /// system — [Readout] then shows [kReadoutUnknown].
  final String? value;
  final String? subtitle;
  final SkotiqColors colors;

  const _ComputedValue({
    required this.label,
    required this.value,
    this.subtitle,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Readout(value: value, label: label, size: ReadoutSize.sm),
        if (subtitle != null) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            subtitle!,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// One device slot: the friendly name, the device picker, and a clear button,
/// with the assigned device id as the row's help line.
class _DeviceRow extends StatelessWidget {
  final String type;
  // Null when this device type has no persisted friendly-name column, so the
  // row shows only the device id (no editable name field to silently discard).
  final TextEditingController? nameController;
  final String? deviceId;
  final List<UnifiedDevice> discoveredDevices;
  final void Function(String? id, String? name) onDeviceSelected;
  final VoidCallback onClear;
  final VoidCallback onScan;
  final SkotiqColors colors;

  const _DeviceRow({
    required this.type,
    required this.nameController,
    required this.deviceId,
    required this.discoveredDevices,
    required this.onDeviceSelected,
    required this.onClear,
    required this.onScan,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final nameController = this.nameController;
    final picker = _DeviceDropdown(
      deviceId: deviceId,
      discoveredDevices: discoveredDevices,
      onSelected: onDeviceSelected,
      onScan: onScan,
      colors: colors,
    );

    return _EditorRow(
      label: type,
      help: deviceId,
      trailing: deviceId == null
          ? null
          : SkotiqIconButton(
              icon: LucideIcons.x,
              tooltip: 'Clear this device',
              size: IconButtonSize.sm,
              onPressed: onClear,
            ),
      child: nameController == null
          ? Align(alignment: Alignment.centerLeft, child: picker)
          : Row(
              children: [
                Expanded(
                  child: SkotiqTextField(
                    controller: nameController,
                    hint: 'Friendly name',
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                picker,
              ],
            ),
    );
  }
}

/// Dropdown for selecting a device.
class _DeviceDropdown extends StatelessWidget {
  final String? deviceId;
  final List<UnifiedDevice> discoveredDevices;
  final void Function(String? id, String? name) onSelected;
  final VoidCallback onScan;
  final SkotiqColors colors;

  const _DeviceDropdown({
    required this.deviceId,
    required this.discoveredDevices,
    required this.onSelected,
    required this.onScan,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Select device',
      onSelected: (value) {
        if (value == '_manual_') {
          _showManualEntryDialog(context);
        } else if (value == '_scan_') {
          // Trigger a real discovery refresh; the parent watches
          // unifiedDiscoveryProvider so the dropdown repopulates when it lands.
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Scanning for devices…')),
          );
          onScan();
        } else {
          // Find the device name
          final device = discoveredDevices
              .where((d) => d.activeDeviceId == value)
              .firstOrNull;
          onSelected(value, device?.displayName);
        }
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<String>>[];

        // Current selection
        if (deviceId != null) {
          items.add(PopupMenuItem(
            value: deviceId,
            child: Row(
              children: [
                Icon(
                  LucideIcons.check,
                  size: SkotiqTokens.iconXs,
                  color: colors.primary,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    _getDeviceDisplayName(deviceId!),
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
          ));
          items.add(const PopupMenuDivider());
        }

        // Discovered devices
        if (discoveredDevices.isNotEmpty) {
          for (final device in discoveredDevices) {
            if (device.activeDeviceId == deviceId) continue;
            items.add(PopupMenuItem(
              value: device.activeDeviceId,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    device.displayName,
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textPrimary),
                  ),
                  Text(
                    device.activeBackend.shortLabel,
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ));
          }
          items.add(const PopupMenuDivider());
        }

        // Actions
        items.add(PopupMenuItem(
          value: '_scan_',
          child: Row(
            children: [
              Icon(
                LucideIcons.refreshCw,
                size: SkotiqTokens.iconXs,
                color: colors.textSecondary,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Scan',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ));
        items.add(PopupMenuItem(
          value: '_manual_',
          child: Row(
            children: [
              Icon(
                LucideIcons.edit3,
                size: SkotiqTokens.iconXs,
                color: colors.textSecondary,
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Text(
                'Enter manually…',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ));

        return items;
      },
      // The closed control wears the same field face as every other input in
      // the row, so a select and a text box do not read as two different kinds
      // of control (05 §8).
      child: Container(
        height: fieldHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.inputPaddingHorizontal,
        ),
        decoration: SkotiqDecorations.field(colors),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              deviceId != null ? 'Selected' : 'Select…',
              style: SkotiqTypography.input.copyWith(
                color: deviceId != null ? colors.textPrimary : colors.textMuted,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Icon(
              LucideIcons.chevronDown,
              size: SkotiqTokens.iconXs,
              color: colors.textMuted,
            ),
          ],
        ),
      ),
    );
  }

  String _getDeviceDisplayName(String id) {
    final device =
        discoveredDevices.where((d) => d.activeDeviceId == id).firstOrNull;
    return device?.displayName ?? id;
  }

  Future<void> _showManualEntryDialog(BuildContext context) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return SkotiqDialog(
          title: 'Enter device ID',
          width: SkotiqDialog.widthConfirm,
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              onPressed: () => Navigator.pop(context),
            ),
            SkotiqButton(
              label: 'Add',
              variant: ButtonVariant.primary,
              onPressed: () => Navigator.pop(context, controller.text.trim()),
            ),
          ],
          child: SkotiqTextField(
            controller: controller,
            hint: 'Device ID or path',
            autofocus: true,
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
        );
      },
    );
    controller.dispose();
    if (result != null && result.isNotEmpty) {
      onSelected(result, null);
    }
  }
}

/// One row of the filter table: ordinal, name, focus offset, remove.
class _FilterRow extends StatelessWidget {
  final int index;
  final TextEditingController nameController;
  final TextEditingController offsetController;
  final VoidCallback onRemove;
  final bool isLast;
  final SkotiqColors colors;

  const _FilterRow({
    required this.index,
    required this.nameController,
    required this.offsetController,
    required this.onRemove,
    required this.isLast,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        border:
            isLast ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _filterIndexWidth,
            child: Text(
              '$index',
              style: SkotiqTypography.monoSm
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Semantics(
              label: 'Filter $index name',
              child: SkotiqTextField(
                dense: true,
                controller: nameController,
                hint: 'Filter name',
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SizedBox(
            width: _filterOffsetWidth,
            child: Semantics(
              label: 'Filter $index focus offset',
              child: SkotiqTextField(
                dense: true,
                mono: true,
                controller: offsetController,
                hint: '0',
                suffix: 'steps',
                keyboardType:
                    const TextInputType.numberWithOptions(signed: true),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
          SkotiqIconButton(
            icon: LucideIcons.trash2,
            tooltip: 'Remove this filter',
            size: IconButtonSize.sm,
            color: colors.error,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Helper class for filter name and offset controllers
class _FilterControllerPair {
  final TextEditingController nameController;
  final TextEditingController offsetController;

  _FilterControllerPair({
    required this.nameController,
    required this.offsetController,
  });

  void dispose() {
    nameController.dispose();
    offsetController.dispose();
  }
}

/// Extension to get trimmed string or null
extension _StringTrimOrNull on String {
  String? get trimOrNull {
    final trimmed = trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
