part of 'demo_backend.dart';

/// The demo guider. PHD2 is a program on an imaging computer, so the demo
/// rig offers its own guider in the guider slot instead.
mixin _DemoGuidingOps on _DemoRigCore {
  void _requireGuider() {
    if (!_guider.connected) throw demoRigNotConnected(DemoDeviceIds.guider);
  }

  Future<bool> isPhd2Running({String host = 'localhost', int port = 4400}) =>
      Future.value(false);

  Future<void> phd2Connect({String host = 'localhost', int port = 4400}) =>
      Future.error(demoRigUnavailable('PHD2; connect the Demo Guider instead'));

  /// PHD2 is never connected on the demo rig.
  Future<void> phd2Disconnect() async {}

  Future<void> guiderLoop() async {
    _requireGuider();
    if (_guider.state == DemoGuiderState.looping) return;
    _cancel(_guideTimer);
    _guideTimer = null;
    _guider.state = DemoGuiderState.looping;
    _emitGuiding(const bridge.GuidingEvent.looping());
  }

  Future<void> guiderStartGuiding({
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _requireGuider();
    if (_guider.guiding) return;
    _guider.stopReason = null;
    _guider.resetStats();
    _guider.state = DemoGuiderState.settling;
    _emitGuiding(const bridge.GuidingEvent.guidingStarted());
    _emitGuiding(const bridge.GuidingEvent.stopReason());
    _emitGuiding(const bridge.GuidingEvent.settling());
    _startGuideSteps();
    _settleAfter(const Duration(seconds: 3));
  }

  void _settleAfter(Duration delay) {
    _after(delay, () {
      if (_guider.state != DemoGuiderState.settling) return;
      _guider.state = DemoGuiderState.guiding;
      final status = _guider.status();
      _emitGuiding(
        bridge.GuidingEvent.settled(
          rms: status.rmsTotal / DemoGuider.pixelScaleArcsec,
        ),
      );
    });
  }

  void _startGuideSteps() {
    _cancel(_guideTimer);
    _guideTimer = _every(const Duration(seconds: 2), (_) {
      if (!_guider.guiding) return;
      final error = _guider.step();
      _emitGuiding(
        bridge.GuidingEvent.correction(
          ra: error.ra,
          dec: error.dec,
          raRaw: error.ra,
          decRaw: error.dec,
        ),
      );
    });
  }

  Future<void> guiderStopGuiding() async {
    _requireGuider();
    _stopGuiding(reason: 'operator');
  }

  @override
  void _stopGuiding({required String? reason}) {
    _cancel(_guideTimer);
    _guideTimer = null;
    final wasActive = _guider.state != DemoGuiderState.stopped;
    _guider.state = DemoGuiderState.stopped;
    _guider.stopReason = reason;
    if (!wasActive) return;
    _emitGuiding(const bridge.GuidingEvent.guidingStopped());
    if (reason != null) {
      _emitGuiding(bridge.GuidingEvent.stopReason(reason: reason));
    }
  }

  Future<void> guiderDither({
    double amount = 5.0,
    bool raOnly = false,
    double settlePixels = 1.0,
    double settleTime = 10.0,
    double settleTimeout = 60.0,
  }) async {
    _requireGuider();
    if (!_guider.guiding) {
      throw const ValidationException(
        message: 'The demo guider is not guiding',
        userMessage: 'Start guiding before dithering',
      );
    }
    _guider.state = DemoGuiderState.settling;
    _emitGuiding(bridge.GuidingEvent.ditherStarted(pixels: amount));
    _after(const Duration(seconds: 1), () {
      _emitGuiding(const bridge.GuidingEvent.ditherCompleted());
    });
    _settleAfter(const Duration(seconds: 3));
  }

  Future<void> guiderSetPaused(bool paused) async {
    _requireGuider();
    if (paused) {
      if (!_guider.guiding) return;
      _guider.state = DemoGuiderState.paused;
      _emitGuiding(const bridge.GuidingEvent.paused());
    } else {
      if (_guider.state != DemoGuiderState.paused) return;
      _guider.state = DemoGuiderState.guiding;
      _emitGuiding(const bridge.GuidingEvent.resumed());
    }
  }

  Future<(double, double)> guiderFindStar() async {
    _requireGuider();
    _emitGuiding(
      bridge.GuidingEvent.starSelected(x: _guider.lockX, y: _guider.lockY),
    );
    return (_guider.lockX, _guider.lockY);
  }

  Future<void> guiderSetLockPosition({
    required double x,
    required double y,
    bool exact = false,
  }) async {
    _requireGuider();
    _guider.lockX = x;
    _guider.lockY = y;
  }

  Future<(double, double)> guiderGetLockPosition() async {
    _requireGuider();
    return (_guider.lockX, _guider.lockY);
  }

  Future<void> guiderDeselectStar() async {
    _requireGuider();
  }

  Future<Phd2Status> guiderGetStatus() async => _guider.status();
}
