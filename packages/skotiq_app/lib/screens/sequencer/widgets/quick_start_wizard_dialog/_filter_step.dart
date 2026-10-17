// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _FilterStep on _QuickStartWizardDialogState {
  // STEP 2: FILTERS & EXPOSURES

  Widget _buildFiltersStep(SkotiqColors colors) {
    final hasFilters = _hasConfiguredFilters;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasFilters) ...[
          Text(
            'Quick Presets',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _ExposurePreset.values.map((preset) {
              final isSelected = _selectedPreset == preset;
              return InkWell(
                onTap: () => _applyPreset(preset),
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? SkotiqDecorations.statusChip(
                            colors.primary,
                            borderRadius: BorderRadius.circular(
                                SkotiqTokens.radiusInline8),
                            bordered: false,
                          ).color
                        : colors.surfaceAlt,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(
                      color: isSelected ? colors.primary : colors.border,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preset.label,
                        style: SkotiqTypography.h6.copyWith(
                            color: isSelected
                                ? colors.primary
                                : colors.textPrimary),
                      ),
                      Text(
                        preset.description,
                        style: TextStyle(
                            color: colors.textMuted,
                            fontSize: SkotiqTypography.fontSize10),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
        ],

        Text(
          hasFilters ? 'Filter Exposures' : 'Exposure Settings',
          style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 8),

        // Column headers
        Padding(
          padding: const EdgeInsets.only(left: 40),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text('Filter',
                    style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11)),
              ),
              Expanded(
                flex: 2,
                child: Text('Exposure',
                    style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11)),
              ),
              Expanded(
                flex: 2,
                child: Text('Binning',
                    style: TextStyle(
                        color: colors.textMuted,
                        fontSize: SkotiqTypography.fontSize11)),
              ),
              const SizedBox(width: 60),
            ],
          ),
        ),
        const SizedBox(height: 4),

        ...List.generate(_filterConfigs.length, (index) {
          final config = _filterConfigs[index];
          return _buildFilterRow(config, colors);
        }),

        const SizedBox(height: 20),

        Text(
          'Frames per filter',
          style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _loopCountController,
                style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize13),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Frames per filter',
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  labelStyle: TextStyle(color: colors.textSecondary),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed > 0) {
                    _update(() {
                      _loopCount = parsed;
                    });
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Text(
                'Each selected filter captures exactly this many frames.',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: SkotiqTypography.fontSize12,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterRow(_FilterExposureConfig config, SkotiqColors colors) {
    final controller = _filterControllers[config.filterIndex];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: SkotiqCheckbox(
              value: config.enabled,
              onChanged: (value) {
                _update(() {
                  config.enabled = value ?? false;
                  _selectedPreset = _ExposurePreset.custom;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              config.filterName,
              style: TextStyle(
                color: config.enabled ? colors.textPrimary : colors.textMuted,
                fontSize: SkotiqTypography.fontSize13,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: controller,
                enabled: config.enabled,
                style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize12),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  suffixText: 's',
                  suffixStyle: TextStyle(
                      color: colors.textMuted,
                      fontSize: SkotiqTypography.fontSize11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed != null && parsed > 0) {
                    _update(() {
                      config.exposureSecs = parsed;
                      config.exposureEdited = true;
                      _selectedPreset = _ExposurePreset.custom;
                    });
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 32,
              child: AccessibleDropdownFormField<BinningMode>(
                initialValue: config.binning,
                dropdownColor: colors.surfaceAlt,
                style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize12),
                decoration: InputDecoration(
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                items: BinningMode.values.map((mode) {
                  return DropdownMenuItem(
                    value: mode,
                    child: Text(mode.label,
                        style: TextStyle(color: colors.textPrimary)),
                  );
                }).toList(),
                onChanged: config.enabled
                    ? (value) {
                        if (value != null) {
                          _update(() {
                            config.binning = value;
                            _selectedPreset = _ExposurePreset.custom;
                          });
                        }
                      }
                    : null,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              _formatFilterTotal(config),
              style: TextStyle(
                color: config.enabled ? colors.textSecondary : colors.textMuted,
                fontSize: SkotiqTypography.fontSize11,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  String _formatFilterTotal(_FilterExposureConfig config) {
    if (!config.enabled) return '';
    final totalMins = (config.totalSecs * _loopCount / 60).round();
    return '${totalMins}m';
  }
}
