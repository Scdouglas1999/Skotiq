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

  Future<void> _startGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _requireConnectedGuider();

    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.guideSettle,
      description: 'Starting guiding and settling',
      currentStep: 'Calibrating...',
    );

    try {
      await _backend.guiderStartGuiding(
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

  Future<void> _stopGuiding() async {
    _requireConnectedGuider();

    await _backend.guiderStopGuiding();

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
    _requireConnectedGuider();

    final operationsNotifier = _ref.read(activeOperationsProvider.notifier);
    final operationId = operationsNotifier.startOperation(
      type: OperationType.dither,
      description: 'Dithering ${amount.toStringAsFixed(1)} px',
      currentStep: 'Moving...',
    );

    try {
      await _backend.guiderDither(
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
