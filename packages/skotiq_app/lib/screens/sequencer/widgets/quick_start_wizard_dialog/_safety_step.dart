// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _SafetyStep on _QuickStartWizardDialogState {
  // STEP 4: SAFETY

  Widget _buildSafetyStep(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Configure safety and shutdown behavior.',
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
          icon: LucideIcons.snowflake,
          title: 'Cool camera',
          subtitle: 'Cool the camera sensor before imaging and warm after',
          value: _coolCamera,
          onChanged: (v) => _update(() => _coolCamera = v),
        ),
        if (_coolCamera) ...[
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Row(
              children: [
                Text('Target temperature:',
                    style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: SkotiqTypography.fontSize12)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  height: 32,
                  child: TextField(
                    controller: _coolingTempController,
                    style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: SkotiqTypography.fontSize12),
                    keyboardType:
                        const TextInputType.numberWithOptions(signed: true),
                    decoration: InputDecoration(
                      suffixText: 'C',
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
                      if (parsed != null) {
                        _update(() => _coolingTemp = parsed);
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
          icon: LucideIcons.parkingCircle,
          title: 'Park on Error',
          subtitle: 'Park the mount if an unrecoverable error occurs',
          value: _parkOnError,
          onChanged: (v) => _update(() => _parkOnError = v),
        ),
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.cloudRain,
          title: 'Weather abort',
          subtitle: 'Park and abort if the weather becomes unsafe',
          value: _weatherAbort,
          onChanged: (v) => _update(() => _weatherAbort = v),
        ),
        _buildToggleRow(
          colors: colors,
          icon: LucideIcons.sunrise,
          title: 'Dawn shutdown',
          subtitle: 'Warm camera and park mount at the end of the session',
          value: _dawnShutdown,
          onChanged: (v) => _update(() => _dawnShutdown = v),
        ),
      ],
    );
  }
}
