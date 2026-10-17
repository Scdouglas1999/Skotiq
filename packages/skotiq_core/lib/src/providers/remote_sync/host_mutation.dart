part of '../remote_sync_handler.dart';

void _applyHostMutation(Object reader, Map<String, dynamic> data) {
  final entityType = data['entityType'] as String?;
  final action = data['action'] as String?;
  if (entityType == null || action == null) {
    return;
  }

  switch (entityType) {
    case HostMutationEntity.equipment:
      _applyEquipmentMutationFromHost(reader, action, data);
    case HostMutationEntity.guider:
      _applyGuiderMutationFromHost(reader, action, data);
    case HostMutationEntity.framing:
      _applyFramingMutationFromHost(reader, action, data);
    case HostMutationEntity.sequencer:
      _applySequencerMutationFromHost(reader, action, data);
    case HostMutationEntity.sequenceEditor:
      _applySequenceEditorMirror(reader, action, data);
    case HostMutationEntity.profile:
      _invalidateHostProfiles(reader);
    case HostMutationEntity.settings:
      // Deliberately NOT invalidating anything per-event here. The host
      // broadcasts `settings/updated` at very high frequency — the scheduler
      // persists runtime config (e.g. conditions_score) many times a second and
      // each persist emits a settings mutation (measured ~14/s on a live rig).
      // Reacting per-event reloads the entire "Plan Tonight" Recommendation tab
      // dozens of times a second on a slave, and a settings change is not a
      // profile change, so it must not invalidate the equipment-PROFILE
      // providers either. appSettings is already re-pulled every 30s by
      // hydrateRemoteSessionState (and on reconnect), so a genuine settings
      // change mirrors within one poll cycle without the churn.
      break;
    case HostMutationEntity.sequence:
      _invalidateSequenceLibrary(reader, sequenceId: _parseSequenceId(data));
    case HostMutationEntity.target:
      _invalidateHostTargets(reader);
      _invalidateSequenceLibrary(reader);
    case HostMutationEntity.session:
      _invalidateHostSessions(reader);
    case HostMutationEntity.capturedImage:
      _invalidateHostCapturedImages(reader);
    default:
      break;
  }
}

void _applyEquipmentMutationFromHost(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  final deviceTypeStr = data['deviceType'] as String?;
  final deviceId = data['deviceId'] as String? ?? '';
  final deviceName = data['deviceName'] as String? ?? deviceId;

  final parsed = deviceTypeStr == null
      ? null
      : deviceTypeFromWireName(deviceTypeStr);
  if (parsed == null) {
    return;
  }

  switch (action) {
    case HostMutationAction.connected:
      final notifier = readDeviceConnectionNotifier(reader, parsed);
      if (!_isDeviceAlreadyConnected(reader, parsed, deviceId)) {
        notifier.setConnecting(deviceId, deviceName);
      }
      notifier.setConnected();
    case HostMutationAction.disconnected:
      readDeviceConnectionNotifier(reader, parsed).setDisconnected();
    default:
      break;
  }
}

void _applyGuiderMutationFromHost(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  final notifier = readDeviceConnectionNotifier(reader, DeviceType.guider);
  switch (action) {
    case HostMutationAction.connected:
      if (!_isDeviceAlreadyConnected(
        reader,
        DeviceType.guider,
        'phd2_guider',
      )) {
        notifier.setConnecting('phd2_guider', 'PHD2');
      }
      notifier.setConnected();
    case HostMutationAction.disconnected:
      notifier.setDisconnected();
    case HostMutationAction.started:
    case HostMutationAction.stopped:
    case HostMutationAction.paused:
    case HostMutationAction.resumed:
      notifier.setConnected();
    default:
      final state = data['state'] as String?;
      if (state != null && state.isNotEmpty) {
        notifier.setConnected();
      }
  }
}

void _applyFramingMutationFromHost(
  Object reader,
  String action,
  Map<String, dynamic> data,
) {
  if (action != HostMutationAction.updated &&
      action != HostMutationAction.created) {
    return;
  }

  final ra = data['ra'];
  final dec = data['dec'];
  final name = data['name'] as String?;
  if (ra is! num || dec is! num) {
    return;
  }

  _read(reader, framingProvider.notifier).setTargetCoordinates(
    ra.toDouble(),
    dec.toDouble(),
    name: name,
    fromRemoteSync: true,
  );
}

void _applyFramingTargetChanged(Object reader, SkotiqEvent event) {
  final ra = (event.data['ra'] as num?)?.toDouble();
  final dec = (event.data['dec'] as num?)?.toDouble();
  final name = event.data['name'] as String?;
  if (ra == null || dec == null || name == null || name.isEmpty) {
    return;
  }

  _read(
    reader,
    framingProvider.notifier,
  ).setTargetCoordinates(ra, dec, name: name, fromRemoteSync: true);
}

void _invalidateHostProfiles(Object reader) {
  _invalidateEquipmentSyncProviders(reader);
  _invalidate(reader, allProfilesProvider);
  _invalidate(reader, activeProfileProvider);
}

void _invalidateHostTargets(Object reader) {
  _invalidate(reader, allDbTargetsProvider);
  _invalidate(reader, favoriteDbTargetsProvider);
  _invalidateTargetProgress(reader);
}

void _invalidateHostCapturedImages(Object reader) {
  _invalidate(reader, allDbImagesProvider);
  _invalidate(reader, capturedImageByIdProvider);
  _invalidateTargetProgress(reader);
}

void _invalidateHostSessions(Object reader) {
  _invalidate(reader, allSessionsProvider);
  _invalidate(reader, incompleteSessionsProvider);
  _invalidate(reader, sessionStateProvider);
}

void _invalidateTargetProgress(Object reader) {
  _invalidate(reader, allTargetProgressProvider);
  _invalidate(reader, targetProgressProvider);
}
