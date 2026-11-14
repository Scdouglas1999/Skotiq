part of '../device_service.dart';

extension _DeviceServiceGuidingSequencerControls on DeviceService {
  /// Refuse a guiding command when no guider is connected. The host picks
  /// which guider answers; this only keeps a command off a rig with none.
  void _requireConnectedGuider() {
    final deviceId = _connectedDeviceIdFor(DeviceType.guider);
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No guider connected');
    }
  }

  Future<void> _stopGuiding() async {
    _requireConnectedGuider();

    await _backend.guiderStopGuiding();

    final guiderNotifier = _ref.read(guiderStateProvider.notifier);
    guiderNotifier.setGuiding(false);
  }

  Future<void> _startSequence() async {
    await _backend.sequencerStart();
  }

  Future<void> _stopSequence() async {
    await _backend.sequencerStop();
  }

  Future<void> _pauseSequence() async {
    await _backend.sequencerPause();
  }

  Future<void> _resumeSequence() async {
    await _backend.sequencerResume();
  }

  Future<void> _requestSequenceMeridianFlip() async {
    await _backend.sequencerRequestMeridianFlip();
  }

  Future<void> _loadSequence(String json) async {
    await _backend.sequencerLoadJson(json);
  }

  Future<SequencerStatus> _getSequencerStatus() async {
    return await _backend.sequencerGetStatus();
  }
}
