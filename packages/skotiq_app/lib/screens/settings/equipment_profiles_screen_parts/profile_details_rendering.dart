part of '../equipment_profiles_screen.dart';

extension _ProfileDetailsRendering on _ProfileDetailsState {
  /// Read-only text for an optic. `0` is the model's "unspecified" sentinel,
  /// and "0 mm" read as a measured zero-length telescope.
  String _opticDisplay(double value) =>
      value > 0 ? '${value.toStringAsFixed(0)} mm' : 'Not set';

  Widget _buildDetails(BuildContext context) {
    final padding = widget.isMobile ? 16.0 : 32.0;

    Widget content = SingleChildScrollView(
      padding: EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.isEditing)
                      _EditableField(
                        controller: _nameController,
                        style: SkotiqTypography.pageTitle.copyWith(
                          color: SkotiqColors.of(context).textPrimary,
                        ),
                      )
                    else
                      Text(
                        widget.profile.name,
                        style: SkotiqTypography.pageTitle.copyWith(
                          color: SkotiqColors.of(context).textPrimary,
                        ),
                      ),
                    const SizedBox(height: 4),
                    if (widget.isEditing)
                      _EditableField(
                        controller: _descController,
                        hint: 'Add a description...',
                        style: SkotiqTypography.bodySm.copyWith(
                          color: SkotiqColors.of(context).textSecondary,
                        ),
                      )
                    else
                      Text(
                        widget.profile.description ?? 'No description',
                        style: SkotiqTypography.bodySm.copyWith(
                          color: SkotiqColors.of(context).textMuted,
                        ),
                      ),
                  ],
                ),
              ),

              // Action buttons
              if (widget.isEditing) ...[
                SkotiqButton(
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: _isSaving ? null : widget.onCancel,
                ),
                const SizedBox(width: 8),
                SkotiqButton(
                  label: 'Save',
                  icon: LucideIcons.check,
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                  isLoading: _isSaving,
                  onPressed: _isSaving ? null : _handleSave,
                ),
              ] else ...[
                if (!widget.isActive)
                  SkotiqButton(
                    label: 'Set active',
                    icon: LucideIcons.check,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: widget.onSetActive,
                  ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  icon: Icon(LucideIcons.moreVertical,
                      color: SkotiqColors.of(context).textSecondary),
                  color: SkotiqColors.of(context).surface,
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        widget.onEdit();
                        break;
                      case 'default':
                        widget.onSetDefault();
                        break;
                      case 'duplicate':
                        widget.onDuplicate();
                        break;
                      case 'export':
                        widget.onExport();
                        break;
                      case 'delete':
                        widget.onDelete();
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(LucideIcons.pencil,
                              size: 16,
                              color:
                                  SkotiqColors.of(context).textSecondary),
                          const SizedBox(width: 8),
                          Text('Edit',
                              style: SkotiqTypography.body.copyWith(
                                color: SkotiqColors.of(context).textPrimary,
                              )),
                        ],
                      ),
                    ),
                    // Auto-connect on launch uses the DEFAULT profile, not the
                    // active one. Without this action the flag sat wherever
                    // the first-created profile put it, unreadable and
                    // unmovable from any screen.
                    if (!widget.profile.isDefault)
                      PopupMenuItem(
                        value: 'default',
                        child: Row(
                          children: [
                            Icon(LucideIcons.power,
                                size: 16,
                                color:
                                    SkotiqColors.of(context).textSecondary),
                            const SizedBox(width: 8),
                            // Flexible: the popup menu is width-bounded and
                            // this is the longest item label on the menu.
                            Flexible(
                              child: Text('Set as default',
                                  style: SkotiqTypography.body.copyWith(
                                    color: SkotiqColors.of(context)
                                        .textPrimary,
                                  )),
                            ),
                          ],
                        ),
                      ),
                    PopupMenuItem(
                      value: 'duplicate',
                      child: Row(
                        children: [
                          Icon(LucideIcons.copy,
                              size: 16,
                              color:
                                  SkotiqColors.of(context).textSecondary),
                          const SizedBox(width: 8),
                          Text('Duplicate',
                              style: SkotiqTypography.body.copyWith(
                                color: SkotiqColors.of(context).textPrimary,
                              )),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'export',
                      child: Row(
                        children: [
                          Icon(LucideIcons.upload,
                              size: 16,
                              color:
                                  SkotiqColors.of(context).textSecondary),
                          const SizedBox(width: 8),
                          Text('Export',
                              style: SkotiqTypography.body.copyWith(
                                color: SkotiqColors.of(context).textPrimary,
                              )),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(LucideIcons.trash2,
                              size: 16,
                              color: SkotiqColors.of(context).error),
                          const SizedBox(width: 8),
                          Text('Delete',
                              style: SkotiqTypography.body.copyWith(
                                color: SkotiqColors.of(context).error,
                              )),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: 32),

          // Optical Configuration
          _Section(
            title: 'Optical configuration',
            icon: LucideIcons.aperture,
            isMobile: widget.isMobile,
            children: [
              widget.isMobile
                  ? Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _FieldCard(
                                label: _ProfileDetailsState._focalLengthField,
                                value: widget.isEditing
                                    ? null
                                    : _opticDisplay(widget.profile.focalLength),
                                controller: widget.isEditing
                                    ? _focalLengthController
                                    : null,
                                suffix: 'mm',
                                hint: 'e.g., 530',
                                errorText: _fieldErrors[
                                    _ProfileDetailsState._focalLengthField],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _FieldCard(
                                label: _ProfileDetailsState._apertureField,
                                value: widget.isEditing
                                    ? null
                                    : _opticDisplay(widget.profile.aperture),
                                controller: widget.isEditing
                                    ? _apertureController
                                    : null,
                                suffix: 'mm',
                                hint: 'e.g., 106',
                                errorText: _fieldErrors[
                                    _ProfileDetailsState._apertureField],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _FieldCard(
                          label: 'Focal ratio',
                          value: widget.profile.calculatedFocalRatio != null
                              ? 'f/${widget.profile.calculatedFocalRatio!.toStringAsFixed(1)}'
                              : kReadoutUnknown,
                          readOnly: true,
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: _FieldCard(
                            label: _ProfileDetailsState._focalLengthField,
                            value: widget.isEditing
                                ? null
                                : _opticDisplay(widget.profile.focalLength),
                            controller: widget.isEditing
                                ? _focalLengthController
                                : null,
                            suffix: 'mm',
                            hint: 'e.g., 530',
                            errorText: _fieldErrors[
                                _ProfileDetailsState._focalLengthField],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _FieldCard(
                            label: _ProfileDetailsState._apertureField,
                            value: widget.isEditing
                                ? null
                                : _opticDisplay(widget.profile.aperture),
                            controller:
                                widget.isEditing ? _apertureController : null,
                            suffix: 'mm',
                            hint: 'e.g., 106',
                            errorText: _fieldErrors[
                                _ProfileDetailsState._apertureField],
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _FieldCard(
                            label: 'Focal ratio',
                            value: widget.profile.calculatedFocalRatio != null
                                ? 'f/${widget.profile.calculatedFocalRatio!.toStringAsFixed(1)}'
                                : kReadoutUnknown,
                            readOnly: true,
                          ),
                        ),
                      ],
                    ),
            ],
          ),
          const SizedBox(height: 24),

          // Camera Defaults
          _Section(
            title: 'Camera defaults',
            icon: LucideIcons.camera,
            isMobile: widget.isMobile,
            children: [
              widget.isMobile
                  ? Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _FieldCard(
                                label: 'Default gain',
                                value: widget.isEditing
                                    ? null
                                    : (widget.profile.defaultGain?.toString() ??
                                        'Not set'),
                                controller:
                                    widget.isEditing ? _gainController : null,
                                hint: 'e.g., 100',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _FieldCard(
                                label: 'Default offset',
                                value: widget.isEditing
                                    ? null
                                    : (widget.profile.defaultOffset
                                            ?.toString() ??
                                        'Not set'),
                                controller:
                                    widget.isEditing ? _offsetController : null,
                                hint: 'e.g., 10',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _FieldCard(
                          label: 'Cooling temp',
                          value: widget.isEditing
                              ? null
                              : (widget.profile.defaultCoolingTemp != null
                                  ? '${widget.profile.defaultCoolingTemp!.toStringAsFixed(0)}°C'
                                  : 'Not set'),
                          controller:
                              widget.isEditing ? _coolingController : null,
                          suffix: '°C',
                          hint: 'e.g., -10',
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: _FieldCard(
                            label: 'Default gain',
                            value: widget.isEditing
                                ? null
                                : (widget.profile.defaultGain?.toString() ??
                                    'Not set'),
                            controller:
                                widget.isEditing ? _gainController : null,
                            hint: 'e.g., 100',
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _FieldCard(
                            label: 'Default offset',
                            value: widget.isEditing
                                ? null
                                : (widget.profile.defaultOffset?.toString() ??
                                    'Not set'),
                            controller:
                                widget.isEditing ? _offsetController : null,
                            hint: 'e.g., 10',
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _FieldCard(
                            label: 'Cooling temp',
                            value: widget.isEditing
                                ? null
                                : (widget.profile.defaultCoolingTemp != null
                                    ? '${widget.profile.defaultCoolingTemp!.toStringAsFixed(0)}°C'
                                    : 'Not set'),
                            controller:
                                widget.isEditing ? _coolingController : null,
                            suffix: '°C',
                            hint: 'e.g., -10',
                          ),
                        ),
                      ],
                    ),
              const SizedBox(height: 16),
              widget.isMobile
                  ? Row(
                      children: [
                        Expanded(
                          child: _BinningSelector(
                            label: 'Binning X',
                            value: _binX,
                            enabled: widget.isEditing,
                            onChanged: (v) => _update(() => _binX = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _BinningSelector(
                            label: 'Binning Y',
                            value: _binY,
                            enabled: widget.isEditing,
                            onChanged: (v) => _update(() => _binY = v),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: _BinningSelector(
                            label: 'Binning X',
                            value: _binX,
                            enabled: widget.isEditing,
                            onChanged: (v) => _update(() => _binX = v),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: _BinningSelector(
                            label: 'Binning Y',
                            value: _binY,
                            enabled: widget.isEditing,
                            onChanged: (v) => _update(() => _binY = v),
                          ),
                        ),
                        const Expanded(flex: 2, child: SizedBox()),
                      ],
                    ),
            ],
          ),
          const SizedBox(height: 24),

          // Filter Configuration
          _Section(
            title: 'Filter configuration',
            icon: LucideIcons.layers,
            isMobile: widget.isMobile,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sync from hardware button (always visible when not editing)
                if (!widget.isEditing)
                  _isSyncingFilters
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                SkotiqColors.of(context).primary),
                          ),
                        )
                      : SkotiqIconButton(
                          icon: LucideIcons.refreshCw,
                          tooltip: 'Sync from filter wheel',
                          onPressed: _syncFiltersFromHardware,
                          size: IconButtonSize.sm,
                          color: SkotiqColors.of(context).primary,
                        ),
                if (widget.isEditing)
                  SkotiqIconButton(
                    icon: LucideIcons.plus,
                    tooltip: 'Add filter',
                    onPressed: () {
                      _update(() {
                        _filterControllers.add(TextEditingController());
                        _filterOffsetControllers
                            .add(TextEditingController(text: '0'));
                      });
                    },
                    size: IconButtonSize.sm,
                    color: SkotiqColors.of(context).primary,
                  ),
              ],
            ),
            children: [
              if (_filterControllers.isEmpty ||
                  (!widget.isEditing && widget.profile.filterNames.isEmpty))
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: SkotiqColors.of(context).well,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                  ),
                  child: Center(
                    child: Text(
                      'No filters configured',
                      style: SkotiqTypography.body.copyWith(
                        color: SkotiqColors.of(context).textMuted,
                      ),
                    ),
                  ),
                )
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (int i = 0;
                        i <
                            (widget.isEditing
                                ? _filterControllers.length
                                : widget.profile.filterNames.length);
                        i++)
                      widget.isEditing
                          ? _EditableFilterChip(
                              controller: _filterControllers[i],
                              onNameChanged: () => _update(() {}),
                              onRemove: () {
                                _update(() {
                                  _filterControllers[i].dispose();
                                  _filterControllers.removeAt(i);
                                  if (i < _filterOffsetControllers.length) {
                                    _filterOffsetControllers[i].dispose();
                                    _filterOffsetControllers.removeAt(i);
                                  }
                                });
                              },
                            )
                          : _FilterChip(
                              name: widget.profile.filterNames[i],
                            ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 24),

          // Filter Focus Offsets section
          if (_hasFilters()) ...[
            _Section(
              title: 'Filter focus offsets',
              icon: LucideIcons.gitBranch,
              isMobile: widget.isMobile,
              children: [
                Text(
                  'Focus position offset (in steps) when switching to each filter',
                  style: SkotiqTypography.caption.copyWith(
                    color: SkotiqColors.of(context).textMuted,
                  ),
                ),
                const SizedBox(height: 12),
                ..._buildFilterOffsetRows(),
              ],
            ),
            const SizedBox(height: 24),
          ],

          // Device Assignments
          _Section(
            title: 'Device assignments',
            icon: LucideIcons.cpu,
            isMobile: widget.isMobile,
            trailing: widget.isEditing
                ? SkotiqButton(
                    label: 'Copy from Connected',
                    icon: LucideIcons.copy,
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                    onPressed: _copyFromConnectedDevices,
                  )
                : null,
            children: [
              if (!_hasDeviceAssignmentsForEdit() && !widget.isEditing)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: SkotiqColors.of(context).well,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                  ),
                  child: Center(
                    child: Text(
                      'No devices assigned. Connect devices from the Equipment tab.',
                      style: SkotiqTypography.body.copyWith(
                        color: SkotiqColors.of(context).textMuted,
                      ),
                    ),
                  ),
                )
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _buildDeviceAssignment(
                        'Camera',
                        widget.isEditing ? _cameraId : widget.profile.cameraId,
                        (val) => _update(() => _cameraId = val)),
                    _buildDeviceAssignment(
                        'Mount',
                        widget.isEditing ? _mountId : widget.profile.mountId,
                        (val) => _update(() => _mountId = val)),
                    _buildDeviceAssignment(
                        'Focuser',
                        widget.isEditing
                            ? _focuserId
                            : widget.profile.focuserId,
                        (val) => _update(() => _focuserId = val)),
                    _buildDeviceAssignment(
                        'Filter wheel',
                        widget.isEditing
                            ? _filterWheelId
                            : widget.profile.filterWheelId,
                        (val) => _update(() => _filterWheelId = val)),
                    _buildDeviceAssignment(
                        'Guider',
                        widget.isEditing ? _guiderId : widget.profile.guiderId,
                        (val) => _update(() => _guiderId = val)),
                    _buildDeviceAssignment(
                        'Rotator',
                        widget.isEditing
                            ? _rotatorId
                            : widget.profile.rotatorId,
                        (val) => _update(() => _rotatorId = val)),
                    _buildDeviceAssignment(
                        'Dome',
                        widget.isEditing ? _domeId : widget.profile.domeId,
                        (val) => _update(() => _domeId = val)),
                    _buildDeviceAssignment(
                        'Weather',
                        widget.isEditing
                            ? _weatherId
                            : widget.profile.weatherId,
                        (val) => _update(() => _weatherId = val)),
                  ].whereType<Widget>().toList(),
                ),
              if (widget.isEditing)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Click "Copy from Connected" to assign currently connected devices, or use X to clear individual assignments.',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: SkotiqColors.of(context).textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );

    // Wrap with mobile back button header if needed
    if (widget.isMobile && widget.onBack != null) {
      return Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: SkotiqColors.of(context).surface,
              border: Border(
                  bottom:
                      BorderSide(color: SkotiqColors.of(context).border)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    SkotiqIconButton(
                      icon: LucideIcons.arrowLeft,
                      tooltip: 'Back to profiles',
                      onPressed: widget.onBack,
                      color: SkotiqColors.of(context).textPrimary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.profile.name,
                        style: SkotiqTypography.pageTitle.copyWith(
                          color: SkotiqColors.of(context).textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: content),
        ],
      );
    }

    return content;
  }
}
