// ignore_for_file: invalid_use_of_protected_member

part of '../profile_editor_dialog.dart';

/// The binning factors this editor offers. Square only (binX == binY).
const List<int> _binningFactors = [1, 2, 3, 4];

/// Width of the label column in the SDK recommendation well.
const double _recommendationLabelWidth = 104;

/// Widest the "connect a camera" note beside the auto-detect buttons gets.
const double _autoDetectNoteMaxWidth = 240;

extension _ProfileEditorFiltersAndCameraDefaults on _ProfileEditorDialogState {
  // Section 4: filters

  Widget _buildFiltersSection(SkotiqColors colors, ThemeData theme) {
    final filterWheelState = ref.watch(filterWheelStateProvider);
    final wheelConnected =
        filterWheelState.connectionState == DeviceConnectionState.connected &&
            (filterWheelState.deviceId?.isNotEmpty ?? false);
    return _SectionBlock(
      title: 'Filters (${_filterControllers.length} slots)',
      icon: LucideIcons.filter,
      isExpanded: _expandedSections['filters']!,
      onToggle: () => setState(
          () => _expandedSections['filters'] = !_expandedSections['filters']!),
      summary: _filterControllers.isEmpty
          ? 'No filters'
          : countLabel(_filterControllers.length, 'filter'),
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The table sits in a well — the one level of nesting a dialog
          // surface is allowed (02 §2).
          Container(
            decoration: SkotiqDecorations.well(colors),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Column headings
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceSm,
                    SkotiqTokens.spaceSm,
                    SkotiqTokens.spaceSm,
                    SkotiqTokens.spaceXs,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: _filterIndexWidth),
                      Expanded(
                        child: Text(
                          'Filter name'.toUpperCase(),
                          style: SkotiqTypography.eyebrow
                              .copyWith(color: colors.textMuted),
                        ),
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      SizedBox(
                        width: _filterOffsetWidth,
                        child: Text(
                          'Focus offset'.toUpperCase(),
                          style: SkotiqTypography.eyebrow
                              .copyWith(color: colors.textMuted),
                        ),
                      ),
                      // Space for the remove button.
                      const SizedBox(
                        width: SkotiqTokens.iconButtonSizeSm +
                            SkotiqTokens.spaceXs,
                      ),
                    ],
                  ),
                ),

                // Filter rows
                if (_filterControllers.isEmpty)
                  Padding(
                    padding: SkotiqTokens.paddingLg,
                    child: Text(
                      'No filters configured',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                    ),
                  )
                else
                  ..._filterControllers.asMap().entries.map((entry) {
                    final index = entry.key;
                    final pair = entry.value;
                    return _FilterRow(
                      index: index + 1,
                      nameController: pair.nameController,
                      offsetController: pair.offsetController,
                      onRemove: () => _removeFilter(index),
                      isLast: index == _filterControllers.length - 1,
                      colors: colors,
                    );
                  }),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Action buttons
          Row(
            children: [
              SkotiqButton(
                label: 'Add filter',
                icon: LucideIcons.plus,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: _addFilter,
              ),
              const Spacer(),
              SkotiqTooltip(
                message: wheelConnected
                    ? 'Read the filter names from the connected wheel.'
                    : 'Connect the filter wheel to auto-detect filters',
                child: SkotiqButton(
                  label: 'Auto-detect from wheel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: wheelConnected ? _autoDetectFilters : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Section 5: camera defaults

  Widget _buildCameraDefaultsSection(SkotiqColors colors, ThemeData theme) {
    return _SectionBlock(
      title: 'Camera defaults',
      icon: LucideIcons.settings2,
      isExpanded: _expandedSections['camera']!,
      onToggle: () => setState(
          () => _expandedSections['camera'] = !_expandedSections['camera']!),
      summary:
          _gainController.text.isEmpty && _coolingTargetController.text.isEmpty
              ? 'Not configured'
              : 'Configured',
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _EditorRow(
            label: 'Gain',
            child: SkotiqTextField(
              controller: _gainController,
              hint: 'e.g., 100',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.gain],
              onChanged: (_) => clearFieldError(ProfileEditorField.gain),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Offset',
            child: SkotiqTextField(
              controller: _offsetController,
              hint: 'e.g., 10',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.offset],
              onChanged: (_) => clearFieldError(ProfileEditorField.offset),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Binning',
            child: Align(
              alignment: Alignment.centerLeft,
              child: SkotiqDropdown(
                value: _binning.toString(),
                items: [for (final b in _binningFactors) b.toString()],
                itemLabels: [for (final b in _binningFactors) '$b×$b'],
                onChanged: (v) => setState(
                  () => _binning = int.tryParse(v ?? '') ?? 1,
                ),
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // SDK auto-detect button + recommendation well.
          // The button is only useful when a camera is selected on this
          // profile (so we have a device_id to query).
          _buildAutoDetectRow(colors),
          if (_recommendedSettings != null)
            _buildRecommendationCard(colors, _recommendedSettings!),
          const SizedBox(height: SkotiqTokens.spaceLg),

          _EditorRow(
            label: 'Cooling target',
            child: SkotiqTextField(
              controller: _coolingTargetController,
              hint: 'e.g., -10',
              suffix: '°C',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.coolingTarget],
              onChanged: (_) =>
                  clearFieldError(ProfileEditorField.coolingTarget),
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
            ),
          ),
          const SizedBox(height: _rowGap),
          SkotiqSwitchRow(
            label: 'Cool on connect',
            value: _coolOnConnect,
            onChanged: (v) => setState(() => _coolOnConnect = v),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Centering exposure',
            help: 'Used for plate-solve centering; adjustable per session in '
                'the centering dialog.',
            child: SkotiqTextField(
              controller: _centeringExposureController,
              hint: 'e.g., 5',
              suffix: 's',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.centeringExposure],
              onChanged: (_) =>
                  clearFieldError(ProfileEditorField.centeringExposure),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Auto-detect recommended camera gain/offset

  /// Build the auto-detect button row.
  ///
  /// The button is enabled only when the user has selected (or auto-populated)
  /// a camera id for this profile AND that camera is currently connected.
  /// Without a live camera we have no SDK to query.
  Widget _buildAutoDetectRow(SkotiqColors colors) {
    final cameraState = ref.watch(cameraStateProvider);
    final liveDeviceId =
        cameraState.connectionState == DeviceConnectionState.connected
            ? cameraState.deviceId
            : null;
    // Prefer the connected camera's id when it matches what the profile has
    // selected; otherwise fall back to the live device.
    final queryDeviceId = (_cameraId != null && _cameraId == liveDeviceId)
        ? _cameraId
        : liveDeviceId;

    final enabled = queryDeviceId != null && !_isQueryingRecommendation;
    final disabledReason = queryDeviceId == null
        ? 'Connect a camera to query its SDK for recommended gain/offset.'
        : null;

    return Wrap(
      spacing: SkotiqTokens.spaceMd,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SkotiqTooltip(
          message: disabledReason ??
              'Query the connected camera SDK for the '
                  'manufacturer-recommended unity gain and offset.',
          child: SkotiqButton(
            onPressed: enabled ? () => _runAutoDetect(queryDeviceId) : null,
            icon: LucideIcons.zap,
            label: 'Auto-detect from camera',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: _isQueryingRecommendation,
          ),
        ),
        // Camera library (C10): a curated fallback that does NOT require a live
        // camera. It complements the SDK auto-detect above — the user can pull
        // sensible gain/offset (+ binning, cooling) from the built-in catalog
        // even when no camera is connected.
        SkotiqButton(
          label: 'Camera library',
          icon: LucideIcons.camera,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _pickCameraFromLibrary,
        ),
        if (disabledReason != null)
          ConstrainedBox(
            constraints:
                const BoxConstraints(maxWidth: _autoDetectNoteMaxWidth),
            child: Text(
              disabledReason,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
  }

  /// Open the camera library (C10) and, on selection, prefill the camera
  /// defaults: gain, offset, binning, and (when the preset has regulated
  /// cooling) the cooling set-point. Cameras without cooling leave the cooling
  /// field untouched rather than collapsing it to 0 °C.
  Future<void> _pickCameraFromLibrary() async {
    final preset = await HardwarePresetPickerDialog.showCamera(context);
    if (preset == null || !mounted) return;
    setState(() {
      _gainController.text = preset.recommendedGain.toString();
      _offsetController.text = preset.recommendedOffset.toString();
      // The binning dropdown is square (binX == binY) in this editor; presets
      // store the recommended X binning, which we apply directly when it is one
      // of the offered factors.
      if (preset.recommendedBinX >= 1 && preset.recommendedBinX <= 4) {
        _binning = preset.recommendedBinX;
      }
      final coolingTemp = preset.recommendedCoolingTempC;
      if (coolingTemp != null) {
        _coolingTargetController.text =
            _ProfileEditorOpticalAndDevices._formatOptic(coolingTemp);
      }
    });
  }

  /// The well that surfaces the SDK-reported recommendation.
  ///
  /// All values are shown verbatim — a field the SDK returned null for reads as
  /// [kReadoutUnknown], never as an invented number.
  Widget _buildRecommendationCard(
      SkotiqColors colors, CameraRecommendedSettings rec) {
    final hasAny = rec.unityGain != null || rec.defaultOffset != null;
    final canApplyGain = rec.unityGain != null &&
        rec.unityGain.toString() != _gainController.text;
    final canApplyOffset = rec.defaultOffset != null &&
        rec.defaultOffset.toString() != _offsetController.text;

    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      child: Container(
        padding: SkotiqTokens.paddingMd,
        decoration: SkotiqDecorations.well(colors),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  hasAny ? LucideIcons.info : LucideIcons.alertCircle,
                  size: SkotiqTokens.iconXs,
                  color: hasAny ? colors.primary : colors.textMuted,
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    hasAny
                        ? 'The camera SDK reports'
                        : 'The camera SDK reported no recommendation',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textPrimary),
                  ),
                ),
              ],
            ),
            if (hasAny) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              _buildRecRow('Unity gain', rec.unityGain, colors),
              _buildRecRow('HCG gain', rec.hcgGain, colors),
              _buildRecRow('Default offset', rec.defaultOffset, colors),
            ],
            if (rec.notes.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                rec.notes,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
            ],
            if (canApplyGain || canApplyOffset) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  onPressed: () => _applyRecommendation(rec),
                  icon: LucideIcons.check,
                  label:
                      'Apply${(canApplyGain && canApplyOffset) ? ' both' : canApplyGain ? ' gain' : ' offset'}',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRecRow(String label, int? value, SkotiqColors colors) {
    // No padding of its own: the caption's line height is the row rhythm, and
    // the sub-4px gap this used to carry has no place on the 4px grid.
    return Row(
      children: [
        SizedBox(
          width: _recommendationLabelWidth,
          child: Text(
            label,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
        ),
        Text(
          value == null ? kReadoutUnknown : value.toString(),
          style: SkotiqTypography.monoCaption.copyWith(
            color: value == null ? colors.textMuted : colors.textPrimary,
          ),
        ),
      ],
    );
  }

  Future<void> _runAutoDetect(String deviceId) async {
    setState(() {
      _isQueryingRecommendation = true;
    });
    try {
      final rec = await ref
          .read(deviceServiceProvider)
          .queryRecommendedCameraSettings(deviceId);
      if (!mounted) return;
      setState(() {
        _recommendedSettings = rec;
      });
    } catch (e) {
      if (!mounted) return;
      // Surface the failure to the user — never silently fall back.
      context.showErrorSnackBar('Auto-detect failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isQueryingRecommendation = false;
        });
      }
    }
  }

  void _applyRecommendation(CameraRecommendedSettings rec) {
    setState(() {
      if (rec.unityGain != null) {
        _gainController.text = rec.unityGain.toString();
      }
      if (rec.defaultOffset != null) {
        _offsetController.text = rec.defaultOffset.toString();
      }
    });
  }
}
