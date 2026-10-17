part of '../equipment_profiles_screen.dart';

extension _ProfileDetailsHelpers on _ProfileDetailsState {
  bool _hasDeviceAssignments() {
    return widget.profile.cameraId != null ||
        widget.profile.mountId != null ||
        widget.profile.focuserId != null ||
        widget.profile.filterWheelId != null ||
        widget.profile.guiderId != null ||
        widget.profile.rotatorId != null ||
        widget.profile.domeId != null ||
        widget.profile.weatherId != null;
  }

  bool _hasDeviceAssignmentsForEdit() {
    if (widget.isEditing) {
      return _cameraId != null ||
          _mountId != null ||
          _focuserId != null ||
          _filterWheelId != null ||
          _guiderId != null ||
          _rotatorId != null ||
          _domeId != null ||
          _weatherId != null;
    }
    return _hasDeviceAssignments();
  }

  Widget? _buildDeviceAssignment(
      String type, String? deviceId, void Function(String?) onClear) {
    if (deviceId == null) return null;

    final displayId = formatDeviceId(deviceId);

    if (widget.isEditing) {
      return _EditableDeviceChip(
        type: type,
        id: displayId,
        fullId: deviceId,
        onClear: () => onClear(null),
      );
    }

    return _DeviceChip(type: type, id: displayId);
  }

  bool _hasFilters() {
    if (widget.isEditing) {
      return _filterControllers.any((c) => c.text.trim().isNotEmpty);
    }
    return widget.profile.filterNames.isNotEmpty;
  }

  List<Widget> _buildFilterOffsetRows() {
    final filterNameWidth = widget.isMobile ? 100.0 : 120.0;
    final inputWidth = widget.isMobile ? 90.0 : 100.0;

    Widget buildRow(
        String filterName, TextEditingController? controller, int offset) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              flex: widget.isMobile ? 2 : 1,
              child: Container(
                constraints: BoxConstraints(minWidth: filterNameWidth),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.isMobile ? 10 : 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: SkotiqColors.of(context).well,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Text(
                  filterName,
                  style: SkotiqTypography.body.copyWith(
                    color: SkotiqColors.of(context).textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            SizedBox(width: widget.isMobile ? 10 : 12),
            if (widget.isEditing)
              SizedBox(
                width: inputWidth,
                child: TextFormField(
                  controller: controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(signed: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^-?\d*')),
                  ],
                  style: SkotiqTypography.body.copyWith(
                    color: SkotiqColors.of(context).textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: widget.isMobile ? 6 : 8,
                      vertical: 8,
                    ),
                    suffixText: widget.isMobile ? 'st' : 'steps',
                    suffixStyle: SkotiqTypography.caption.copyWith(
                      color: SkotiqColors.of(context).textMuted,
                    ),
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(
                          color: SkotiqColors.of(context).border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(
                          color: SkotiqColors.of(context).border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusMd),
                      borderSide: BorderSide(
                          color: SkotiqColors.of(context).primary,
                          width: 2),
                    ),
                  ),
                ),
              )
            else
              Text(
                '$offset steps',
                style: SkotiqTypography.body.copyWith(
                  color: SkotiqColors.of(context).textSecondary,
                ),
              ),
          ],
        ),
      );
    }

    final rows = <Widget>[];
    if (widget.isEditing) {
      for (var i = 0; i < _filterControllers.length; i++) {
        final filterName = _filterControllers[i].text.trim();
        if (filterName.isEmpty) continue;
        while (_filterOffsetControllers.length <= i) {
          _filterOffsetControllers.add(TextEditingController(text: '0'));
        }
        rows.add(buildRow(filterName, _filterOffsetControllers[i], 0));
      }
    } else {
      for (final filterName in widget.profile.filterNames) {
        rows.add(buildRow(filterName, null,
            widget.profile.filterFocusOffsets[filterName] ?? 0));
      }
    }
    return rows;
  }
}
