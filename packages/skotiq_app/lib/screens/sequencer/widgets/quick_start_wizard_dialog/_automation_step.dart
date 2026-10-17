// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _AutomationStep on _QuickStartWizardDialogState {
  // STEP 3: AUTOMATION

  Widget _buildAutomationStep(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Configure automation features for your imaging session.',
          style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize13),
        ),
        if (_populatedFromSavedDefaults) ...[
          const SizedBox(height: 8),
          _buildSavedDefaultsHint(colors),
        ],
        const SizedBox(height: 16),
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.focus,
          title: 'Autofocus',
          subtitle:
              'Run autofocus before imaging and trigger refocus on HFR degradation',
          value: _enableAutofocus,
          onChanged: (v) => _update(() => _enableAutofocus = v),
        ),
        if (_enableAutofocus) ...[
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Row(
              children: [
                Text('Refocus trigger:',
                    style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: SkotiqTypography.fontSize12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  height: 32,
                  child: TextField(
                    controller: _autofocusFramesController,
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: SkotiqTypography.fontSize12),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      filled: true,
                      fillColor: colors.surfaceAlt,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed > 0) {
                        _update(() => _autofocusEveryFrames = parsed);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Text('frames (HFR-based)',
                    style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: SkotiqTypography.fontSize12)),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.shuffle,
          title: 'Dithering',
          subtitle:
              'Shift the image slightly between exposures to reduce noise patterns',
          value: _enableDithering,
          onChanged: (v) => _update(() => _enableDithering = v),
        ),
        if (_enableDithering) ...[
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Row(
              children: [
                Text('Dither amount:',
                    style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: SkotiqTypography.fontSize12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  height: 32,
                  child: TextField(
                    controller: _ditherPixelsController,
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: SkotiqTypography.fontSize12),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      suffixText: 'px',
                      suffixStyle: TextStyle(
                          color: colors.textMuted,
                          fontSize: SkotiqTypography.fontSize11),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusMd),
                        borderSide: BorderSide(color: colors.border),
                      ),
                      filled: true,
                      fillColor: colors.surfaceAlt,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                    ),
                    onChanged: (value) {
                      final parsed = double.tryParse(value);
                      if (parsed != null && parsed > 0) {
                        _update(() => _ditherPixels = parsed);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.refreshCw,
          title: 'Meridian flip',
          subtitle: 'Automatically flip the mount when crossing the meridian',
          value: _enableMeridianFlip,
          onChanged: (v) => _update(() => _enableMeridianFlip = v),
        ),
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.crosshair,
          title: 'Auto-Guide',
          subtitle: 'Start PHD2 guiding before imaging and stop after',
          value: _enableAutoGuide,
          onChanged: (v) => _update(() => _enableAutoGuide = v),
        ),
      ],
    );
  }

  /// Small, understated hint surfaced on the Automation and Safety steps
  /// to tell the user that the pre-filled values came from their saved
  /// Sequencer Settings / equipment profile rather than wizard defaults.
  /// Why: the original wizard silently overwrote the user's preferences
  /// with hardcoded numbers; surfacing the source makes the wizard's
  /// behaviour discoverable instead of surprising.
  Widget _buildSavedDefaultsHint(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.info, color: colors.textMuted, size: 12),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Using your saved defaults from Settings and the active '
              'equipment profile. Adjust below to override for this sequence.',
              style: TextStyle(
                  color: colors.textMuted,
                  fontSize: SkotiqTypography.fontSize11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleRow({
    required SkotiqColors colors,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon,
              color: value ? colors.primary : colors.textMuted, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: SkotiqTypography.label
                        .copyWith(color: colors.textPrimary)),
                Text(subtitle,
                    style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11)),
              ],
            ),
          ),
          SkotiqSwitch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
