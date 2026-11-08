part of '../device_service.dart';

extension _DeviceServiceProfileConnections on DeviceService {
  /// Parallel "Connect All" with per-device progress.
  ///
  /// Returns a [Stream] of [DeviceConnectProgress] events that the caller
  /// (typically the equipment screen) can subscribe to so each device card
  /// can render its own live status: idle → connecting → connected/failed.
  ///
  /// Why this exists: the equipment screen's previous "Connect All" button
  /// iterated devices sequentially with `await`. Ten devices × 3-5 s each
  /// meant 30-50 s of wall-clock time with no feedback per device. A user
  /// staring at a single spinner has no idea whether the focuser is the
  /// one taking forever or whether the dome failed and the mount succeeded.
  ///
  /// Contract:
  ///
  /// * Every configured device-type from [profile] is connected in parallel
  ///   with `Future.wait`. Device connects do not interact with each other
  ///   during the connect phase (mount/camera/focuser/etc. each go to a
  ///   different driver) so parallelism is safe.
  /// * For each device, the stream emits:
  ///     1. `connecting` immediately as the call is dispatched, and
  ///     2. `connected` if the underlying `connectX` completes, or
  ///        `failed` carrying the raw error if it throws.
  /// * One device failing does NOT block any other device. Per-device
  ///   errors are reported as `failed` events; the stream itself never
  ///   errors and always closes cleanly once every device is settled.
  /// * The original backend error rides on the `failed` event verbatim
  ///   (driver error, "device not reachable", USB hub blip); it is never
  ///   swallowed or rewritten.
  /// * If [profile] has no configured devices, the stream closes
  ///   immediately with no events.
  ///
  /// The returned stream is single-subscription so initial `connecting`
  /// events are buffered until the caller attaches its listener. UI
  /// surfaces that need to fan out to multiple widgets should feed the
  /// stream through [deviceConnectionProgressProvider]
  /// (see `record(event)`), which materializes the events into a
  /// `ref.watch`-able snapshot that any number of widgets can observe.
  Stream<DeviceConnectProgress> _connectAllFromProfile(
    EquipmentProfileModel profile,
  ) {
    // (id, deviceType label, connector, saved name, discovery type). Order is
    // informational only: every device is dispatched in parallel.
    final entries =
        <(String?, String, Future<void> Function(String), String?, DeviceType)>[
          (
            profile.cameraId,
            'camera',
            connectCamera,
            profile.cameraName,
            DeviceType.camera,
          ),
          (
            profile.mountId,
            'mount',
            connectMount,
            profile.mountName,
            DeviceType.mount,
          ),
          (
            profile.focuserId,
            'focuser',
            connectFocuser,
            profile.focuserName,
            DeviceType.focuser,
          ),
          (
            profile.filterWheelId,
            'filter wheel',
            connectFilterWheel,
            profile.filterWheelName,
            DeviceType.filterWheel,
          ),
          (
            profile.guideCameraId,
            'guide camera',
            connectGuideCamera,
            profile.guideCameraName,
            DeviceType.camera,
          ),
          (
            profile.guiderId,
            'guider',
            connectGuider,
            profile.guiderName,
            DeviceType.guider,
          ),
          (
            profile.rotatorId,
            'rotator',
            connectRotator,
            profile.rotatorName,
            DeviceType.rotator,
          ),
          (profile.domeId, 'dome', connectDome, null, DeviceType.dome),
          (
            profile.weatherId,
            'weather station',
            connectWeather,
            null,
            DeviceType.weather,
          ),
          (
            profile.safetyMonitorId,
            'safety monitor',
            connectSafetyMonitor,
            profile.safetyMonitorName,
            DeviceType.safetyMonitor,
          ),
          (
            profile.switchId,
            'switch',
            connectSwitch,
            profile.switchName,
            DeviceType.switch_,
          ),
          (
            profile.coverCalibratorId,
            'cover calibrator',
            connectCoverCalibrator,
            null,
            DeviceType.coverCalibrator,
          ),
        ];

    // Use a single-subscription StreamController so events are buffered
    // until the caller subscribes. A broadcast controller would drop the
    // initial `connecting` events because the caller hasn't yet attached
    // its `await for` listener at the moment we add them.
    final controller = StreamController<DeviceConnectProgress>();

    // Filter to only configured devices. An empty list still produces a
    // valid stream — the caller just sees no events before close.
    final active = entries
        .where((e) => e.$1 != null && e.$1!.isNotEmpty)
        .map((e) => (e.$1!, e.$2, e.$3, e.$4, e.$5))
        .toList(growable: false);

    if (active.isEmpty) {
      // No devices configured — close immediately so the caller's `await
      // for` exits cleanly.
      scheduleMicrotask(controller.close);
      return controller.stream;
    }

    // Defer dispatch one microtask so the caller (typically `await for`)
    // has time to attach its listener before any events fire. The
    // single-subscription controller buffers anyway, but emitting on the
    // next turn also keeps observable ordering deterministic in tests
    // that drive multiple sweeps in the same event-loop turn.
    scheduleMicrotask(() async {
      final resolved = await _resolveProfilePositions(profile, active);

      // Dispatch every connect in parallel. Each future swallows its own
      // error and routes it onto the stream as a `failed` event so one
      // bad device cannot abort the sweep.
      final futures = <Future<void>>[];
      final settled = <String, Future<void>>{};
      for (final (savedId, deviceType, connect, _, _) in active) {
        final resolution = resolved[deviceType]!;
        final id = resolution.deviceId ?? savedId;
        if (resolution.refusal != null) {
          controller.add(
            DeviceConnectProgress(
              deviceType: deviceType,
              deviceId: savedId,
              status: DeviceConnectProgressStatus.failed,
              error: StateError(resolution.refusal!),
              errorMessage: resolution.refusal,
            ),
          );
          continue;
        }
        controller.add(
          DeviceConnectProgress(
            deviceType: deviceType,
            deviceId: id,
            status: DeviceConnectProgressStatus.connecting,
          ),
        );

        // A software guider (the built-in one) takes its frames through the
        // guide camera and pulses the mount, so it is connected once those
        // two have settled; connecting it alongside them fails every time.
        final dependencies = deviceType == 'guider' && !isPhd2DeviceId(id)
            ? [settled['mount'], settled['guide camera']].nonNulls.toList()
            : const <Future<void>>[];
        final attempt = dependencies.isEmpty
            ? connect(id)
            : Future.wait(dependencies).then((_) => connect(id));
        final future = attempt
            .then((_) {
              if (!controller.isClosed) {
                controller.add(
                  DeviceConnectProgress(
                    deviceType: deviceType,
                    deviceId: id,
                    status: DeviceConnectProgressStatus.connected,
                  ),
                );
              }
            })
            .catchError((Object error, StackTrace stack) {
              if (!controller.isClosed) {
                controller.add(
                  DeviceConnectProgress(
                    deviceType: deviceType,
                    deviceId: id,
                    status: DeviceConnectProgressStatus.failed,
                    error: error,
                    errorMessage: error.toString(),
                  ),
                );
              }
            });
        settled[deviceType] = future;
        futures.add(future);
      }

      // Close the stream once every device has settled. We use
      // `Future.wait` without `eagerError` because we've already caught
      // every per-device error above — every future resolves
      // successfully here.
      unawaited(
        Future.wait(futures).whenComplete(() {
          if (!controller.isClosed) {
            controller.close();
          }
        }),
      );
    });

    return controller.stream;
  }

  /// Check each positional id in [active] against the name the profile saved
  /// for it, and move it to the device that carries that name. The corrected
  /// ids are written back to the profile so the next connect, and every screen
  /// that shows the profile, names the right device.
  ///
  /// Discovery for a type that fails or does not answer in time leaves that
  /// slot on its saved id: an unverifiable position is connected as before,
  /// and the host still refuses a device that answers as another model.
  Future<Map<String, ProfileSlotResolution>> _resolveProfilePositions(
    EquipmentProfileModel profile,
    List<(String, String, Future<void> Function(String), String?, DeviceType)>
    active,
  ) => _resolveProfileSlots(profile, [
    for (final (savedId, label, _, savedName, type) in active)
      (label: label, savedId: savedId, savedName: savedName, type: type),
  ]);

  /// Resolve [slots] of [profile] together (see [resolveProfileSlots]),
  /// write any moved ids back to the profile, and record what each slot must
  /// be for [_expectedModelFor].
  Future<Map<String, ProfileSlotResolution>> _resolveProfileSlots(
    EquipmentProfileModel profile,
    List<({String label, String savedId, String? savedName, DeviceType type})>
    slots,
  ) async {
    final discovered = <DeviceType, List<DeviceInfo>>{};
    for (final slot in slots) {
      final name = slot.savedName;
      if (!isPositionalDeviceId(slot.savedId) ||
          name == null ||
          name.trim().isEmpty ||
          discovered.containsKey(slot.type)) {
        continue;
      }
      try {
        discovered[slot.type] = await _backend
            .discoverDevices(slot.type)
            .timeout(DeviceService._profilePositionDiscoveryTimeout);
      } catch (e) {
        _ref
            .read(loggingServiceProvider)
            .warning(
              'Could not check which ${slot.label} is at ${slot.savedId} '
              '($e); connecting the saved id',
              source: 'DeviceService',
            );
        discovered[slot.type] = const [];
      }
    }
    final typeOf = {for (final slot in slots) slot.label: slot.type};
    final resolutions = resolveProfileSlots(
      [
        for (final slot in slots)
          (label: slot.label, savedId: slot.savedId, savedName: slot.savedName),
      ],
      (label) => discovered[typeOf[label]] ?? const [],
    );

    if (_slotExpectationsProfileId != profile.id) {
      _slotExpectations.clear();
      _slotExpectationsProfileId = profile.id;
    }
    final corrections = <String, String>{};
    for (final slot in slots) {
      final resolution = resolutions[slot.label]!;
      final id = resolution.deviceId;
      final name = slot.savedName?.trim();
      if (id != null && name != null && name.isNotEmpty) {
        _slotExpectations[slot.label] = (deviceId: id, model: name);
      } else {
        _slotExpectations.remove(slot.label);
      }
      if (resolution.corrected) {
        corrections[slot.label] = id!;
        _ref
            .read(loggingServiceProvider)
            .warning(
              'Profile ${profile.name}: ${slot.savedName} moved from '
              '${slot.savedId} to $id; connecting it there and updating the '
              'profile',
              source: 'DeviceService',
            );
      }
    }
    final profileId = profile.id;
    if (corrections.isNotEmpty && profileId != null) {
      try {
        await _ref
            .read(profileServiceProvider)
            .updateProfileDevices(
              profileId,
              cameraId: corrections['camera'],
              guideCameraId: corrections['guide camera'],
              mountId: corrections['mount'],
              focuserId: corrections['focuser'],
              filterWheelId: corrections['filter wheel'],
              guiderId: corrections['guider'],
              rotatorId: corrections['rotator'],
              safetyMonitorId: corrections['safety monitor'],
              switchId: corrections['switch'],
            );
      } catch (e) {
        _ref
            .read(loggingServiceProvider)
            .warning(
              'Could not save the corrected device ids to profile '
              '${profile.name}: $e',
              source: 'DeviceService',
            );
      }
    }
    return resolutions;
  }

  /// The profile slots a reconnect of [type] at [deviceId] has to resolve,
  /// main slot first. Empty when [deviceId] is not the active profile's
  /// device for [type], or is not a position on the bus.
  ///
  /// Both camera slots resolve together: after the bus re-enumerates, the
  /// main camera can come back at the guide camera's old id.
  List<({String label, String savedId, String? savedName, DeviceType type})>
  _reconnectSlots(EquipmentProfileModel profile, DeviceType type, String id) {
    if (!isPositionalDeviceId(id)) return const [];
    ({String label, String savedId, String? savedName, DeviceType type})? slot(
      String label,
      String? savedId,
      String? savedName,
    ) => savedId == null || savedId.isEmpty
        ? null
        : (label: label, savedId: savedId, savedName: savedName, type: type);
    final slots = switch (type) {
      DeviceType.camera => [
        slot('camera', profile.cameraId, profile.cameraName),
        slot('guide camera', profile.guideCameraId, profile.guideCameraName),
      ],
      DeviceType.focuser => [
        slot('focuser', profile.focuserId, profile.focuserName),
      ],
      DeviceType.filterWheel => [
        slot('filter wheel', profile.filterWheelId, profile.filterWheelName),
      ],
      DeviceType.rotator => [
        slot('rotator', profile.rotatorId, profile.rotatorName),
      ],
      DeviceType.mount => [slot('mount', profile.mountId, profile.mountName)],
      _ => const <Null>[],
    }.nonNulls.toList();
    if (slots.isEmpty || slots.first.savedId != id) return const [];
    return slots;
  }

  /// Where a reconnect of the profile's [type] device, last at [deviceId],
  /// has to go: the id the profile's saved name is at now. Returns
  /// [deviceId] unchanged for a device the profile does not name. Throws
  /// with the reason when the slot cannot be resolved safely (the device the
  /// profile names is not found and something else is at its id, or two
  /// devices carry its name).
  Future<String> _reconnectTarget(DeviceType type, String deviceId) async {
    final profile = _ref.read(activeEquipmentProfileProvider);
    if (profile == null) return deviceId;
    final slots = _reconnectSlots(profile, type, deviceId);
    if (slots.isEmpty) return deviceId;
    final resolution = (await _resolveProfileSlots(
      profile,
      slots,
    ))[slots.first.label]!;
    final refusal = resolution.refusal;
    if (refusal != null) throw StateError(refusal);
    return resolution.deviceId!;
  }

  /// The model the device at [deviceId] must be for the profile slot
  /// [label], or null when nothing is expected (the id is not a bus position,
  /// or it is not the profile's device for that slot). The host passes it to
  /// the driver layer, which refuses a device that answers as another model.
  String? _expectedModelFor(String label, String deviceId) {
    if (!isPositionalDeviceId(deviceId)) return null;
    final resolved = _slotExpectation(label);
    if (resolved != null && resolved.deviceId == deviceId) {
      return resolved.model;
    }
    final profile = _ref.read(activeEquipmentProfileProvider);
    if (profile == null) return null;
    final (id, name) = switch (label) {
      'camera' => (profile.cameraId, profile.cameraName),
      'guide camera' => (profile.guideCameraId, profile.guideCameraName),
      'mount' => (profile.mountId, profile.mountName),
      'focuser' => (profile.focuserId, profile.focuserName),
      'filter wheel' => (profile.filterWheelId, profile.filterWheelName),
      'rotator' => (profile.rotatorId, profile.rotatorName),
      _ => (null, null),
    };
    if (id != deviceId || name == null || name.trim().isEmpty) return null;
    return name.trim();
  }

  /// Disconnect all devices
  ///
  /// Each device-type disconnect now throws [DeviceNotConnectedException]
  /// when the matching state provider has no `deviceId`. For a
  /// bulk-disconnect sweep that is the normal case (most equipment profiles
  /// list only a handful of devices), so we silence that specific exception
  /// and let every other failure (driver error, stale handle, timeout, …)
  /// propagate so the caller can surface it. We deliberately do not use
  /// `Future.wait`: a single failure there cancels reporting of the others.
  Future<void> _disconnectAll() async {
    final disconnects = <(Future<void> Function(), String)>[
      (disconnectCamera, 'camera'),
      (disconnectMount, 'mount'),
      (disconnectFocuser, 'focuser'),
      (disconnectFilterWheel, 'filter wheel'),
      (disconnectGuider, 'guider'),
      (disconnectRotator, 'rotator'),
      (disconnectDome, 'dome'),
      (disconnectWeather, 'weather station'),
      (disconnectSafetyMonitor, 'safety monitor'),
      (disconnectSwitch, 'switch'),
      (disconnectCoverCalibrator, 'cover calibrator'),
    ];

    final errors = <String>[];
    // The guide camera has no device slot of its own; the profile names it.
    final guideCameraId = _ref
        .read(activeEquipmentProfileProvider)
        ?.guideCameraId;
    if (guideCameraId != null && guideCameraId.isNotEmpty) {
      try {
        await _backend.disconnectDevice(DeviceType.camera, guideCameraId);
      } catch (e) {
        // A guide camera that was never connected has nothing to disconnect.
        _ref
            .read(loggingServiceProvider)
            .info(
              'Guide camera $guideCameraId not disconnected: $e',
              source: 'DeviceService',
            );
      }
    }
    for (final (disconnect, name) in disconnects) {
      try {
        await disconnect();
      } on DeviceNotConnectedException {
        // Expected — the matching device type is not currently connected.
        continue;
      } catch (e) {
        errors.add('$name: $e');
      }
    }

    if (errors.isNotEmpty) {
      throw Exception(
        'Some devices failed to disconnect:\n${errors.join('\n')}',
      );
    }
  }
}
