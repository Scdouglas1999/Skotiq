// ignore_for_file: unused_element

part of '../quick_start_wizard_dialog.dart';

extension _ReviewStep on _QuickStartWizardDialogState {
  // STEP 5: REVIEW

  Widget _buildReviewStep(SkotiqColors colors) {
    final enabledFilters = _filterConfigs.where((f) => f.enabled).toList();
    final totalSecs = _estimatedTotalSecs();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Review your sequence before creating it.',
          style: TextStyle(
              color: colors.textSecondary,
              fontSize: SkotiqTypography.fontSize13),
        ),
        const SizedBox(height: 16),

        // Target summary
        _buildReviewSection(
          colors: colors,
          icon: LucideIcons.target,
          title: 'Target',
          children: [
            _reviewRow(colors, 'Name', _targetNameController.text),
            _reviewRow(colors, 'RA', _raController.text),
            _reviewRow(colors, 'Dec', _decController.text),
          ],
        ),

        const SizedBox(height: 12),

        // Filters summary
        _buildReviewSection(
          colors: colors,
          icon: LucideIcons.camera,
          title:
              'Exposures (${enabledFilters.length} filter${enabledFilters.length != 1 ? "s" : ""})',
          children: [
            for (final f in enabledFilters) ...[
              _reviewRow(
                colors,
                f.filterName,
                '${_loopCount}x ${f.exposureSecs.round()}s (${f.binning.label})',
              ),
              _buildExposureRationale(colors, f),
            ],
            const SizedBox(height: 6),
            // Re-preview: regenerate the recommended exposures after the user
            // changed knobs, without leaving the Review step. User-edited
            // rows are preserved.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _rePreviewExposures,
                icon: Icon(LucideIcons.refreshCw,
                    size: 14, color: colors.primary),
                label: Text(
                  'Re-preview recommended exposures',
                  style: TextStyle(
                      color: colors.primary,
                      fontSize: SkotiqTypography.fontSize12),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // Capture count summary
        _buildReviewSection(
          colors: colors,
          icon: LucideIcons.repeat,
          title: 'Capture count',
          children: [
            _reviewRow(
              colors,
              'Frames per filter',
              '$_loopCount',
            ),
          ],
        ),

        const SizedBox(height: 12),

        // Automation summary
        _buildReviewSection(
          colors: colors,
          icon: LucideIcons.settings,
          title: 'Automation',
          children: [
            _reviewRow(colors, 'Autofocus',
                _enableAutofocus ? 'Enabled (HFR-based)' : 'Disabled'),
            _reviewRow(colors, 'Dithering',
                _enableDithering ? '${_ditherPixels.round()}px' : 'Disabled'),
            _reviewRow(colors, 'Meridian Flip',
                _enableMeridianFlip ? 'Enabled' : 'Disabled'),
            _reviewRow(colors, 'Auto-Guide',
                _enableAutoGuide ? 'Enabled' : 'Disabled'),
          ],
        ),

        const SizedBox(height: 12),

        // Safety summary
        _buildReviewSection(
          colors: colors,
          icon: LucideIcons.shield,
          title: 'Safety',
          children: [
            _reviewRow(colors, 'Cool Camera',
                _coolCamera ? '${_coolingTemp.round()}C' : 'Disabled'),
            _reviewRow(
                colors, 'Park on Error', _parkOnError ? 'Enabled' : 'Disabled'),
            _reviewRow(colors, 'Weather Abort',
                _weatherAbort ? 'Enabled' : 'Disabled'),
            _reviewRow(colors, 'Dawn Shutdown',
                _dawnShutdown ? 'Enabled' : 'Disabled'),
          ],
        ),

        const SizedBox(height: 16),

        // Estimated time
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: SkotiqDecorations.emphasisSurface(
            colors.primary,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.clock, color: colors.primary, size: 20),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Estimated Duration',
                    style: SkotiqTypography.h6.copyWith(color: colors.primary),
                  ),
                  Text(
                    _formatDuration(totalSecs),
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: SkotiqTypography.fontSize16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Opt-in: persist these choices as the user's new defaults.
        InkWell(
          onTap: () => _update(() => _saveAsDefaults = !_saveAsDefaults),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SkotiqCheckbox(
                  value: _saveAsDefaults,
                  onChanged: (v) => _update(() => _saveAsDefaults = v ?? false),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Save these as my defaults (autofocus cadence, dither, '
                    'exposure count, meridian flip, weather and dawn safety)',
                    style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: SkotiqTypography.fontSize12),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Tree preview
        _buildTreePreview(colors, enabledFilters),
      ],
    );
  }

  /// Render the smart exposure recommendation's rationale under a filter row
  /// when a recommendation is available for that filter. Read-only — surfaces
  /// the "why this exposure" already computed in [_exposureContext].
  Widget _buildExposureRationale(
      SkotiqColors colors, _FilterExposureConfig config) {
    final context = _exposureContext;
    if (context == null) return const SizedBox.shrink();
    final rec = context.recommendForFilter(config.filterName);
    if (rec.rationale.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 120, bottom: 4),
      child: Text(
        rec.rationale,
        style: TextStyle(
            color: colors.textMuted,
            fontSize: SkotiqTypography.fontSize10,
            fontStyle: FontStyle.italic),
      ),
    );
  }

  Widget _buildReviewSection({
    required SkotiqColors colors,
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: colors.primary, size: 16),
              const SizedBox(width: 8),
              Text(
                title,
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }

  Widget _reviewRow(SkotiqColors colors, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: TextStyle(
                    color: colors.textMuted,
                    fontSize: SkotiqTypography.fontSize12)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: SkotiqTypography.fontSize12)),
          ),
        ],
      ),
    );
  }

  Widget _buildTreePreview(
      SkotiqColors colors, List<_FilterExposureConfig> enabledFilters) {
    // Build a visual tree preview of what will be created
    final treeLines = <_TreeLine>[];

    treeLines.add(_TreeLine(
      'Target: ${_targetNameController.text}',
      LucideIcons.target,
      0,
    ));

    if (_coolCamera) {
      treeLines.add(_TreeLine(
          'Cool Camera (${_coolingTemp.round()}C)', LucideIcons.snowflake, 1));
    }
    treeLines.add(_TreeLine('Slew to Target', LucideIcons.compass, 1));
    treeLines.add(_TreeLine('Plate Solve & Center', LucideIcons.crosshair, 1));
    if (_enableAutofocus) {
      treeLines.add(_TreeLine('Autofocus', LucideIcons.focus, 1));
    }
    if (_enableAutoGuide) {
      treeLines.add(_TreeLine('Start Guiding', LucideIcons.crosshair, 1));
    }

    final loopLabel = 'Capture Loop ($_loopCount frames/filter)';
    treeLines.add(_TreeLine(loopLabel, LucideIcons.repeat, 1));

    for (final f in enabledFilters) {
      treeLines.add(_TreeLine(
        '${f.filterName}: ${f.exposureSecs.round()}s',
        LucideIcons.camera,
        2,
      ));
    }
    if (_enableDithering && _enableAutoGuide) {
      treeLines.add(_TreeLine('Dither', LucideIcons.shuffle, 2));
    }

    if (_enableAutoGuide) {
      treeLines.add(_TreeLine('Stop Guiding', LucideIcons.xCircle, 1));
    }
    if (_coolCamera) {
      treeLines.add(_TreeLine('Warm Camera', LucideIcons.flame, 1));
    }
    if (_dawnShutdown) {
      treeLines.add(_TreeLine('Park Mount', LucideIcons.parkingCircle, 1));
    }

    // Triggers
    if (_enableAutofocus) {
      treeLines
          .add(_TreeLine('HFR Refocus Trigger', LucideIcons.shieldCheck, 1));
    }
    if (_enableMeridianFlip) {
      treeLines.add(_TreeLine('Meridian Flip', LucideIcons.refreshCw, 1));
    }
    if (_weatherAbort) {
      treeLines.add(_TreeLine('Weather Safety', LucideIcons.cloudRain, 1));
    }
    if (_parkOnError) {
      treeLines.add(_TreeLine('Park on Error', LucideIcons.parkingCircle, 1));
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sequence Tree Preview',
            style: SkotiqTypography.labelStrongSm
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 8),
          ...treeLines.map((line) {
            return Padding(
              padding: EdgeInsets.only(left: line.depth * 20.0, bottom: 2),
              child: Row(
                children: [
                  Icon(line.icon, color: colors.textMuted, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    line.label,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: SkotiqTypography.fontSize12,
                      fontFamily: SkotiqTypography.fontFamilyMono,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _TreeLine {
  final String label;
  final IconData icon;
  final int depth;

  _TreeLine(this.label, this.icon, this.depth);
}
