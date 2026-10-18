part of '../connected_device_card.dart';

extension _ConnectedDeviceActionsAndTelemetry on _ConnectedDeviceCardState {
  Widget _buildActionsRow(SkotiqColors colors) {
    final settingsAction = _resolveSettingsAction();
    final actions =
        _buildDeviceActions(colors).where((w) => w is! SizedBox).toList();

    // A ROW, never a Wrap, and the buttons are NOT flexible: a wrapped action
    // row left a lone icon stranded on a second line, and flexible buttons
    // split the slack with the Spacer and ellipsised "Cool to -10.0 °C" to
    // "Cool t…". The row measures instead: buttons keep their natural width
    // and stop being inline the moment the next one would not fit, with
    // everything else behind one `more-vertical` menu.
    //
    // The width comes from [DeviceTileWidth], not a LayoutBuilder — see the
    // note there.
    final trailing = <Widget>[
      if (settingsAction != null)
        SkotiqIconButton(
          icon: LucideIcons.settings2,
          tooltip: 'Settings',
          size: IconButtonSize.sm,
          onPressed: _anyCommandInFlight ? null : settingsAction,
        ),
    ];

    // The glyph buttons are 28 px on a desktop pointer but grow to the 48 dp
    // touch floor on a phone (SkotiqIconButton), so the budget must use
    // the width they REALLY take or the row overflows by the difference.
    final glyphWidth = SkotiqTouchTarget.minExtent(
      context,
      desktopExtent: SkotiqTokens.iconButtonSizeSm,
    );
    var budget = DeviceTileWidth.of(context) -
        SkotiqTokens.spaceLg * 2 -
        glyphWidth -
        trailing.length * (glyphWidth + _deviceActionGap);

    final inline = <Widget>[];
    for (final action in actions) {
      if (inline.length >= _maxInlineActions) break;
      final needed =
          _actionWidth(action) + (inline.isEmpty ? 0 : _deviceActionGap);
      if (needed > budget) break;
      budget -= needed;
      inline.add(action);
    }
    final overflowed = actions.sublist(inline.length);

    return Row(
      children: [
        for (var i = 0; i < inline.length; i++) ...[
          if (i > 0) const SizedBox(width: _deviceActionGap),
          inline[i],
        ],
        const Spacer(),
        for (final control in trailing) ...[
          control,
          const SizedBox(width: _deviceActionGap),
        ],
        _DeviceOverflowMenu(
          extraActions: overflowed,
          isExpanded: _isExpanded,
          onToggleDetails: _toggleExpanded,
          onDisconnect: _anyCommandInFlight
              ? null
              : widget.onDisconnect ?? () => _handleDisconnect(),
        ),
      ],
    );
  }

  /// Width [action] needs at its natural size. Measured from the real label,
  /// not guessed: a device action's label carries live values ("Cool to
  /// -10.0 °C") whose width changes with the reading.
  double _actionWidth(Widget action) {
    if (action is _FilterDropdown) return _FilterDropdown.width;
    if (action is! _ActionButton) return _unmeasurableActionWidth;
    final painter = TextPainter(
      text: TextSpan(
        text: action.label,
        style: SkotiqTypography.buttonSm,
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + _actionButtonPadding;
  }

  /// Returns the settings action for the current device type, or `null` if
  /// this device type has no real settings to expose from the card.
  ///
  /// Wiring matrix:
  ///
  /// | Device          | Gear visible? | Action                                    |
  /// |-----------------|---------------|-------------------------------------------|
  /// | camera          | yes           | local cooling-target dialog               |
  /// | filterWheel     | yes (if      | injected `widget.onSettings`              |
  /// |                 | injected)     | (parent opens ProfileEditorDialog where   |
  /// |                 |               | per-filter offsets are edited)            |
  /// | mount           | no            | no slew-rate / park-position widget yet   |
  /// | focuser         | no            | no step-size / max-position widget yet    |
  /// | rotator         | no            | no sky-PA preset widget yet               |
  /// | dome            | no            | no park/home/follow-mount widget yet      |
  /// | coverCalibrator | yes, if light | local brightness dialog                    |
  /// | guider          | no            | no per-card settings (config in Imaging)  |
  /// | weather         | no            | read-only telemetry                       |
  /// | safetyMonitor   | no            | read-only                                 |
  ///
  /// No stubs or placeholders: unwired gears stay hidden
  /// — we never display a settings affordance that does nothing or that opens
  /// an empty dialog. When a real device-specific settings widget for one of
  /// the unwired entries is added under
  /// `packages/skotiq_app/lib/screens/equipment/widgets/`, route to it
  /// from this switch.
  ///
  /// An externally-injected `widget.onSettings` always wins, allowing the
  /// equipment screen (which knows the active profile) to wire filter-wheel
  /// offsets editing without making the card itself profile-aware.
  VoidCallback? _resolveSettingsAction() {
    final injected = widget.onSettings;
    if (injected != null) {
      return injected;
    }
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        return () {
          final targetTemp = ref.read(cameraStateProvider).targetTemp;
          _showCoolingTempDialog(targetTemp);
        };
      case ConnectedDeviceType.mount:
        return _showMountSettingsDialog;
      case ConnectedDeviceType.focuser:
        return _showFocuserSettingsDialog;
      case ConnectedDeviceType.rotator:
        return _showRotatorSettingsDialog;
      case ConnectedDeviceType.dome:
        return _showDomeSettingsDialog;
      case ConnectedDeviceType.coverCalibrator:
        final state = ref.watch(coverCalibratorStateProvider);
        final capabilities = ref.watch(
          equipmentCoverCalibratorCapabilitiesProvider(state.deviceId ?? ''),
        );
        return gateCapability(
          capabilities,
          (caps) => caps.calibratorPresent,
        )
            ? _showCoverCalibratorSettingsDialog
            : null;
      case ConnectedDeviceType.filterWheel:
      // Read-only / no per-card settings.
      case ConnectedDeviceType.guider:
      case ConnectedDeviceType.weather:
      case ConnectedDeviceType.safetyMonitor:
        return null;
    }
  }

  List<Widget> _buildDeviceActions(SkotiqColors colors) {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        final state = ref.watch(cameraStateProvider);
        return [
          _ActionButton(
            label: 'Cool to ${formatCelsius(state.targetTemp, decimals: 0)}',
            onTap: _deviceCommandInFlight
                ? null
                : () => _handleCoolCamera(state.targetTemp),
            onLongPress: _deviceCommandInFlight
                ? null
                : () => _showCoolingTempDialog(state.targetTemp),
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: state.isWarming ? 'Cancel warm-up' : 'Warm up',
            onTap: _deviceCommandInFlight
                ? null
                : state.isWarming
                    ? _handleCancelWarm
                    : _handleWarmCamera,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.mount:
        final state = ref.watch(mountStateProvider);
        final capabilities = ref.watch(
          equipmentMountCapabilitiesProvider(state.deviceId ?? ''),
        );
        final connected =
            state.connectionState == DeviceConnectionState.connected &&
                state.deviceId != null &&
                state.deviceId!.isNotEmpty;
        final canPark = gateCapability<MountCapabilities>(
          capabilities,
          (caps) => state.isParked ? caps.canUnpark : caps.canPark,
        );
        final canSetTracking = gateCapability<MountCapabilities>(
          capabilities,
          (caps) => caps.canSetTracking,
        );
        final canFindHome = gateCapability<MountCapabilities>(
          capabilities,
          (caps) => caps.canFindHome,
        );
        final canFlip = gateCapability<MountCapabilities>(
          capabilities,
          (caps) =>
              caps.isEquatorial &&
              caps.canGetSideOfPier &&
              (caps.canSlew || caps.canSlewAsync),
        );
        final flipInProgress = ref.watch(isFlipInProgressProvider);
        final sequenceSettled =
            ref.watch(sequenceExecutionStateProvider).canStart;
        final homeBlockedReason = MountCommandService.homeUnavailableReason(
          mountState: state,
          isConnected: connected,
          canFindHome: canFindHome,
        );
        // Home sits next to Park: both put the mount somewhere known, and
        // keeping them together keeps the difference in view — Home leaves
        // the mount unparked and commandable.
        return [
          _ActionButton(
            label: state.isParked ? 'Unpark' : 'Park',
            onTap: connected &&
                    canPark &&
                    !state.isSlewing &&
                    !state.isHoming &&
                    !flipInProgress &&
                    !_mountCommandInFlight
                ? _handleTogglePark
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Home',
            tooltip: homeBlockedReason ??
                'Send the mount to its home position. It stays unparked.',
            onTap: homeBlockedReason == null &&
                    !flipInProgress &&
                    !_mountCommandInFlight
                ? _handleFindHome
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: state.isTracking ? 'Stop Tracking' : 'Track',
            onTap: connected &&
                    canSetTracking &&
                    !state.isSlewing &&
                    !state.isHoming &&
                    !flipInProgress &&
                    !_mountCommandInFlight
                ? () => _handleToggleTracking(state.isTracking)
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Flip',
            onTap: connected &&
                    canFlip &&
                    state.isTracking &&
                    !state.isParked &&
                    !state.isSlewing &&
                    state.ra != null &&
                    state.dec != null &&
                    sequenceSettled &&
                    !flipInProgress &&
                    !_mountCommandInFlight
                ? _handleManualMeridianFlip
                : null,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.focuser:
        final state = ref.watch(focuserStateProvider);
        final autofocusRunning = ref.watch(
          sessionStateProvider.select((session) => session.isAutofocusing),
        );
        return [
          _ActionButton(
            label: 'Move to…',
            onTap: state.isAbsolute && !state.isMoving && !autofocusRunning
                ? () => _showMoveDialog(context)
                : null,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.filterWheel:
        final state = ref.watch(filterWheelStateProvider);
        final autofocusRunning = ref.watch(
          sessionStateProvider.select((session) => session.isAutofocusing),
        );
        return [
          _FilterDropdown(
            filterNames: state.filterNames,
            currentPosition: state.currentPosition,
            onFilterSelected: _handleFilterChange,
            enabled: state.connectionState == DeviceConnectionState.connected &&
                !state.isMoving &&
                !autofocusRunning &&
                !_deviceCommandInFlight,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.guider:
        final state = ref.watch(guiderStateProvider);
        return [
          _ActionButton(
            label: state.isGuiding ? 'Stop' : 'Start guiding',
            onTap: state.connectionState == DeviceConnectionState.connected &&
                    state.deviceId != null &&
                    state.deviceId!.isNotEmpty &&
                    !state.isCalibrating &&
                    !_deviceCommandInFlight
                ? () => _handleToggleGuiding(state.isGuiding)
                : null,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.rotator:
        // Keep the rotator's capability future warm so the "Rotate To Angle"
        // dialog observes the resolved min/maxAngleDeg window (it reads them
        // synchronously on open). capabilityRefreshOnConnectProvider only
        // invalidates on the connect edge; without an active watcher the
        // FutureProvider would be cold and the dialog would fall back to a
        // full 0..360 turn even on a bounded rotator.
        final state = ref.watch(rotatorStateProvider);
        final capabilities = ref.watch(
          equipmentRotatorCapabilitiesProvider(state.deviceId ?? ''),
        );
        final canMoveAbsolute = gateCapability<RotatorCapabilities>(
          capabilities,
          (caps) => caps.canMoveAbsolute,
        );
        return [
          _ActionButton(
            label: 'Rotate to…',
            onTap: state.connectionState == DeviceConnectionState.connected &&
                    !state.isMoving &&
                    canMoveAbsolute
                ? () => _showRotateDialog(context)
                : null,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.dome:
        final state = ref.watch(domeStateProvider);
        final capabilities = ref.watch(
          equipmentDomeCapabilitiesProvider(state.deviceId ?? ''),
        );
        final connected =
            state.connectionState == DeviceConnectionState.connected &&
                state.deviceId != null &&
                state.deviceId!.isNotEmpty;
        final canSetShutter = gateCapability<DomeCapabilities>(
          capabilities,
          (caps) => caps.canSetShutter,
        );
        final canPark = gateCapability<DomeCapabilities>(
          capabilities,
          (caps) => caps.canPark,
        );
        final canSetAzimuth = gateCapability<DomeCapabilities>(
          capabilities,
          (caps) => caps.canSetAzimuth,
        );
        final canFindHome = gateCapability<DomeCapabilities>(
          capabilities,
          (caps) => caps.canFindHome,
        );
        final canAbort = gateCapability<DomeCapabilities>(
          capabilities,
          (caps) => caps.canAbort,
        );
        final shutterMoving = state.shutterStatus == ShutterStatus.opening ||
            state.shutterStatus == ShutterStatus.closing;
        return [
          _ActionButton(
            label: state.shutterStatus == ShutterStatus.open
                ? 'Close shutter'
                : 'Open shutter',
            onTap: connected &&
                    canSetShutter &&
                    !shutterMoving &&
                    !_domeCommandInFlight
                ? () => _handleDomeShutter(state.shutterStatus)
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: state.isParked ? 'Parked' : 'Park',
            onTap: connected &&
                    canPark &&
                    !state.isParked &&
                    !state.isSlewing &&
                    !_domeCommandInFlight
                ? _handleDomePark
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Slew…',
            onTap: connected &&
                    canSetAzimuth &&
                    !state.isSlewing &&
                    !_domeCommandInFlight
                ? () => _showDomeSlewDialog(context)
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Home',
            onTap: connected &&
                    canFindHome &&
                    !state.isSlewing &&
                    !_domeCommandInFlight
                ? _handleDomeHome
                : null,
            colors: colors,
          ),
          const SizedBox(width: 8),
          _ActionButton(
            label: 'Halt',
            onTap: connected &&
                    canAbort &&
                    state.isSlewing &&
                    !_domeCommandInFlight
                ? _handleDomeHalt
                : null,
            colors: colors,
          ),
        ];

      case ConnectedDeviceType.weather:
        return [];

      case ConnectedDeviceType.safetyMonitor:
        final state = ref.watch(safetyMonitorStateProvider);
        final safetyStatus = ref.watch(equipmentSafetySnoozeStatusProvider);
        return [
          if (!state.isSafe)
            _ActionButton(
              label: safetyStatus == WeatherSafetyStatus.snoozed
                  ? 'Cancel Snooze'
                  : 'Snooze 15m',
              onTap: state.connectionState != DeviceConnectionState.connected
                  ? null
                  : safetyStatus == WeatherSafetyStatus.snoozed
                      ? _handleSafetyCancelSnooze
                      : _handleSafetySnooze,
              colors: colors,
            ),
        ];

      case ConnectedDeviceType.coverCalibrator:
        final state = ref.watch(coverCalibratorStateProvider);
        final capabilities = ref.watch(
          equipmentCoverCalibratorCapabilitiesProvider(state.deviceId ?? ''),
        );
        final snapshot = capabilities.valueOrNull;
        if (snapshot == null) return [];
        final connected =
            state.connectionState == DeviceConnectionState.connected;
        final coverStatus = snapshot.coverStatus;
        final coverCanMove = coverStatus == CoverStatus.open ||
            coverStatus == CoverStatus.closed;
        final calibratorStatus = snapshot.calibratorStatus;
        final calibratorCanToggle = calibratorStatus == CalibratorStatus.off ||
            calibratorStatus == CalibratorStatus.ready ||
            calibratorStatus == CalibratorStatus.notReady;
        final calibratorOn = calibratorStatus == CalibratorStatus.ready ||
            calibratorStatus == CalibratorStatus.notReady;
        return [
          if (snapshot.coverPresent)
            _ActionButton(
              label: switch (coverStatus) {
                CoverStatus.open => 'Close cover',
                CoverStatus.closed => 'Open cover',
                CoverStatus.moving => 'Cover Moving',
                _ => 'Cover unavailable',
              },
              onTap: connected &&
                      coverCanMove &&
                      !_coverCalibratorCommandInFlight
                  ? () => _handleCoverToggle(coverStatus == CoverStatus.open)
                  : null,
              colors: colors,
            ),
          if (snapshot.coverPresent && snapshot.calibratorPresent)
            const SizedBox(width: 8),
          if (snapshot.calibratorPresent)
            _ActionButton(
              label: calibratorOn ? 'Light off' : 'Light on',
              onTap: connected &&
                      calibratorCanToggle &&
                      (calibratorOn || snapshot.maxBrightness > 0) &&
                      !_coverCalibratorCommandInFlight
                  ? () => _handleCalibratorToggle(
                        isOn: calibratorOn,
                        brightness: snapshot.brightness,
                        maxBrightness: snapshot.maxBrightness,
                      )
                  : null,
              colors: colors,
            ),
        ];
    }
  }

  Widget _buildExpandedContent(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Container(
        padding: SkotiqTokens.paddingMd,
        decoration: SkotiqDecorations.well(colors),
        child: KeyValueList(rows: _buildExpandedTelemetry(colors)),
      ),
    );
  }

  List<(String, String)> _buildExpandedTelemetry(SkotiqColors colors) {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        final state = ref.watch(cameraStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          ('Gain', state.gain?.toString() ?? kReadoutUnknown),
          ('Offset', state.offset?.toString() ?? kReadoutUnknown),
          ('Binning', state.binning ?? kReadoutUnknown),
          ('Cooling', state.isCooling ? 'Active' : 'Off'),
          ('Target temp', formatCelsius(state.targetTemp)),
        ];

      case ConnectedDeviceType.mount:
        final state = ref.watch(mountStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          ('RA', state.ra?.toStringAsFixed(4) ?? kReadoutUnknown),
          ('Dec', state.dec?.toStringAsFixed(4) ?? kReadoutUnknown),
          (
            'Altitude',
            state.altitude != null
                ? state.altitude!.toStringAsFixed(2)
                : kReadoutUnknown
          ),
          (
            'Azimuth',
            state.azimuth != null
                ? state.azimuth!.toStringAsFixed(2)
                : kReadoutUnknown
          ),
          ('Side of pier', state.sideOfPier ?? 'Unknown'),
          ('Tracking rate', state.trackingRate.name.toUpperCase()),
        ];

      case ConnectedDeviceType.focuser:
        final state = ref.watch(focuserStateProvider);
        final reportedMax = state.maxPosition;
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'Max position',
            reportedMax != null && reportedMax > 0
                ? reportedMax.toString()
                : kReadoutUnknown
          ),
        ];

      case ConnectedDeviceType.filterWheel:
        final state = ref.watch(filterWheelStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          ('Filters', state.filterNames.join(', ')),
        ];

      case ConnectedDeviceType.guider:
        final state = ref.watch(guiderStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'RA RMS',
            state.rmsRa != null
                ? '${state.rmsRa!.toStringAsFixed(3)}"'
                : kReadoutUnknown
          ),
          (
            'Dec RMS',
            state.rmsDec != null
                ? '${state.rmsDec!.toStringAsFixed(3)}"'
                : kReadoutUnknown
          ),
          ('Calibrating', state.isCalibrating ? 'Yes' : 'No'),
        ];

      case ConnectedDeviceType.rotator:
        final state = ref.watch(rotatorStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'Mechanical Position',
            state.mechanicalPosition != null
                ? state.mechanicalPosition!.toStringAsFixed(2)
                : kReadoutUnknown
          ),
          ('Reversed', state.isReversed ? 'Yes' : 'No'),
        ];

      case ConnectedDeviceType.dome:
        final state = ref.watch(domeStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'Azimuth',
            state.azimuth != null
                ? '${state.azimuth!.toStringAsFixed(2)}\u00B0'
                : kReadoutUnknown
          ),
          ('Shutter', _shutterStatusLabel(state.shutterStatus)),
          ('Parked', state.isParked ? 'Yes' : 'No'),
          ('At Home', state.isAtHome ? 'Yes' : 'No'),
          ('Slaved', state.isSlaved ? 'Yes' : 'No'),
        ];

      case ConnectedDeviceType.weather:
        final state = ref.watch(weatherStateProvider);
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'Temperature',
            state.temperature != null
                ? '${state.temperature!.toStringAsFixed(1)}\u00B0C'
                : kReadoutUnknown
          ),
          (
            'Humidity',
            state.humidity != null
                ? '${state.humidity!.toStringAsFixed(1)}%'
                : kReadoutUnknown
          ),
          (
            'Dew Point',
            state.dewPoint != null
                ? '${state.dewPoint!.toStringAsFixed(1)}\u00B0C'
                : kReadoutUnknown
          ),
          (
            'Pressure',
            state.pressure != null
                ? '${state.pressure!.toStringAsFixed(1)} hPa'
                : kReadoutUnknown
          ),
          (
            'Wind Speed',
            state.windSpeed != null
                ? '${state.windSpeed!.toStringAsFixed(1)} km/h'
                : kReadoutUnknown
          ),
          (
            'Wind Direction',
            state.windDirection != null
                ? '${state.windDirection!.toStringAsFixed(0)}\u00B0'
                : kReadoutUnknown
          ),
          (
            'Cloud Cover',
            state.cloudCover != null
                ? '${state.cloudCover!.toStringAsFixed(0)}%'
                : kReadoutUnknown
          ),
          (
            'Sky Quality',
            state.skyQuality != null
                ? '${state.skyQuality!.toStringAsFixed(2)} mag/arcsec\u00B2'
                : kReadoutUnknown
          ),
          (
            'Sky Temp',
            state.skyTemperature != null
                ? '${state.skyTemperature!.toStringAsFixed(1)}\u00B0C'
                : kReadoutUnknown
          ),
          (
            'Rain Rate',
            state.rainRate != null
                ? '${state.rainRate!.toStringAsFixed(1)} mm/h'
                : kReadoutUnknown
          ),
          if (state.lastUpdated != null)
            (
              'Last Updated',
              '${_formatAge(_tickNow().difference(state.lastUpdated!))} '
                  'ago'
            ),
        ];

      case ConnectedDeviceType.safetyMonitor:
        final state = ref.watch(safetyMonitorStateProvider);
        final lastChecked = state.lastChecked;
        final age =
            lastChecked == null ? null : _tickNow().difference(lastChecked);
        final isStale = age != null && age > _safetyStatusStaleAfter;
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          (
            'Is Safe',
            lastChecked == null
                ? 'Unknown — not read yet'
                : isStale
                    ? 'Unknown — reading is stale'
                    : state.isSafe
                        ? 'Yes'
                        : 'No'
          ),
          if (age != null) ('Last Checked', '${_formatAge(age)} ago'),
        ];

      case ConnectedDeviceType.coverCalibrator:
        final state = ref.watch(coverCalibratorStateProvider);
        final capabilities = ref.watch(
          equipmentCoverCalibratorCapabilitiesProvider(state.deviceId ?? ''),
        );
        final snapshot = capabilities.valueOrNull;
        if (snapshot == null) {
          return [
            ('Device id', state.deviceId ?? 'Unknown'),
            (
              'Capabilities',
              capabilities.hasError ? 'Unavailable' : 'Loading...'
            ),
          ];
        }
        return [
          ('Device id', state.deviceId ?? 'Unknown'),
          if (snapshot.coverPresent)
            (
              'Cover Status',
              _coverStatusLabel(
                snapshot.coverStatus ?? CoverStatus.unknown,
              )
            ),
          if (snapshot.calibratorPresent) ...[
            ('Calibrator', _calibratorStatusLabel(snapshot.calibratorStatus)),
            (
              'Brightness',
              '${snapshot.brightness ?? 0} / '
                  '${snapshot.maxBrightness}'
            ),
          ],
          if (!snapshot.coverPresent && !snapshot.calibratorPresent)
            ('Capabilities', 'No cover or calibrator reported'),
        ];
    }
  }
}

/// Gap between a device panel's action controls (mockup: 6).
const double _deviceActionGap = 6.0;

/// How many device actions stay inline before the rest go behind the menu.
const int _maxInlineActions = 2;

/// A small button's horizontal padding plus its border, added to the measured
/// label width (05 §6: small = 28 high, 10 padding a side).
const double _actionButtonPadding = 22.0;

/// Width assumed for an action this row cannot measure, so an unmeasurable
/// control is never assumed free.
const double _unmeasurableActionWidth = 120.0;

/// The `⋮` at the end of a device panel's action row: the actions that did not
/// fit inline, the details toggle, and Disconnect.
class _DeviceOverflowMenu extends StatefulWidget {
  /// Device actions pushed out of the inline row. Only `_ActionButton`s carry
  /// a label, so anything else is skipped rather than shown as a blank item.
  final List<Widget> extraActions;
  final bool isExpanded;
  final VoidCallback onToggleDetails;
  final VoidCallback? onDisconnect;

  const _DeviceOverflowMenu({
    required this.extraActions,
    required this.isExpanded,
    required this.onToggleDetails,
    required this.onDisconnect,
  });

  @override
  State<_DeviceOverflowMenu> createState() => _DeviceOverflowMenuState();
}

class _DeviceOverflowMenuState extends State<_DeviceOverflowMenu> {
  final GlobalKey _anchorKey = GlobalKey();

  Future<void> _open() async {
    final anchor = _anchorKey.currentContext;
    if (anchor == null) return;
    final extras = <_ActionButton>[
      for (final action in widget.extraActions)
        if (action is _ActionButton) action,
    ];

    final chosen = await showMenu<VoidCallback>(
      context: context,
      position: menuPositionBelowWidget(anchor),
      items: <PopupMenuEntry<VoidCallback>>[
        for (final action in extras)
          PopupMenuItem<VoidCallback>(
            value: action.onTap,
            enabled: action.onTap != null,
            child: Text(action.label),
          ),
        if (extras.isNotEmpty) const PopupMenuDivider(),
        PopupMenuItem<VoidCallback>(
          value: widget.onToggleDetails,
          child: Text(widget.isExpanded ? 'Hide details' : 'Show details'),
        ),
        PopupMenuItem<VoidCallback>(
          value: widget.onDisconnect,
          enabled: widget.onDisconnect != null,
          child: const Text('Disconnect'),
        ),
      ],
    );
    if (!mounted || chosen == null) return;
    chosen();
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqIconButton(
      key: _anchorKey,
      icon: LucideIcons.moreVertical,
      tooltip: 'More actions',
      size: IconButtonSize.sm,
      onPressed: _open,
    );
  }
}
