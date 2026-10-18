// ignore_for_file: invalid_use_of_protected_member

part of '../profile_editor_dialog.dart';

extension _ProfileEditorShellAndIdentity on _ProfileEditorDialogState {
  /// Persistent validation summary rendered INSIDE the dialog, above the
  /// sections.
  ///
  /// Replaces relying on a transient snackbar that appeared ~150 px below the
  /// Save button at the bottom edge of the window, dimmed by the modal barrier to
  /// a measured 2.00:1 contrast ratio, and disappeared after a few seconds. The
  /// banner stays until the form validates, sits where the user is already
  /// looking, and is not subject to the scrim.
  ///
  /// ONE banner (05 §11), never a stack: a single problem is stated as the
  /// banner's title, several are counted in the title and listed in its message.
  Widget _buildValidationBanner(SkotiqColors colors) {
    final messages = <String>[
      if (_nameError != null) _nameError!,
      ..._fieldErrors.values.whereType<String>(),
      ..._formErrors,
    ];
    if (messages.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqBanner(
        tone: BannerTone.error,
        title: messages.length == 1
            ? messages.single
            : 'Fix ${messages.length} problems before saving',
        message: messages.length == 1 ? null : messages.join(' • '),
      ),
    );
  }

  /// The dialog's footer: `[ghost Cancel] [primary Save]`, right-aligned with an
  /// 8px gap (05 §13). The chrome supplies the alignment and the gap; this only
  /// supplies the buttons, in reading order.
  List<Widget> _footerActions() {
    return [
      if (widget.mode == ProfileEditorMode.full)
        SkotiqButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
        ),
      SkotiqButton(
        onPressed: _isSaving ? null : _save,
        label: 'Save changes',
        variant: ButtonVariant.primary,
        isLoading: _isSaving,
      ),
    ];
  }

  /// The same footer for the embedded Profiles page, which has no dialog
  /// chrome to lay the actions out for it.
  Widget _buildFooter(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceLg,
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceLg,
      ),
      child: Wrap(
        alignment: WrapAlignment.end,
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceSm,
        children: _footerActions(),
      ),
    );
  }

  // Section 1: profile identity

  Widget _buildIdentitySection(SkotiqColors colors, ThemeData theme) {
    return _SectionBlock(
      title: 'Profile identity',
      icon: LucideIcons.user,
      isExpanded: _expandedSections['identity']!,
      onToggle: () => setState(() =>
          _expandedSections['identity'] = !_expandedSections['identity']!),
      summary: _nameController.text.isEmpty ? 'Unnamed' : _nameController.text,
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _EditorRow(
            label: 'Profile name',
            child: SkotiqTextField(
              controller: _nameController,
              hint: 'e.g. Main imaging rig',
              errorText: _nameError,
              onChanged: (_) {
                // Clear a standing validation error the moment the user edits,
                // and refresh the section summary that mirrors the name.
                if (_nameError != null) {
                  setState(() => _nameError = null);
                } else {
                  setState(() {});
                }
              },
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Icon',
            child: Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: _ProfileEditorDialogState._availableIcons.map((icon) {
                final isSelected = _selectedIcon == icon;
                return _IconOption(
                  icon: icon,
                  isSelected: isSelected,
                  onTap: () => setState(() => _selectedIcon = icon),
                  colors: colors,
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Accent colour',
            child: Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // None option
                _ColorOption(
                  color: null,
                  isSelected: _selectedColor == null,
                  onTap: () => setState(() => _selectedColor = null),
                  colors: colors,
                ),
                ..._ProfileEditorDialogState._accentColors.map((color) {
                  final isSelected = _selectedColor == color;
                  return _ColorOption(
                    color: color,
                    isSelected: isSelected,
                    onTap: () => setState(() => _selectedColor = color),
                    colors: colors,
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: _rowGap),
          SkotiqSwitchRow(
            label: 'Default profile',
            subtitle: 'Set as the active profile on startup',
            value: _isDefault,
            onChanged: (v) => setState(() => _isDefault = v),
          ),
        ],
      ),
    );
  }
}
