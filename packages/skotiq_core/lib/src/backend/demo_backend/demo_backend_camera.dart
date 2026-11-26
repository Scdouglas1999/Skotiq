part of 'demo_backend.dart';

/// An exposure in flight: the future its start call returns, and the timers
/// that report its progress and end it.
class _ExposureRun {
  _ExposureRun(this.exposure);

  final DemoExposure exposure;
  final Completer<void> done = Completer<void>();
  Timer? progress;
  Timer? end;
}

/// The demo cameras: exposures, the frames they produce, gain, offset and
/// the cooler.
mixin _DemoCameraOps on _DemoRigCore {
  DemoCamera _connectedCamera(String deviceId) {
    final camera = _cameras[deviceId];
    if (camera == null) throw demoRigUnknownDevice(deviceId);
    if (!camera.connected) throw demoRigNotConnected(deviceId);
    return camera;
  }

  /// Starts the exposure and completes when its frame is ready, as a real
  /// camera's start call does on a host.
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    final camera = _connectedCamera(deviceId);
    if (camera.exposure != null) {
      throw DeviceBusyException(
        message: 'Demo camera $deviceId is already exposing',
        userMessage: 'The camera is already exposing',
        deviceId: deviceId,
        currentOperation: 'exposure',
      );
    }
    if (!exposureTime.isFinite || exposureTime < 0 || exposureTime > 3600) {
      throw ValidationException.outOfRange(
        'Exposure time',
        exposureTime,
        0,
        3600,
      );
    }
    if (binX < 1 ||
        binX > DemoCamera.maxBin ||
        binY < 1 ||
        binY > DemoCamera.maxBin) {
      throw ValidationException.outOfRange(
        'Binning',
        '${binX}x$binY',
        1,
        DemoCamera.maxBin,
      );
    }
    if (x != null || y != null || width != null || height != null) {
      throw demoRigUnavailable('subframes');
    }
    if (gain != null) camera.gain = gain.clamp(0, DemoCamera.gainMax);
    if (offset != null) camera.offset = offset.clamp(0, DemoCamera.offsetMax);
    // Binning is square on the demo camera.
    camera.binX = binX;
    camera.binY = binX;

    final exposure = DemoExposure(
      seconds: exposureTime,
      startedAt: _clock(),
      frameType: frameType.name,
    );
    camera.exposure = exposure;
    final run = _ExposureRun(exposure);
    _exposureRuns[deviceId] = run;
    _emitImaging(
      bridge.ImagingEvent.exposureStarted(
        durationSecs: exposureTime,
        frameType: bridge.FrameType.values.byName(frameType.name),
      ),
      deviceId: deviceId,
    );
    run.progress = _every(const Duration(milliseconds: 500), (_) {
      final elapsed =
          _clock().difference(exposure.startedAt).inMicroseconds / 1e6;
      final remaining = (exposureTime - elapsed).clamp(0.0, exposureTime);
      _emitImaging(
        bridge.ImagingEvent.exposureProgress(
          progress: exposureTime <= 0
              ? 1.0
              : (elapsed / exposureTime).clamp(0.0, 1.0),
          remainingSecs: remaining,
        ),
        deviceId: deviceId,
      );
    });
    run.end = _after(
      Duration(microseconds: (exposureTime * 1e6).round()),
      () => unawaited(_finishExposure(camera, run)),
    );
    return run.done.future;
  }

  Future<void> _finishExposure(DemoCamera camera, _ExposureRun run) async {
    _cancel(run.progress);
    final exposure = run.exposure;
    if (exposure.aborted) return;
    final request = _frameRequest(camera, exposure);
    final DemoFrame frame;
    try {
      frame = await _renderFrame(request);
    } on Object catch (error, stackTrace) {
      if (exposure.aborted || _disposed) return;
      camera.exposure = null;
      _exposureRuns.remove(camera.deviceId);
      _emitImaging(
        bridge.ImagingEvent.exposureFailed(error: '$error'),
        deviceId: camera.deviceId,
      );
      run.done.completeError(error, stackTrace);
      return;
    }
    if (exposure.aborted || _disposed) return;
    camera.lastFrame = DemoCapturedFrame(
      frame: frame,
      endedAt: exposure.endsAt,
      exposureSeconds: exposure.seconds,
    );
    camera.exposure = null;
    _exposureRuns.remove(camera.deviceId);
    _emitImaging(
      const bridge.ImagingEvent.exposureProgress(
        progress: 1.0,
        remainingSecs: 0,
      ),
      deviceId: camera.deviceId,
    );
    _emitImaging(
      const bridge.ImagingEvent.exposureComplete(success: true),
      deviceId: camera.deviceId,
    );
    run.done.complete();
  }

  DemoFrameRequest _frameRequest(DemoCamera camera, DemoExposure exposure) {
    final t = _clock();
    final isMain = camera.deviceId == DemoDeviceIds.camera;
    // The same pointing shows the same stars; a slew shows new ones.
    var fieldSeed = isMain ? 0x51f15e : 0x2c1b3d;
    if (_mount.connected) {
      final pointing = _mount.position();
      final raKey = (pointing.raHours * 60).round();
      final decKey = (pointing.decDeg * 4).round();
      fieldSeed = (raKey * 73856093) ^ (decKey * 19349663) ^ fieldSeed;
    }
    return DemoFrameRequest(
      width: camera.sensorWidth ~/ camera.binX,
      height: camera.sensorHeight ~/ camera.binY,
      exposureSeconds: exposure.seconds,
      frameKind: exposure.frameType,
      fieldSeed: fieldSeed & 0x7fffffff,
      frameSeed: ++_frameCounter,
      starSigmaPx: isMain && _focuser.connected ? _focuser.starSigmaAt(t) : 1.8,
      filterThroughput: isMain && _filterWheel.connected
          ? _filterWheel.throughputAt(t)
          : 1.0,
      gain: camera.gain,
      offset: camera.offset,
      sensorTempC: camera.sensorTempAt(t),
      binning: camera.binX,
    );
  }

  Future<void> cameraAbortExposure(String deviceId) async {
    _abortExposure(_connectedCamera(deviceId), notify: true);
  }

  void _abortExposure(DemoCamera camera, {required bool notify}) {
    final run = _exposureRuns.remove(camera.deviceId);
    camera.exposure = null;
    if (run == null) return;
    run.exposure.aborted = true;
    _cancel(run.progress);
    _cancel(run.end);
    if (notify) {
      _emitImaging(
        const bridge.ImagingEvent.exposureCancelled(),
        deviceId: camera.deviceId,
      );
    }
    if (!run.done.isCompleted) {
      run.done.completeError(
        SkotiqException(
          category: BackendErrorCategory.imaging,
          message: 'Exposure cancelled',
          userMessage: 'Exposure cancelled',
          deviceId: camera.deviceId,
        ),
      );
    }
  }

  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    final last = _connectedCamera(deviceId).lastFrame;
    if (last == null) return null;
    final frame = last.frame;
    return CapturedImageResult(
      width: frame.width,
      height: frame.height,
      displayData: frame.displayRgba,
      histogram: frame.histogram,
      stats: ImageStatsResult(
        min: frame.min,
        max: frame.max,
        mean: frame.mean,
        median: frame.median,
        stdDev: frame.stdDev,
        hfr: frame.hfr,
        fwhm: frame.fwhm,
        eccentricity: frame.hfr == null ? null : 0.12,
        starCount: frame.starCount,
      ),
      exposureTime: last.exposureSeconds,
      timestamp: last.endedAt.toIso8601String(),
    );
  }

  Future<List<int>> getLastRawImageData(String deviceId) async {
    final last = _connectedCamera(deviceId).lastFrame;
    return last == null ? const <int>[] : last.frame.raw;
  }

  Future<void> clearDeviceImage(String deviceId) async {
    final camera = _cameras[deviceId];
    if (camera == null) throw demoRigUnknownDevice(deviceId);
    camera.lastFrame = null;
  }

  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    final camera = _connectedCamera(deviceId);
    if (!camera.canCool) throw demoRigUnavailable('cooling the guide camera');
    if (targetTemp != null && !targetTemp.isFinite) {
      throw ValidationException.outOfRange(
        'Target temperature',
        targetTemp,
        DemoCamera.coolestC,
        demoRigAmbientC,
      );
    }
    final t = _clock();
    camera.setCooler(on: enabled, targetC: targetTemp, at: t);
    if (!enabled) {
      _emitEquipment(
        bridge.EquipmentEvent.cameraWarmingStarted(deviceId: deviceId),
        deviceId: deviceId,
      );
      return;
    }
    _emitEquipment(
      bridge.EquipmentEvent.cameraCoolingStarted(
        deviceId: deviceId,
        targetTemp: camera.targetTempC,
      ),
      deviceId: deviceId,
    );
    final target = camera.targetTempC;
    _after(camera.timeToGoalFrom(t), () {
      if (!camera.connected || !camera.coolerOn) return;
      if ((camera.targetTempC - target).abs() > 1e-9) return;
      _emitEquipment(
        bridge.EquipmentEvent.cameraCoolingReached(
          deviceId: deviceId,
          temperature: camera.sensorTempAt(_clock()),
        ),
        deviceId: deviceId,
      );
    });
  }

  /// Nothing is ever kept back: every demo frame downloads.
  Future<List<RetainedCapture>> cameraRetainedCaptures() async =>
      const <RetainedCapture>[];

  Future<void> cameraSetGain(String deviceId, int gain) async {
    final camera = _connectedCamera(deviceId);
    if (gain < 0 || gain > DemoCamera.gainMax) {
      throw ValidationException.outOfRange('Gain', gain, 0, DemoCamera.gainMax);
    }
    camera.gain = gain;
  }

  Future<void> cameraSetOffset(String deviceId, int offset) async {
    final camera = _connectedCamera(deviceId);
    if (offset < 0 || offset > DemoCamera.offsetMax) {
      throw ValidationException.outOfRange(
        'Offset',
        offset,
        0,
        DemoCamera.offsetMax,
      );
    }
    camera.offset = offset;
  }

  /// A demo camera has no maker to recommend settings, so it recommends none.
  Future<CameraRecommendedSettings> cameraGetRecommendedSettings(
    String deviceId,
  ) async {
    _connectedCamera(deviceId);
    return const CameraRecommendedSettings(
      notes: 'The demo camera has no recommended settings.',
    );
  }

  Future<CameraStatus> getCameraStatus(String deviceId) async {
    final camera = _cameras[deviceId];
    if (camera == null) throw demoRigUnknownDevice(deviceId);
    return camera.statusAt(_clock());
  }

  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async {
    final camera = _cameras[deviceId];
    if (camera == null || !camera.connected) return null;
    return camera.capabilitiesAt(_clock());
  }
}
