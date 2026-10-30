part of '../equipment_profiles_screen.dart';

// Helper widgets

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  final Widget? trailing;
  final bool isMobile;

  const _Section({
    required this.title,
    required this.icon,
    required this.children,
    this.trailing,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final sectionPadding = isMobile ? 16.0 : 20.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: isMobile ? 16 : 18, color: colors.primary),
            SizedBox(width: isMobile ? 6 : 8),
            Expanded(
              child: Text(
                title,
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        SizedBox(height: isMobile ? 12 : 16),
        Container(
          padding: EdgeInsets.all(sectionPadding),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: SkotiqTokens.borderRadiusXl,
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _FieldCard extends StatelessWidget {
  final String label;
  final String? value;
  final TextEditingController? controller;
  final String? suffix;
  final String? hint;
  final bool readOnly;

  /// Why a rejected save says so. Rendered under the field and used to tint
  /// the border, because the summary snackbar is drawn behind the persistent
  /// bottom status bar on desktop.
  final String? errorText;

  const _FieldCard({
    required this.label,
    this.value,
    this.controller,
    this.suffix,
    this.hint,
    this.readOnly = false,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasError = errorText != null && controller != null && !readOnly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SkotiqTypography.captionSm.copyWith(
            color: hasError ? colors.error : colors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        if (controller != null && !readOnly)
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border:
                  Border.all(color: hasError ? colors.error : colors.border),
            ),
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
              ],
              style: SkotiqTypography.bodyStrong
                  .copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                border: InputBorder.none,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                hintText: hint,
                hintStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                suffixText: suffix,
                suffixStyle: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ),
          )
        else
          // Deliberately unboxed. A filled, rounded panel carrying a number is
          // the same visual language as the editable field above and as the
          // live binning selector directly beneath, so clicking "400 mm" and
          // typing produced no focus ring and swallowed every keystroke —
          // within one card, identical chrome was half live and half dead.
          // Values that cannot be typed into do not look typed into.
          Semantics(
            label: '$label: ${value ?? 'not set'}',
            readOnly: true,
            excludeSemantics: true,
            child: SizedBox(
              height: 36,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  value ?? 'Not set',
                  style: SkotiqTypography.bodyStrong.copyWith(
                      color: value != null &&
                              value != 'Not set' &&
                              value != kReadoutUnknown
                          ? colors.textPrimary
                          : colors.textMuted),
                ),
              ),
            ),
          ),
        if (hasError)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              errorText!,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _BinningSelector extends StatelessWidget {
  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _BinningSelector({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          height: 36,
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              for (int i = 1; i <= 4; i++)
                Expanded(
                  child: GestureDetector(
                    onTap: enabled ? () => onChanged(i) : null,
                    child: Container(
                      decoration: BoxDecoration(
                        color: value == i ? colors.primary : Colors.transparent,
                        borderRadius: BorderRadius.horizontal(
                          left: i == 1
                              ? const Radius.circular(SkotiqTokens.radiusSm)
                              : Radius.zero,
                          right: i == 4
                              ? const Radius.circular(SkotiqTokens.radiusSm)
                              : Radius.zero,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '$i',
                          style: SkotiqTypography.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: value == i
                                  ? colors.background
                                  : colors.textSecondary),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String name;

  const _FilterChip({
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final filterColor = FilterColors.forName(name, colors: colors);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.chip(colors, tone: filterColor),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: filterColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            name,
            style: SkotiqTypography.caption
                .copyWith(fontWeight: FontWeight.w600, color: filterColor),
          ),
        ],
      ),
    );
  }
}

class _EditableFilterChip extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onRemove;

  /// Fired on every keystroke. The Filter Focus Offsets card below is built
  /// from these same controllers' text, so without a rebuild signal it lagged
  /// a whole interaction behind: naming a filter produced no offset row until
  /// some unrelated widget forced a rebuild, and the operator had to save and
  /// re-open the editor to reach the offset they had just created a slot for.
  final VoidCallback onNameChanged;

  const _EditableFilterChip({
    required this.controller,
    required this.onRemove,
    required this.onNameChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: 120,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => onNameChanged(),
              style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Filter name',
                hintStyle: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          GestureDetector(
            onTap: onRemove,
            child: Icon(
              LucideIcons.x,
              size: 14,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceChip extends StatelessWidget {
  final String type;
  final String id;

  const _DeviceChip({
    required this.type,
    required this.id,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.link, size: 12, color: colors.textMuted),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                type,
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
              Text(
                id,
                style: SkotiqTypography.labelSm
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EditableDeviceChip extends StatelessWidget {
  final String type;
  final String id;
  final String fullId;
  final VoidCallback onClear;

  const _EditableDeviceChip({
    required this.type,
    required this.id,
    required this.fullId,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.link, size: 12, color: colors.textMuted),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                type,
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
              Tooltip(
                message: fullId,
                child: Text(
                  id,
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onClear,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.x,
                size: 12,
                color: colors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableField extends StatelessWidget {
  final TextEditingController controller;
  final String? hint;
  final TextStyle style;

  const _EditableField({
    required this.controller,
    this.hint,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return TextField(
      controller: controller,
      style: style,
      decoration: InputDecoration(
        border: InputBorder.none,
        hintText: hint,
        hintStyle: style.copyWith(color: colors.textMuted),
        isDense: true,
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}
