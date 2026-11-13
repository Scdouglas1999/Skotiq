part of '../remote_sync_handler.dart';

/// A change the host announced: which kind of thing, and what happened to it.
class HostDataChange {
  const HostDataChange(this.entityType, this.action);

  final String entityType;
  final String action;

  static HostDataChange? of(Map<String, dynamic> data) {
    final entityType = data['entityType'] as String?;
    final action = data['action'] as String?;
    if (entityType == null || action == null) return null;
    return HostDataChange(entityType, action);
  }
}

/// Re-read the stored data [change] is about. The same on the host's own
/// window and on a linked client: both show what the host's database holds.
void _rereadChangedHostData(
  ProviderContainer container,
  HostDataChange change,
  Map<String, dynamic> data,
) {
  switch (change.entityType) {
    case HostMutationEntity.profile:
      _invalidateHostProfiles(container);
    case HostMutationEntity.settings:
      // The host announces a settings change many times a second while the
      // scheduler stores its running values (about 14 a second on a live
      // rig). Settings are re-read with the periodic re-read and on
      // reconnect instead, so a change still shows within one cycle.
      break;
    case HostMutationEntity.sequence:
      _invalidateSequenceLibrary(container, sequenceId: _parseSequenceId(data));
    case HostMutationEntity.target:
      _invalidateHostTargets(container);
      _invalidateSequenceLibrary(container);
    case HostMutationEntity.session:
      _invalidateHostSessions(container);
    case HostMutationEntity.capturedImage:
      _invalidateHostCapturedImages(container);
  }
}

void _applyEquipmentMutationFromHost(
  ProviderContainer container,
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

  // The guide camera is the guider's: it has no slot, and the imaging
  // camera's is not its to take or to empty.
  if (_isHostGuideCamera(container, parsed, deviceId)) return;

  final notifier = readDeviceConnectionNotifier(container, parsed);
  switch (action) {
    case HostMutationAction.connected:
      if (!_isDeviceAlreadyConnected(container, parsed, deviceId)) {
        notifier.setConnecting(deviceId, deviceName);
      }
      notifier.setConnected();
    case HostMutationAction.disconnected:
      _emptySlotFor(container, parsed, deviceId);
    default:
      break;
  }
}

void _applyGuiderMutationFromHost(
  ProviderContainer container,
  String action,
  Map<String, dynamic> data,
) {
  final notifier = readDeviceConnectionNotifier(container, DeviceType.guider);
  switch (action) {
    case HostMutationAction.connected:
      if (!_isDeviceAlreadyConnected(
        container,
        DeviceType.guider,
        'phd2_guider',
      )) {
        notifier.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
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

void _invalidateHostProfiles(ProviderContainer container) {
  _invalidateEquipmentSyncProviders(container);
  container.invalidate(allProfilesProvider);
  container.invalidate(activeProfileProvider);
}

void _invalidateHostTargets(ProviderContainer container) {
  container.invalidate(allDbTargetsProvider);
  container.invalidate(favoriteDbTargetsProvider);
  _invalidateTargetProgress(container);
}

void _invalidateHostCapturedImages(ProviderContainer container) {
  container.invalidate(allDbImagesProvider);
  container.invalidate(capturedImageByIdProvider);
  _invalidateTargetProgress(container);
}

void _invalidateHostSessions(ProviderContainer container) {
  container.invalidate(allSessionsProvider);
  container.invalidate(incompleteSessionsProvider);
  container.invalidate(sessionStateProvider);
}

void _invalidateTargetProgress(ProviderContainer container) {
  container.invalidate(allTargetProgressProvider);
  container.invalidate(targetProgressProvider);
}
