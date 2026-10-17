// ignore_for_file: invalid_use_of_protected_member

part of '../profile_editor_dialog.dart';

extension _ProfileEditorOpticalAndDevices on _ProfileEditorDialogState {
  // Section 2: optical train

  Widget _buildOpticalTrainSection(SkotiqColors colors, ThemeData theme) {
    return _SectionBlock(
      title: 'Optical train',
      icon: LucideIcons.target,
      isExpanded: _expandedSections['optical']!,
      onToggle: () => setState(
          () => _expandedSections['optical'] = !_expandedSections['optical']!),
      summary: _telescopeNameController.text.isEmpty
          ? 'Not configured'
          : _telescopeNameController.text,
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // One-tap prefill from the built-in + user telescope library (C10).
          // Manual entry below remains fully available afterwards.
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              // lucide_icons ships no `telescope` glyph; `aperture` is this
              // codebase's established optics/telescope icon (the onboarding
              // optical-train step uses the same).
              icon: LucideIcons.aperture,
              label: 'Telescope library',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: _pickTelescopeFromLibrary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _EditorRow(
            label: 'Telescope / OTA',
            child: SkotiqTextField(
              controller: _telescopeNameController,
              hint: 'e.g., Esprit 100ED, RC8',
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Focal length',
            trailing: helpAffordance(
              context,
              title: 'Focal length (mm)',
              body: "The telescope's NATIVE focal length in millimetres "
                  '— on the OTA label or its spec sheet. Enter any '
                  'reducer or barlow separately below; the profile '
                  'stores the two multiplied together as the focal '
                  'length everything else images at.',
            ),
            child: SkotiqTextField(
              controller: _focalLengthController,
              hint: 'e.g., 550',
              suffix: 'mm',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.focalLength],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) {
                clearFieldError(ProfileEditorField.focalLength);
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: _rowGap),
          _EditorRow(
            label: 'Aperture',
            trailing: helpAffordance(
              context,
              title: 'Aperture (mm)',
              body: 'The diameter of the telescope in millimetres. '
                  'Focal length ÷ aperture gives your focal ratio and '
                  'sets how much light you gather.',
            ),
            child: SkotiqTextField(
              controller: _apertureController,
              hint: 'e.g., 100',
              suffix: 'mm',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.aperture],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) {
                clearFieldError(ProfileEditorField.aperture);
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: _rowGap),
          // Reducer / barlow. Without this field the profile's effective focal
          // length was unrepresentable here, so opening a reducer'd rig (the
          // wizard is the only other surface that can set one) and pressing
          // Save quietly multiplied its focal length back up by 1/reducer.
          _EditorRow(
            label: 'Reducer / barlow',
            trailing: helpAffordance(
              context,
              title: 'Reducer or barlow factor',
              body: 'The multiplier printed on the reducer or barlow — 0.8 '
                  'for a 0.8x reducer, 2 for a 2x barlow. Leave blank (or 1) '
                  'when the camera is at prime focus. Focal length x this factor '
                  'is what the rig actually images at.',
            ),
            child: SkotiqTextField(
              controller: _reducerController,
              hint: '1 (none)',
              suffix: '×',
              mono: true,
              errorText: _fieldErrors[ProfileEditorField.reducer],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) {
                clearFieldError(ProfileEditorField.reducer);
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Computed values, in a well. A Wrap, not a Row: the effective focal
          // length is a third entry on a 640px-wide dialog that a Row would
          // overflow.
          Container(
            padding: SkotiqTokens.paddingMd,
            decoration: SkotiqDecorations.well(colors),
            child: Wrap(
              spacing: SkotiqTokens.space3xl,
              runSpacing: SkotiqTokens.spaceMd,
              children: [
                _ComputedValue(
                  label: 'Focal ratio',
                  value: _computedFRatio != null
                      ? 'f/${_computedFRatio!.toStringAsFixed(1)}'
                      : null,
                  colors: colors,
                ),
                _ComputedValue(
                  label: 'Image scale',
                  value: _computedScale != null
                      ? '${_computedScale!.toStringAsFixed(2)}"/px'
                      : null,
                  subtitle: _pixelSize != null
                      ? 'at ${_pixelSize!.toStringAsFixed(2)}µm'
                      : null,
                  colors: colors,
                ),
                // Shown only when a reducer/barlow is in the train, where the
                // stored focal length differs from the typed one.
                if (_effectiveFocalLengthMm != null &&
                    _effectiveFocalLengthMm !=
                        double.tryParse(_focalLengthController.text.trim()))
                  _ComputedValue(
                    label: 'Effective focal length',
                    value: '${_formatOptic(_effectiveFocalLengthMm!)} mm',
                    subtitle: 'stored in the profile',
                    colors: colors,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Open the telescope library (C10) and, on selection, prefill the OTA name,
  /// focal length, and aperture fields. Manual edits afterwards remain fully
  /// available — this is a one-tap convenience, not a lock-in.
  Future<void> _pickTelescopeFromLibrary() async {
    final preset = await HardwarePresetPickerDialog.showTelescope(context);
    if (preset == null || !mounted) return;
    setState(() {
      _telescopeNameController.text = preset.displayName;
      // The presets store whole-number optics as e.g. 550.0; render them as
      // plain integers when they have no fractional part to match how a user
      // would type the value.
      _focalLengthController.text = _formatOptic(preset.focalLengthMm);
      _apertureController.text = _formatOptic(preset.apertureMm);
    });
  }

  /// Format an optic dimension: integral values as a bare integer (e.g. `550`),
  /// otherwise with its decimal places (e.g. `714.5`).
  static String _formatOptic(double value) {
    return value == value.roundToDouble()
        ? value.round().toString()
        : value.toString();
  }

  // Section 3: devices

  Widget _buildDevicesSection(SkotiqColors colors, ThemeData theme) {
    final discovery = ref.watch(unifiedDiscoveryProvider);
    final cameras = discovery.getDevicesByType(DeviceType.camera);
    final mounts = discovery.getDevicesByType(DeviceType.mount);
    final focusers = discovery.getDevicesByType(DeviceType.focuser);
    final filterWheels = discovery.getDevicesByType(DeviceType.filterWheel);
    final guiders = discovery.getDevicesByType(DeviceType.guider);
    final rotators = discovery.getDevicesByType(DeviceType.rotator);
    final domes = discovery.getDevicesByType(DeviceType.dome);
    final weatherStations = discovery.getDevicesByType(DeviceType.weather);
    final safetyMonitors = discovery.getDevicesByType(DeviceType.safetyMonitor);
    final switches = discovery.getDevicesByType(DeviceType.switch_);
    final coverCalibrators =
        discovery.getDevicesByType(DeviceType.coverCalibrator);

    // Fire-and-forget backend scan; the watch on unifiedDiscoveryProvider above
    // rebuilds this section (and its dropdowns) when results arrive.
    void onScan() {
      ref.read(unifiedDiscoveryProvider.notifier).discoverAll();
    }

    return _SectionBlock(
      title: 'Devices',
      icon: LucideIcons.plugZap,
      isExpanded: _expandedSections['devices']!,
      onToggle: () => setState(
          () => _expandedSections['devices'] = !_expandedSections['devices']!),
      summary: _countAssignedDevices() > 0
          ? '${_countAssignedDevices()} assigned'
          : 'None assigned',
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Camera
          _DeviceRow(
            type: 'Camera',
            nameController: _cameraNameController,
            deviceId: _cameraId,
            discoveredDevices: cameras,
            onDeviceSelected: (id, name) => setState(() {
              _cameraId = id;
              if (name != null && _cameraNameController.text.isEmpty) {
                _cameraNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _cameraId = null;
              _cameraNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          // Mount
          _DeviceRow(
            type: 'Mount',
            nameController: _mountNameController,
            deviceId: _mountId,
            discoveredDevices: mounts,
            onDeviceSelected: (id, name) => setState(() {
              _mountId = id;
              if (name != null && _mountNameController.text.isEmpty) {
                _mountNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _mountId = null;
              _mountNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          // Focuser
          _DeviceRow(
            type: 'Focuser',
            nameController: _focuserNameController,
            deviceId: _focuserId,
            discoveredDevices: focusers,
            onDeviceSelected: (id, name) => setState(() {
              _focuserId = id;
              if (name != null && _focuserNameController.text.isEmpty) {
                _focuserNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _focuserId = null;
              _focuserNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          // Filter wheel
          _DeviceRow(
            type: 'Filter wheel',
            nameController: _filterWheelNameController,
            deviceId: _filterWheelId,
            discoveredDevices: filterWheels,
            onDeviceSelected: (id, name) => setState(() {
              _filterWheelId = id;
              if (name != null && _filterWheelNameController.text.isEmpty) {
                _filterWheelNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _filterWheelId = null;
              _filterWheelNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          // Guider
          _DeviceRow(
            type: 'Guider',
            nameController: _guiderNameController,
            deviceId: _guiderId,
            discoveredDevices: guiders,
            onDeviceSelected: (id, name) => setState(() {
              _guiderId = id;
              if (name != null && _guiderNameController.text.isEmpty) {
                _guiderNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _guiderId = null;
              _guiderNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          // Rotator
          _DeviceRow(
            type: 'Rotator',
            nameController: _rotatorNameController,
            deviceId: _rotatorId,
            discoveredDevices: rotators,
            onDeviceSelected: (id, name) => setState(() {
              _rotatorId = id;
              if (name != null && _rotatorNameController.text.isEmpty) {
                _rotatorNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _rotatorId = null;
              _rotatorNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          _DeviceRow(
            type: 'Dome',
            nameController: null,
            deviceId: _domeId,
            discoveredDevices: domes,
            onDeviceSelected: (id, name) => setState(() {
              _domeId = id;
            }),
            onClear: () => setState(() {
              _domeId = null;
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          _DeviceRow(
            type: 'Weather',
            nameController: null,
            deviceId: _weatherId,
            discoveredDevices: weatherStations,
            onDeviceSelected: (id, name) => setState(() {
              _weatherId = id;
            }),
            onClear: () => setState(() {
              _weatherId = null;
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          _DeviceRow(
            type: 'Safety monitor',
            nameController: _safetyMonitorNameController,
            deviceId: _safetyMonitorId,
            discoveredDevices: safetyMonitors,
            onDeviceSelected: (id, name) => setState(() {
              _safetyMonitorId = id;
              if (name != null && _safetyMonitorNameController.text.isEmpty) {
                _safetyMonitorNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _safetyMonitorId = null;
              _safetyMonitorNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          _DeviceRow(
            type: 'Switch',
            nameController: _switchNameController,
            deviceId: _switchId,
            discoveredDevices: switches,
            onDeviceSelected: (id, name) => setState(() {
              _switchId = id;
              if (name != null && _switchNameController.text.isEmpty) {
                _switchNameController.text = name;
              }
            }),
            onClear: () => setState(() {
              _switchId = null;
              _switchNameController.clear();
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: _rowGap),

          _DeviceRow(
            type: 'Cover / calibrator',
            nameController: null,
            deviceId: _coverCalibratorId,
            discoveredDevices: coverCalibrators,
            onDeviceSelected: (id, name) => setState(() {
              _coverCalibratorId = id;
            }),
            onClear: () => setState(() {
              _coverCalibratorId = null;
            }),
            onScan: onScan,
            colors: colors,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // Add from connected button
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: 'Add from connected',
              icon: LucideIcons.plus,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: _populateFromConnected,
            ),
          ),
        ],
      ),
    );
  }

  int _countAssignedDevices() {
    int count = 0;
    if (_cameraId != null) count++;
    if (_mountId != null) count++;
    if (_focuserId != null) count++;
    if (_filterWheelId != null) count++;
    if (_guiderId != null) count++;
    if (_rotatorId != null) count++;
    if (_domeId != null) count++;
    if (_weatherId != null) count++;
    if (_safetyMonitorId != null) count++;
    if (_switchId != null) count++;
    if (_coverCalibratorId != null) count++;
    return count;
  }
}
