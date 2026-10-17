part of '../device_service.dart';

extension _DeviceServiceGuidingSequencerControls on DeviceService {
  // Guiding control

  /// Get the live connected guider device ID.
  ///
  /// A profile records configuration, not connection authority. Falling back
  /// to its guider id would dispatch commands to a stale/unopened driver after
  /// a disconnect or host/profile transition.
  String? _getGuiderDeviceId() => _connectedDeviceIdFor(DeviceType.guider);

  /// Start guiding
  Future<void> _startGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    final deviceId = _getGuiderDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No guider connected');
    }

    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.guideSettle,
      description: 'Starting guiding and settling',
      currentStep: 'Calibrating...',
    );

    try {
      await _backend.guiderStartGuiding(
        deviceId: deviceId,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );

      final guiderNotifier = _ref.read(guiderStateProvider.notifier);
      guiderNotifier.setGuiding(true);
    } finally {
      operationsNotifier.completeOperation(
        OperationType.guideSettle,
        operationId: operationId,
      );
    }
  }

  /// Stop guiding
  Future<void> _stopGuiding() async {
    final deviceId = _getGuiderDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No guider connected');
    }

    await _backend.guiderStopGuiding(deviceId: deviceId);

    final guiderNotifier = _ref.read(guiderStateProvider.notifier);
    guiderNotifier.setGuiding(false);
  }

  /// Dither
  Future<void> _dither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    final deviceId = _getGuiderDeviceId();
    if (deviceId == null || deviceId.isEmpty) {
      throw Exception('No guider connected');
    }

    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.dither,
      description: 'Dithering ${amount.toStringAsFixed(1)} px',
      currentStep: 'Moving...',
    );

    try {
      await _backend.guiderDither(
        deviceId: deviceId,
        amount: amount,
        raOnly: raOnly,
        settlePixels: settlePixels,
        settleTime: settleTime,
        settleTimeout: settleTimeout,
      );
    } finally {
      operationsNotifier.completeOperation(
        OperationType.dither,
        operationId: operationId,
      );
    }
  }

  // Sequencer control

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

  Future<void> _loadSequence(String json) async {
    await _backend.sequencerLoadJson(json);
  }

  Future<SequencerStatus> _getSequencerStatus() async {
    return await _backend.sequencerGetStatus();
  }
}
