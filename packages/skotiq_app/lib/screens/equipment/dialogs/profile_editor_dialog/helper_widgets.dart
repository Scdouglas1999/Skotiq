part of '../profile_editor_dialog.dart';

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

const double _swatchSelectedRing = 2;

const double _filterOffsetWidth = 104;

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
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
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

const double _rowGap = FormRow.rowGap;

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
      enabled: true,
      selected: isSelected,
      label: icon.isEmpty ? 'No icon' : 'Icon $icon',
      onTap: onTap,
      excludeSemantics: true,
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
      enabled: true,
      selected: isSelected,
      label: color == null ? 'No accent color' : 'Accent color',
      onTap: onTap,
      excludeSemantics: true,
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
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }
}

/// A device a row's picker offers: one connected now, one a scan found, or
/// one a saved profile assigns.
class _DeviceChoice {
  final String id;
  final String name;

  /// Where the choice comes from, shown under its name.
  final String detail;

  const _DeviceChoice({
    required this.id,
    required this.name,
    required this.detail,
  });
}

/// One device slot: the device picker first, the name the profile shows for it
/// after it, and a clear button, with the assigned device id as the row's help
/// line.
class _DeviceRow extends StatelessWidget {
  final String label;
  // Null when this device type has no persisted friendly-name column, so the
  // row shows only the picker (no editable name field to silently discard).
  final TextEditingController? nameController;
  final String? deviceId;
  final List<_DeviceChoice> choices;
  final void Function(String? id, String? name) onDeviceSelected;
  final VoidCallback onClear;
  final VoidCallback onScan;
  final SkotiqColors colors;

  const _DeviceRow({
    required this.label,
    required this.nameController,
    required this.deviceId,
    required this.choices,
    required this.onDeviceSelected,
    required this.onClear,
    required this.onScan,
    required this.colors,
  });

  /// Below this width the name field goes under the picker instead of beside
  /// it, so the picker keeps room for a device name.
  static const double _sideBySideMinWidth = 360;

  @override
  Widget build(BuildContext context) {
    final nameController = this.nameController;
    final picker = _DevicePicker(
      label: label,
      deviceId: deviceId,
      choices: choices,
      onSelected: onDeviceSelected,
      onScan: onScan,
      colors: colors,
    );
    final nameField = nameController == null
        ? null
        : Semantics(
            label: '$label display name',
            child: SkotiqTextField(
              controller: nameController,
              hint: 'Display name (optional)',
            ),
          );

    return _EditorRow(
      label: label,
      help: deviceId,
      trailing: deviceId == null
          ? null
          : SkotiqIconButton(
              icon: LucideIcons.x,
              tooltip: 'Clear this device',
              size: IconButtonSize.sm,
              onPressed: onClear,
            ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _sideBySideMinWidth) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                picker,
                if (nameField != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  nameField,
                ],
              ],
            );
          }
          // The picker keeps the same width on every row, name field or not,
          // so the column of pickers lines up.
          return Row(
            children: [
              Expanded(flex: 3, child: picker),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(flex: 2, child: nameField ?? const SizedBox.shrink()),
            ],
          );
        },
      ),
    );
  }
}

class _DevicePicker extends StatefulWidget {
  final String label;
  final String? deviceId;
  final List<_DeviceChoice> choices;
  final void Function(String? id, String? name) onSelected;
  final VoidCallback onScan;
  final SkotiqColors colors;

  const _DevicePicker({
    required this.label,
    required this.deviceId,
    required this.choices,
    required this.onSelected,
    required this.onScan,
    required this.colors,
  });

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  static const _scanValue = '_scan_';
  static const _manualValue = '_manual_';

  final _menuKey = GlobalKey<PopupMenuButtonState<String>>();

  String? get _selectedName {
    final id = widget.deviceId;
    if (id == null) return null;
    return widget.choices.where((c) => c.id == id).firstOrNull?.name ?? id;
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selectedName = _selectedName;
    // The menu's own button reports DISABLED to assistive technology; the
    // picker is announced as one button that opens it.
    return Semantics(
      button: true,
      enabled: true,
      label: '${widget.label}: ${selectedName ?? 'choose a device'}',
      onTap: () => _menuKey.currentState?.showButtonMenu(),
      excludeSemantics: true,
      child: PopupMenuButton<String>(
        key: _menuKey,
        tooltip: 'Choose the ${widget.label.toLowerCase()}',
        onSelected: (value) {
          if (value == _manualValue) {
            _showManualEntryDialog(context);
          } else if (value == _scanValue) {
            // The parent watches the discovery results, so the list fills in
            // when the scan lands.
            context.showInfoSnackBar('Scanning for devices…');
            widget.onScan();
          } else {
            final choice =
                widget.choices.where((c) => c.id == value).firstOrNull;
            widget.onSelected(value, choice?.name);
          }
        },
        itemBuilder: (context) => [
          for (final choice in widget.choices)
            PopupMenuItem(
              value: choice.id,
              child: Row(
                children: [
                  SizedBox(
                    width: SkotiqTokens.iconXs,
                    child: choice.id == widget.deviceId
                        ? Icon(
                            LucideIcons.check,
                            size: SkotiqTokens.iconXs,
                            color: colors.primary,
                          )
                        : null,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          choice.name,
                          style: SkotiqTypography.bodySm
                              .copyWith(color: colors.textPrimary),
                        ),
                        Text(
                          choice.detail,
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (widget.choices.isNotEmpty) const PopupMenuDivider(),
          _actionItem(_scanValue, LucideIcons.refreshCw, 'Scan for devices'),
          _actionItem(_manualValue, LucideIcons.edit3, 'Enter manually…'),
        ],
        // The closed control wears the same field face as every other input
        // in the row, so a select and a text box do not read as two different
        // kinds of control (05 §8).
        child: Container(
          height: fieldHeight,
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.inputPaddingHorizontal,
          ),
          decoration: SkotiqDecorations.field(colors),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  selectedName ?? 'Choose a device…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.input.copyWith(
                    color: selectedName != null
                        ? colors.textPrimary
                        : colors.textMuted,
                  ),
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
      ),
    );
  }

  PopupMenuItem<String> _actionItem(String value, IconData icon, String text) {
    final colors = widget.colors;
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: SkotiqTokens.iconXs, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            text,
            style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
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
      widget.onSelected(result, null);
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
              style:
                  SkotiqTypography.monoSm.copyWith(color: colors.textSecondary),
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

extension _StringTrimOrNull on String {
  String? get trimOrNull {
    final trimmed = trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
