part of '../connected_device_card.dart';

extension _ConnectedDeviceStatusAndDisplay on _ConnectedDeviceCardState {
  DeviceConnectionState _getConnectionState() {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        return ref.watch(cameraStateProvider).connectionState;
      case ConnectedDeviceType.mount:
        return ref.watch(mountStateProvider).connectionState;
      case ConnectedDeviceType.focuser:
        return ref.watch(focuserStateProvider).connectionState;
      case ConnectedDeviceType.filterWheel:
        return ref.watch(filterWheelStateProvider).connectionState;
      case ConnectedDeviceType.guider:
        return ref.watch(guiderStateProvider).connectionState;
      case ConnectedDeviceType.rotator:
        return ref.watch(rotatorStateProvider).connectionState;
      case ConnectedDeviceType.dome:
        return ref.watch(domeStateProvider).connectionState;
      case ConnectedDeviceType.weather:
        return ref.watch(weatherStateProvider).connectionState;
      case ConnectedDeviceType.safetyMonitor:
        return ref.watch(safetyMonitorStateProvider).connectionState;
      case ConnectedDeviceType.coverCalibrator:
        return ref.watch(coverCalibratorStateProvider).connectionState;
    }
  }

  Widget _buildHeader(
      SkotiqColors colors, Color accentColor, DeviceConnectionState state) {
    final deviceName = _getDeviceName();

    return Row(
      children: [
        // 32 px icon square in a well — tone, not a tinted accent chip.
        Container(
          width: _deviceIconSquare,
          height: _deviceIconSquare,
          decoration: SkotiqDecorations.well(colors),
          child: Icon(
            widget.type.icon,
            size: _deviceIconSize,
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm + 2),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.type.displayName.toUpperCase(),
                style: SkotiqTypography.eyebrow.copyWith(
                  color: colors.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // A name a couple of characters over the column width must
              // shrink to fit before any of it is dropped: at 1600x900 the
              // FILTER WHEEL card ellipsised to "Simulated Filter ..." beside
              // camera, mount and focuser cards of the same width showing
              // their full names, so one card looked like it held a different,
              // mangled device. The ellipsis (and a tooltip) stays for a name
              // that is genuinely too long.
              Tooltip(
                message: deviceName,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    deviceName,
                    maxLines: 1,
                    style: SkotiqTypography.bodyStrong.copyWith(
                      color: colors.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        _buildConnectionBadge(state, colors),
      ],
    );
  }

  /// Full-width notice for a device that is connected but is NOT the device the
  /// active profile assigns to this slot.
  ///
  /// Returns [SizedBox.shrink] otherwise, so a profile device keeps its compact
  /// card.
  Widget _buildSessionOnlyNotice(
    SkotiqColors colors,
    DeviceConnectionState state,
  ) {
    if (state != DeviceConnectionState.connected || !widget.sessionOnly) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      child: _SessionOnlyNotice(
        colors: colors,
        onAddToProfile: _addToProfile,
      ),
    );
  }

  /// When the device is in an error state, render a full-width
  /// row beneath the header that surfaces the same plain-language headline the
  /// troubleshooter dialog uses (via [DeviceErrorSubtitle]), with the raw driver
  /// message carried verbatim in the tooltip and a Diagnose button that opens
  /// the full [ConnectionTroubleshooterDialog]. Returns
  /// [SizedBox.shrink] when the device is healthy so the card keeps its compact
  /// layout. Placed as its own full-width row (not inside the header's narrow
  /// name column) so the headline and the Diagnose affordance have room to sit
  /// side by side without crowding the connection badge.
  Widget _buildErrorSubtitle(SkotiqColors colors, DeviceConnectionState state) {
    if (state != DeviceConnectionState.error) {
      return const SizedBox.shrink();
    }
    final errorMessage = _getDeviceError()?.message;
    if (errorMessage == null || errorMessage.isEmpty) {
      return const SizedBox.shrink();
    }
    final deviceId = _getDeviceId();
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
      child: DeviceErrorSubtitle(
        descriptiveSubtitle: '',
        isError: true,
        errorMessage: errorMessage,
        deviceType: widget.type.coreDeviceType,
        driverType: driverTypeFromDeviceId(deviceId) ?? DriverType.native,
        colors: colors,
        onDiagnose: () => _openTroubleshooter(
          deviceId: deviceId,
          rawError: errorMessage,
        ),
      ),
    );
  }

  /// Opens the guided [ConnectionTroubleshooterDialog] for this device,
  /// classifying the failure with the same knowledge base that powers the
  /// inline [DeviceErrorSubtitle] headline. The raw driver string is carried
  /// through verbatim (errors-are-a-feature). If the user chooses "Retry
  /// connection", the device's connect is re-attempted exactly once through the
  /// device service.
  Future<void> _openTroubleshooter({
    required String? deviceId,
    required String rawError,
  }) async {
    final retry = await ConnectionTroubleshooterDialog.show(
      context,
      deviceType: widget.type.coreDeviceType,
      driverType: driverTypeFromDeviceId(deviceId) ?? DriverType.native,
      rawError: rawError,
    );
    if (!retry || !mounted || deviceId == null) return;
    // Single, bounded retry — no loop. A second failure simply updates the
    // device state's lastError, which re-renders this subtitle and lets the
    // user open the troubleshooter again deliberately.
    final deviceService = ref.read(deviceServiceProvider);
    try {
      await _reconnect(deviceService, deviceId);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Failed to reconnect: $e');
      }
    }
  }

  /// Re-attempts the connection for this card's device type via the device
  /// service. Mirrors the connect dispatch used by the discovery panel.
  Future<void> _reconnect(DeviceService deviceService, String deviceId) {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        return deviceService.connectCamera(deviceId);
      case ConnectedDeviceType.mount:
        return deviceService.connectMount(deviceId);
      case ConnectedDeviceType.focuser:
        return deviceService.connectFocuser(deviceId);
      case ConnectedDeviceType.filterWheel:
        return deviceService.connectFilterWheel(deviceId);
      case ConnectedDeviceType.guider:
        return deviceService.connectGuider(deviceId);
      case ConnectedDeviceType.rotator:
        return deviceService.connectRotator(deviceId);
      case ConnectedDeviceType.dome:
        return deviceService.connectDome(deviceId);
      case ConnectedDeviceType.weather:
        return deviceService.connectWeather(deviceId);
      case ConnectedDeviceType.safetyMonitor:
        return deviceService.connectSafetyMonitor(deviceId);
      case ConnectedDeviceType.coverCalibrator:
        return deviceService.connectCoverCalibrator(deviceId);
    }
  }

  /// The device's last error (if any) for the current device type.
  DeviceError? _getDeviceError() {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        return ref.watch(cameraStateProvider).lastError;
      case ConnectedDeviceType.mount:
        return ref.watch(mountStateProvider).lastError;
      case ConnectedDeviceType.focuser:
        return ref.watch(focuserStateProvider).lastError;
      case ConnectedDeviceType.filterWheel:
        return ref.watch(filterWheelStateProvider).lastError;
      case ConnectedDeviceType.guider:
        return ref.watch(guiderStateProvider).lastError;
      case ConnectedDeviceType.rotator:
        return ref.watch(rotatorStateProvider).lastError;
      case ConnectedDeviceType.dome:
        return ref.watch(domeStateProvider).lastError;
      case ConnectedDeviceType.weather:
        return ref.watch(weatherStateProvider).lastError;
      case ConnectedDeviceType.safetyMonitor:
        return ref.watch(safetyMonitorStateProvider).lastError;
      case ConnectedDeviceType.coverCalibrator:
        return ref.watch(coverCalibratorStateProvider).lastError;
    }
  }

  /// The device's namespaced device id for the current device type. Used to
  /// resolve the [DriverType] for the troubleshooter and to drive the bounded
  /// reconnect retry.
  String? _getDeviceId() {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        return ref.watch(cameraStateProvider).deviceId;
      case ConnectedDeviceType.mount:
        return ref.watch(mountStateProvider).deviceId;
      case ConnectedDeviceType.focuser:
        return ref.watch(focuserStateProvider).deviceId;
      case ConnectedDeviceType.filterWheel:
        return ref.watch(filterWheelStateProvider).deviceId;
      case ConnectedDeviceType.guider:
        return ref.watch(guiderStateProvider).deviceId;
      case ConnectedDeviceType.rotator:
        return ref.watch(rotatorStateProvider).deviceId;
      case ConnectedDeviceType.dome:
        return ref.watch(domeStateProvider).deviceId;
      case ConnectedDeviceType.weather:
        return ref.watch(weatherStateProvider).deviceId;
      case ConnectedDeviceType.safetyMonitor:
        return ref.watch(safetyMonitorStateProvider).deviceId;
      case ConnectedDeviceType.coverCalibrator:
        return ref.watch(coverCalibratorStateProvider).deviceId;
    }
  }

  /// Resolve the device's display name, preferring the live discovery model
  /// name (e.g. "ZWO ASI1600MM-Cool"). Watching discovery here means the card
  /// updates reactively once a slow native SDK enumeration populates the
  /// discovery cache — even when the device connected (and its state name was
  /// set to the raw id) before that enumeration finished. Falls back to the
  /// connected state name, then the formatted id via [_getDeviceDisplayName].
  String _resolveDisplayName(
      String? stateName, String? deviceId, String fallback) {
    if (deviceId != null && deviceId.isNotEmpty) {
      final discovered = ref.watch(unifiedDiscoveryProvider).rawDevices;
      for (final device in discovered) {
        if (device.id == deviceId &&
            device.name.isNotEmpty &&
            device.name != deviceId) {
          return device.name;
        }
      }
    }
    return _getDeviceDisplayName(stateName, deviceId, fallback);
  }

  String _getDeviceName() {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        final state = ref.watch(cameraStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Camera');
      case ConnectedDeviceType.mount:
        final state = ref.watch(mountStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Mount');
      case ConnectedDeviceType.focuser:
        final state = ref.watch(focuserStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Focuser');
      case ConnectedDeviceType.filterWheel:
        final state = ref.watch(filterWheelStateProvider);
        return _resolveDisplayName(
            state.deviceName, state.deviceId, 'Filter wheel');
      case ConnectedDeviceType.guider:
        final state = ref.watch(guiderStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Guider');
      case ConnectedDeviceType.rotator:
        final state = ref.watch(rotatorStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Rotator');
      case ConnectedDeviceType.dome:
        final state = ref.watch(domeStateProvider);
        return _resolveDisplayName(state.deviceName, state.deviceId, 'Dome');
      case ConnectedDeviceType.weather:
        final state = ref.watch(weatherStateProvider);
        return _resolveDisplayName(
            state.deviceName, state.deviceId, 'Weather Station');
      case ConnectedDeviceType.safetyMonitor:
        final state = ref.watch(safetyMonitorStateProvider);
        return _resolveDisplayName(
            state.deviceName, state.deviceId, 'Safety Monitor');
      case ConnectedDeviceType.coverCalibrator:
        final state = ref.watch(coverCalibratorStateProvider);
        return _resolveDisplayName(
            state.deviceName, state.deviceId, 'Cover Calibrator');
    }
  }

  Widget _buildConnectionBadge(
      DeviceConnectionState state, SkotiqColors colors) {
    // A device connected outside the profile is reported as "Session only" so
    // the chip and the note beneath it say the same thing once.
    if (state == DeviceConnectionState.connected && widget.sessionOnly) {
      return const SkotiqChip(
        label: 'Session only',
        tone: ChipTone.warning,
        dot: true,
      );
    }
    final (tone, text) = switch (state) {
      DeviceConnectionState.connected => (ChipTone.success, 'Connected'),
      DeviceConnectionState.connecting => (ChipTone.warning, 'Connecting'),
      DeviceConnectionState.error => (ChipTone.error, 'Error'),
      DeviceConnectionState.disconnected => (ChipTone.neutral, 'Not connected'),
    };
    return SkotiqChip(label: text, tone: tone, dot: true);
  }

  Widget _buildMetricsRow(SkotiqColors colors) {
    final metrics = _getMetrics();
    if (metrics.isEmpty) return const SizedBox.shrink();

    // A readout NEVER ellipsises: an "00:00:…" or "+47° 1…" is not a smaller
    // reading, it is a different one. When the widest value cannot fit the
    // panel at 20 px, the whole row steps down to 14 px together (so the row
    // still reads as one scale) and the gap tightens with it.
    //
    // The width comes from [DeviceTileWidth], NOT a LayoutBuilder: the grid
    // lays its rows out inside an IntrinsicHeight, and a LayoutBuilder has no
    // intrinsic height — which collapsed the panel to its header and painted
    // the actions outside it.
    final available = DeviceTileWidth.of(context) -
        SkotiqTokens.spaceLg * 2 -
        _deviceReadoutGap * (metrics.length - 1);
    final widest = metrics.fold<double>(
      0,
      (best, metric) {
        final width = _readoutWidth(metric, ReadoutSize.md);
        return width > best ? width : best;
      },
    );
    final fits = widest * metrics.length <= available;

    return ReadoutRow(
      gap: fits ? _deviceReadoutGap : _deviceReadoutGapDense,
      children: [
        for (final metric in metrics)
          Readout(
            value: metric.value,
            unit: metric.unit,
            label: metric.label,
            size: fits ? ReadoutSize.md : ReadoutSize.sm,
            valueColor: metric.valueColor,
          ),
      ],
    );
  }

  /// Width [metric] needs at [size], measured with the real style rather than
  /// guessed from the character count (the mono face is not the UI face, and
  /// the label can be wider than the value).
  double _readoutWidth(_DeviceMetric metric, ReadoutSize size) {
    final valueStyle = switch (size) {
      ReadoutSize.lg => SkotiqTypography.readoutLg,
      ReadoutSize.md => SkotiqTypography.readoutMd,
      ReadoutSize.sm => SkotiqTypography.readoutSm,
    };
    final text = '${metric.value ?? kReadoutUnknown}${metric.unit ?? ''}';
    final value = _measure(text, valueStyle);
    final label = _measure(
      metric.label.toUpperCase(),
      SkotiqTypography.readoutLabel,
    );
    return value > label ? value : label;
  }

  double _measure(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  List<_DeviceMetric> _getMetrics() {
    switch (widget.type) {
      case ConnectedDeviceType.camera:
        final state = ref.watch(cameraStateProvider);
        return [
          _DeviceMetric(
            value: state.temperature?.toStringAsFixed(1),
            unit: '°C',
            label: 'Sensor',
          ),
          _DeviceMetric(
            value: state.coolerPower?.toStringAsFixed(0),
            unit: '%',
            label: 'Cooler',
          ),
          _DeviceMetric(
            value: state.isExposing ? 'Exposing' : 'Idle',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.mount:
        final state = ref.watch(mountStateProvider);
        return [
          // Hours + minutes, degrees + arcminutes. A padded-colon sexagesimal
          // with seconds is one field too wide for a 378 px panel and was
          // ellipsising to "00:00:…", which reads as a different coordinate;
          // the seconds live on Imaging's mount tab.
          _DeviceMetric(
            value: state.ra != null
                ? CoordinateFormat.raHm(state.ra!, wrapHours: true)
                : null,
            label: 'RA',
          ),
          _DeviceMetric(
            value:
                state.dec != null ? CoordinateFormat.decDm(state.dec!) : null,
            label: 'Dec',
          ),
          _DeviceMetric(
            value: state.isHoming
                ? 'Homing'
                : state.isSlewing
                    ? 'Slewing'
                    : state.isParked
                        ? 'Parked'
                        : state.isTracking
                            ? 'Tracking'
                            : state.isAtHome
                                ? 'At home'
                                : state.homeUnconfirmed
                                    ? 'Home (unconfirmed)'
                                    : 'Idle',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.focuser:
        final state = ref.watch(focuserStateProvider);
        return [
          _DeviceMetric(
            value: _stepCount(state.position),
            label: 'Position',
          ),
          _DeviceMetric(
            value: state.temperature?.toStringAsFixed(1),
            unit: '°C',
            label: 'Temp',
          ),
          _DeviceMetric(
            value: state.isMoving ? 'Moving' : 'Ready',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.filterWheel:
        final state = ref.watch(filterWheelStateProvider);
        final slots = state.filterNames.length;
        return [
          _DeviceMetric(
            value: state.currentFilterName,
            label: 'Filter',
          ),
          _DeviceMetric(
            value: state.currentPosition != null
                ? '${state.currentPosition! + 1}'
                : null,
            unit: slots > 0 ? '/$slots' : null,
            label: 'Slot',
          ),
        ];

      case ConnectedDeviceType.guider:
        final state = ref.watch(guiderStateProvider);
        return [
          _DeviceMetric(
            value: state.rmsTotal?.toStringAsFixed(2),
            unit: '"',
            label: 'RMS total',
          ),
          _DeviceMetric(
            value: state.rmsRa?.toStringAsFixed(2),
            unit: '"',
            label: 'RMS RA',
          ),
          _DeviceMetric(
            value: state.isGuiding ? 'Guiding' : 'Idle',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.rotator:
        final state = ref.watch(rotatorStateProvider);
        return [
          _DeviceMetric(
            value: state.position?.toStringAsFixed(1),
            unit: '°',
            label: 'Angle',
          ),
          _DeviceMetric(
            value: state.isMoving ? 'Moving' : 'Ready',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.dome:
        final state = ref.watch(domeStateProvider);
        return [
          _DeviceMetric(
            value: state.azimuth?.toStringAsFixed(1),
            unit: '°',
            label: 'Azimuth',
          ),
          _DeviceMetric(
            value: _shutterStatusLabel(state.shutterStatus),
            label: 'Shutter',
          ),
          _DeviceMetric(
            value: state.isSlewing
                ? 'Slewing'
                : state.isParked
                    ? 'Parked'
                    : state.isSlaved
                        ? 'Slaved'
                        : 'Idle',
            label: 'State',
          ),
        ];

      case ConnectedDeviceType.weather:
        final state = ref.watch(weatherStateProvider);
        final weatherColors = SkotiqColors.of(context);
        final hasRain = state.rainRate != null && state.rainRate! > 0;
        return [
          _DeviceMetric(
            value: state.temperature?.toStringAsFixed(1),
            unit: '°C',
            label: 'Temp',
          ),
          _DeviceMetric(
            value: state.humidity?.toStringAsFixed(0),
            unit: '%',
            label: 'Humidity',
          ),
          if (hasRain)
            _DeviceMetric(
              value: 'Rain',
              label: 'Alert',
              valueColor: weatherColors.error,
            )
          else
            _DeviceMetric(
              value: state.dewPoint?.toStringAsFixed(1),
              unit: '°C',
              label: 'Dew point',
            ),
        ];

      case ConnectedDeviceType.safetyMonitor:
        final state = ref.watch(safetyMonitorStateProvider);
        final colors = SkotiqColors.of(context);
        // The age must be driven by a CLOCK, not by the provider that sets
        // `lastChecked`. Computing it at build time only worked out to "0s ago"
        // forever: the widget rebuilt exactly when lastChecked was set to
        // DateTime.now(), so sampling the label every 3 s over 42 s produced
        // fourteen consecutive "0s ago" against a 5 s poll.
        final now = _tickNow();
        final lastChecked = state.lastChecked;
        final age = lastChecked == null ? null : now.difference(lastChecked);
        final isStale = age != null && age > _safetyStatusStaleAfter;
        return [
          // A stale reading is NOT a safe reading: once the read is older
          // than the staleness budget the card reports Stale, never Safe.
          _DeviceMetric(
            value: lastChecked == null
                ? null
                : isStale
                    ? 'Stale'
                    : state.isSafe
                        ? 'Safe'
                        : 'Unsafe',
            label: 'State',
            valueColor: lastChecked == null || isStale
                ? colors.warning
                : state.isSafe
                    ? colors.success
                    : colors.error,
          ),
          _DeviceMetric(
            value: age != null ? _formatAge(age) : null,
            unit: age != null ? 'ago' : null,
            label: 'Last checked',
            valueColor: isStale ? colors.warning : null,
          ),
        ];

      case ConnectedDeviceType.coverCalibrator:
        final state = ref.watch(coverCalibratorStateProvider);
        final capabilities = ref.watch(
          equipmentCoverCalibratorCapabilitiesProvider(state.deviceId ?? ''),
        );
        final snapshot = capabilities.valueOrNull;
        if (snapshot == null) {
          return [
            _DeviceMetric(
              value: capabilities.hasError ? 'Unavailable' : null,
              label: 'Capabilities',
            ),
          ];
        }
        return [
          if (snapshot.coverPresent)
            _DeviceMetric(
              value: _coverStatusLabel(
                snapshot.coverStatus ?? CoverStatus.unknown,
              ),
              label: 'Cover',
            ),
          if (snapshot.calibratorPresent) ...[
            _DeviceMetric(
              value: _calibratorStatusLabel(snapshot.calibratorStatus),
              label: 'Light',
            ),
            _DeviceMetric(
              // Brightness is a driver reading. A calibrator that reports no
              // brightness, or no brightness scale, must read "—" — showing
              // "0/0" or "0/100" claims the panel is measurably dark when the
              // truth is that nothing was measured.
              value: _calibratorBrightnessLevel(snapshot),
              unit: _calibratorBrightnessScale(snapshot),
              label: 'Brightness',
            ),
          ],
          if (!snapshot.coverPresent && !snapshot.calibratorPresent)
            _DeviceMetric(
              value: 'None reported',
              label: 'Capabilities',
            ),
        ];
    }
  }

  String _shutterStatusLabel(ShutterStatus status) {
    switch (status) {
      case ShutterStatus.open:
        return 'Open';
      case ShutterStatus.closed:
        return 'Closed';
      case ShutterStatus.opening:
        return 'Opening';
      case ShutterStatus.closing:
        return 'Closing';
      case ShutterStatus.error:
        return 'Error';
      case ShutterStatus.unknown:
        return 'Unknown';
    }
  }

  String _coverStatusLabel(CoverStatus status) {
    switch (status) {
      case CoverStatus.open:
        return 'Open';
      case CoverStatus.closed:
        return 'Closed';
      case CoverStatus.moving:
        return 'Moving';
      case CoverStatus.notPresent:
        return 'Not present';
      case CoverStatus.unknown:
        return 'Unknown';
      case CoverStatus.error:
        return 'Error';
    }
  }

  String _calibratorStatusLabel(CalibratorStatus? status) {
    return switch (status) {
      CalibratorStatus.ready => 'ON',
      CalibratorStatus.notReady => 'WARMING',
      CalibratorStatus.off => 'OFF',
      CalibratorStatus.notPresent => 'NONE',
      CalibratorStatus.error => 'ERROR',
      CalibratorStatus.unknown || null => 'UNKNOWN',
    };
  }

  /// The calibrator's brightness LEVEL, or null when the driver reported none.
  ///
  /// `maxBrightness` arrives as 0 when neither the host payload nor the native
  /// capability probe carries a brightness scale, and `brightness` is null when
  /// the level itself is unreported. Either way there is no reading to show, so
  /// the readout renders the em dash rather than a fabricated "0/0".
  String? _calibratorBrightnessLevel(
      CoverCalibratorCapabilitySnapshot snapshot) {
    final isPowered = snapshot.calibratorStatus == CalibratorStatus.ready ||
        snapshot.calibratorStatus == CalibratorStatus.notReady;
    if (!isPowered) return null;
    final level = snapshot.brightness;
    if (level == null || snapshot.maxBrightness <= 0) return null;
    return '$level';
  }

  /// The `/max` half of the brightness reading, attached to the level as its
  /// unit. Null whenever the level itself is unknown.
  String? _calibratorBrightnessScale(
      CoverCalibratorCapabilitySnapshot snapshot) {
    if (_calibratorBrightnessLevel(snapshot) == null) return null;
    return '/${snapshot.maxBrightness}';
  }

  /// "Now" as seen by the card's own 5 s freshness clock
  /// (see `_startFreshnessTicker`).
  ///
  /// Freshness labels MUST derive from a clock, not from `DateTime.now()` read
  /// during a build that only happens when the value being aged is refreshed —
  /// that combination pinned "Last Checked" at "0s ago" permanently, including
  /// while polling was wedged.
  DateTime _tickNow() => _freshnessNow;
}

/// Marks a card whose device is connected but is NOT the device the active
/// profile assigns to that slot.
///
/// Discovery's "Add to profile" (persistent) and "Connect" (ephemeral) sit side
/// by side, and the resulting cards were pixel-identical to the profile
/// devices. A user who set up nine devices at dusk saw "9 connected" and
/// reasonably concluded the rig was configured; the next night four came up.
///
/// ONE 12 px muted line with the remedy as a link, not the amber paragraph:
/// the "Session only" chip in the header already carries the warning colour.
class _SessionOnlyNotice extends StatelessWidget {
  final SkotiqColors colors;
  final VoidCallback? onAddToProfile;

  const _SessionOnlyNotice({required this.colors, this.onAddToProfile});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(LucideIcons.info, size: 13, color: colors.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: 'Connected but not in this profile. ',
              children: [
                if (onAddToProfile != null)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: _AddToProfileLink(onTap: onAddToProfile!),
                  ),
              ],
            ),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

/// The inline "Add to profile" link inside [_SessionOnlyNotice].
class _AddToProfileLink extends StatelessWidget {
  final VoidCallback onTap;

  const _AddToProfileLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // `enabled` and `onTap` both matter: a Semantics node marked `button` with
    // neither reports as DISABLED to AT-SPI, so a screen reader (and the audit
    // harness) sees a dead control where the link works fine with a mouse.
    return Semantics(
      button: true,
      enabled: true,
      label: 'Add to profile',
      onTap: onTap,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Text(
            'Add to profile',
            style: SkotiqTypography.caption.copyWith(color: colors.primary),
          ),
        ),
      ),
    );
  }
}

/// Renders a duration as `12s` / `4m` / `2h`. Takes the age rather than a
/// timestamp so the caller supplies the clock — see the safety-monitor branch of
/// `_getMetrics` for why reading `DateTime.now()` in here made the label
/// structurally incapable of ageing.
String _formatAge(Duration age) {
  if (age.isNegative) return '0s';
  if (age.inSeconds < 60) return '${age.inSeconds}s';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  return '${age.inHours}h';
}

/// How old a safety reading may be before the card stops presenting it as the
/// current safety verdict.
///
/// The environmental poll runs every 5 s with a 4 s read cap, so a healthy cycle
/// completes well inside 10 s. 30 s therefore cannot fire on ordinary jitter but
/// still catches a wedged or unresponsive monitor within half a minute.
const Duration _safetyStatusStaleAfter = Duration(seconds: 30);

/// Side of the device panel's leading icon square (mockup: 32).
const double _deviceIconSquare = 32.0;

/// The glyph inside that square.
const double _deviceIconSize = 16.0;

/// Gap between the device panel's readouts (mockup: 20).
const double _deviceReadoutGap = SkotiqTokens.spaceXl;

/// The dense gap the readout row falls back to when the panel cannot seat the
/// 20 px scale.
const double _deviceReadoutGapDense = SkotiqTokens.spaceMd;

/// The focuser's step count.
///
/// Plain digits: the bundled fonts carry no thin space (U+2009), so a grouped
/// "25 000" rendered as `25<tofu>000` — a separator that is not there is worse
/// than no separator.
String? _stepCount(int? value) => value?.toString();
