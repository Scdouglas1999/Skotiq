import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../../errors/skotiq_error.dart' show BackendErrorCategory;
import '../../errors/skotiq_exception.dart'
    show DeviceBusyException, SkotiqException, ValidationException;
import '../../models/backend/backend_types.dart';
import '../../models/equipment/guider_for_move.dart';
import '../../models/imaging/imaging_models.dart' show FrameType;
import '../../utils/logging_service.dart';
import '../bridge_event_codec.dart' show wireEventFromTyped;
import '../skotiq_backend.dart';
import 'demo_devices.dart';
import 'demo_fits.dart';
import 'demo_guider.dart';
import 'demo_mount.dart';
import 'demo_rig_state.dart';
import 'demo_star_field.dart';

export 'demo_devices.dart' show DemoDeviceIds, demoRigFilterNames;

part 'demo_backend_camera.dart';
part 'demo_backend_guiding.dart';
part 'demo_backend_motion.dart';

/// Renders a demo frame. The default runs [renderDemoFrame] on a background
/// isolate; tests pass one that renders inline.
typedef DemoFrameRenderer = Future<DemoFrame> Function(DemoFrameRequest);

Future<DemoFrame> _renderOffUiIsolate(DemoFrameRequest request) =>
    Isolate.run(() => renderDemoFrame(request));

Future<Directory> _defaultScratchDirectory() async {
  final base = await getTemporaryDirectory();
  return Directory(p.join(base.path, 'skotiq_demo_rig'));
}

/// What every part of the demo rig shares: its devices, its clock, and the
/// event stream and timers they report through.
abstract class _DemoRigCore {
  _DemoRigCore({
    required double latitudeDeg,
    required double longitudeDeg,
    required DateTime Function()? now,
    required DemoFrameRenderer? renderFrame,
    required Future<Directory> Function()? scratchDirectory,
    required this.cameraWidth,
    required this.cameraHeight,
  }) : _now = now ?? DateTime.now,
       _renderFrame = renderFrame ?? _renderOffUiIsolate,
       _scratchDirectory = scratchDirectory ?? _defaultScratchDirectory {
    final t = _clock();
    _mount = DemoMount(
      now: _clock,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    _cameras = {
      DemoDeviceIds.camera: DemoCamera(
        deviceId: DemoDeviceIds.camera,
        name: 'Demo Camera',
        sensorWidth: cameraWidth,
        sensorHeight: cameraHeight,
        canCool: true,
        at: t,
      ),
      DemoDeviceIds.guideCamera: DemoCamera(
        deviceId: DemoDeviceIds.guideCamera,
        name: 'Demo Guide Camera',
        sensorWidth: cameraWidth ~/ 2,
        sensorHeight: cameraHeight ~/ 2,
        canCool: false,
        at: t,
      ),
    };
  }

  /// The main camera's sensor size; the guide camera's is half of it.
  final int cameraWidth;
  final int cameraHeight;

  final DateTime Function() _now;
  final DemoFrameRenderer _renderFrame;
  final Future<Directory> Function() _scratchDirectory;

  final _eventController = StreamController<SkotiqEvent>.broadcast();
  final _polarAlignController =
      StreamController<Map<String, dynamic>>.broadcast();
  final Set<Timer> _timers = {};
  bool _disposed = false;
  Directory? _scratch;
  int _frameCounter = 0;

  late final DemoMount _mount;
  late final Map<String, DemoCamera> _cameras;
  final Map<String, _ExposureRun> _exposureRuns = {};
  Timer? _slewTimer;
  Timer? _focuserTimer;
  Timer? _filterTimer;
  Timer? _rotatorTimer;
  final _focuser = DemoFocuser();
  final _filterWheel = DemoFilterWheel();
  final _rotator = DemoRotator();
  final _guider = DemoGuider();
  Timer? _guideTimer;
  bool _weatherConnected = false;
  bool _safetyConnected = false;

  DateTime _clock() => _now().toUtc();

  void _stopGuiding({required String? reason});

  // ---------------------------------------------------------------------------
  // Events and timers.

  void _emit(
    bridge.EventPayload payload, {
    required bridge.EventCategory category,
    String? deviceId,
    bridge.EventSeverity severity = bridge.EventSeverity.info,
  }) {
    if (_disposed) return;
    final t = _clock().millisecondsSinceEpoch;
    final wire = wireEventFromTyped(
      bridge.SkotiqEvent(
        eventId: BigInt.from(t),
        timestamp: t,
        severity: severity,
        category: category,
        payload: payload,
        deviceId: deviceId,
      ),
    );
    // Imaging events carry no device id of their own; the capture service
    // matches a camera's events by this key.
    _eventController.add(
      deviceId == null || wire.data.containsKey('device_id')
          ? wire
          : wire.copyWith(data: {...wire.data, 'device_id': deviceId}),
    );
  }

  void _emitEquipment(bridge.EquipmentEvent event, {String? deviceId}) => _emit(
    bridge.EventPayload.equipment(event),
    category: bridge.EventCategory.equipment,
    deviceId: deviceId,
  );

  void _emitImaging(bridge.ImagingEvent event, {required String deviceId}) =>
      _emit(
        bridge.EventPayload.imaging(event),
        category: bridge.EventCategory.imaging,
        deviceId: deviceId,
      );

  void _emitGuiding(bridge.GuidingEvent event) => _emit(
    bridge.EventPayload.guiding(event),
    category: bridge.EventCategory.guiding,
    deviceId: DemoDeviceIds.guider,
  );

  Timer _after(Duration delay, void Function() action) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      if (!_disposed) action();
    });
    _timers.add(timer);
    return timer;
  }

  Timer _every(Duration period, void Function(Timer) action) {
    final timer = Timer.periodic(period, (t) {
      if (_disposed) {
        t.cancel();
        return;
      }
      action(t);
    });
    _timers.add(timer);
    return timer;
  }

  void _cancel(Timer? timer) {
    if (timer == null) return;
    timer.cancel();
    _timers.remove(timer);
  }
}

/// The demo rig: a simulated set of equipment that runs inside this app, for
/// testing and showing the phone app with no imaging computer.
///
/// Discovery offers one simulated device of each kind an owner uses (main and
/// guide camera, mount, focuser, filter wheel, rotator, guider, weather
/// station and safety monitor). They connect, report their state and move
/// over a few seconds, and the camera takes exposures that end after the
/// requested time with a synthetic star field. The frame is written as a
/// small FITS file so a capture saves as it would on a rig.
///
/// Everything else a host does (sequences, plate solving, autofocus,
/// stacking, the host's data) is answered by [noSuchMethod] with the
/// "Not available in the demo rig" error, never with a made-up result.
class DemoBackend extends _DemoRigCore
    with _DemoCameraOps, _DemoMotionOps, _DemoGuidingOps
    implements SkotiqBackend, EnvironmentalStatusBackend {
  DemoBackend({
    required super.latitudeDeg,
    required super.longitudeDeg,
    super.now,
    super.renderFrame,
    super.scratchDirectory,
    super.cameraWidth = 1024,
    super.cameraHeight = 768,
  });

  // ---------------------------------------------------------------------------
  // Members that are not futures.

  @override
  bool get dispatchPluginNodesLocally => true;

  @override
  Stream<SkotiqEvent> get eventStream => _eventController.stream;

  @override
  Set<DeviceType> get nativeReconnectedDeviceTypes => const {};

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents =>
      _polarAlignController.stream;

  @override
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  }) {
    throw demoRigUnavailable('stretching stacked images');
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final camera in _cameras.values) {
      camera.exposure = null;
    }
    // An exposure still in flight ends with the backend, as it would with
    // a camera that was unplugged.
    for (final run in _exposureRuns.values) {
      run.exposure.aborted = true;
      if (!run.done.isCompleted) {
        run.done.completeError(demoRigNotConnected(DemoDeviceIds.camera));
      }
    }
    _exposureRuns.clear();
    _eventController.close();
    _polarAlignController.close();
    final scratch = _scratch;
    if (scratch != null) {
      unawaited(
        scratch
            .delete(recursive: true)
            .then<void>(
              (_) {},
              onError: (Object e) => Log.warning(
                'Could not remove the demo rig scratch folder '
                '${scratch.path}: $e',
                source: 'DemoBackend',
              ),
            ),
      );
    }
  }

  /// The members [noSuchMethod] has answered, so a test can see which calls
  /// the app makes that the demo rig does not simulate.
  @visibleForTesting
  final Set<String> debugUnavailableCalls = <String>{};

  /// Everything the demo rig does not simulate.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = _memberName(invocation.memberName);
    debugUnavailableCalls.add(name);
    return Future<Never>.error(demoRigUnavailable(name), StackTrace.current);
  }

  static String _memberName(Symbol symbol) {
    final text = symbol.toString();
    final match = RegExp(r'Symbol\("([^"]*)"\)').firstMatch(text);
    return match?.group(1) ?? text;
  }

  // ---------------------------------------------------------------------------
  // Discovery and connection.

  @override
  Future<List<DeviceInfo>> discoverDevices(DeviceType deviceType) async =>
      List.unmodifiable(demoRigDevices[deviceType] ?? const <DeviceInfo>[]);

  @override
  Future<List<DeviceInfo>> discoverIndiAtAddress(String host, int port) =>
      Future.error(demoRigUnavailable('INDI servers'));

  @override
  Future<List<DeviceInfo>> discoverAlpacaAtAddress(String host, int port) =>
      Future.error(demoRigUnavailable('Alpaca servers'));

  /// The demo rig's devices never change, so a rescan finds the same ones.
  @override
  Future<void> rescanDevices() async {}

  @override
  Future<void> connectDevice(
    DeviceType deviceType,
    String deviceId, {
    String? expectedModel,
  }) async {
    final device = demoRigDevice(deviceType, deviceId);
    if (device == null) throw demoRigUnknownDevice(deviceId);
    // A real driver takes a moment to open.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (_disposed) throw demoRigNotConnected(deviceId);
    _setConnected(deviceType, deviceId, true);
    _emitEquipment(
      bridge.EquipmentEvent.connected(
        deviceType: _wireName(deviceType),
        deviceId: deviceId,
        deviceName: device.name,
      ),
      deviceId: deviceId,
    );
  }

  @override
  Future<void> disconnectDevice(DeviceType deviceType, String deviceId) async {
    if (demoRigDevice(deviceType, deviceId) == null) {
      throw demoRigUnknownDevice(deviceId);
    }
    _setConnected(deviceType, deviceId, false);
    _emitEquipment(
      bridge.EquipmentEvent.disconnected(
        deviceType: _wireName(deviceType),
        deviceId: deviceId,
      ),
      deviceId: deviceId,
    );
  }

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => [
    for (final entry in demoRigDevices.entries)
      for (final device in entry.value)
        if (_isConnected(entry.key, device.id)) device,
  ];

  @override
  Future<(int, bool)> getDeviceHealth(String deviceId) async {
    for (final entry in demoRigDevices.entries) {
      for (final device in entry.value) {
        if (device.id == deviceId) {
          return (
            _clock().millisecondsSinceEpoch,
            _isConnected(entry.key, deviceId),
          );
        }
      }
    }
    throw demoRigUnknownDevice(deviceId);
  }

  static String _wireName(DeviceType type) => type.name.toLowerCase();

  bool _isConnected(DeviceType type, String deviceId) => switch (type) {
    DeviceType.camera => _cameras[deviceId]?.connected == true,
    DeviceType.mount => _mount.connected,
    DeviceType.focuser => _focuser.connected,
    DeviceType.filterWheel => _filterWheel.connected,
    DeviceType.rotator => _rotator.connected,
    DeviceType.guider => _guider.connected,
    DeviceType.weather => _weatherConnected,
    DeviceType.safetyMonitor => _safetyConnected,
    _ => false,
  };

  void _setConnected(DeviceType type, String deviceId, bool connected) {
    switch (type) {
      case DeviceType.camera:
        final camera = _cameras[deviceId];
        if (camera == null) return;
        if (!connected) _abortExposure(camera, notify: false);
        camera.connected = connected;
      case DeviceType.mount:
        if (!connected) _mount.abort();
        _mount.connected = connected;
      case DeviceType.focuser:
        if (!connected) _focuser.halt(_clock());
        _focuser.connected = connected;
      case DeviceType.filterWheel:
        _filterWheel.connected = connected;
      case DeviceType.rotator:
        if (!connected) _rotator.halt(_clock());
        _rotator.connected = connected;
      case DeviceType.guider:
        if (!connected) _stopGuiding(reason: null);
        _guider.connected = connected;
      case DeviceType.weather:
        _weatherConnected = connected;
      case DeviceType.safetyMonitor:
        _safetyConnected = connected;
      default:
        return;
    }
  }

  // ---------------------------------------------------------------------------
  // Weather station and safety monitor.

  @override
  Future<HardwareWeatherConditions> getHardwareWeatherConditions(
    String deviceId,
  ) async {
    if (deviceId != DemoDeviceIds.weather) throw demoRigUnknownDevice(deviceId);
    if (!_weatherConnected) throw demoRigNotConnected(deviceId);
    return const HardwareWeatherConditions(
      temperature: demoRigAmbientC - 2.5,
      humidity: 64,
      pressure: 1013,
      cloudCover: 5,
      dewPoint: 6.1,
      windSpeed: 2.2,
      windDirection: 220,
      skyQuality: 20.8,
      skyTemperature: -18,
      rainRate: 0,
    );
  }

  @override
  Future<bool> getHardwareSafetyStatus(String deviceId) async {
    if (deviceId != DemoDeviceIds.safetyMonitor) {
      throw demoRigUnknownDevice(deviceId);
    }
    if (!_safetyConnected) throw demoRigNotConnected(deviceId);
    return true;
  }

  // ---------------------------------------------------------------------------
  // Saving frames.

  /// The folder this demo writes its scratch frames to. It is deleted when
  /// the demo stops, so the frame rows that point into it go too.
  Future<String> scratchFolderPath() async =>
      (_scratch ??= await _scratchDirectory()).path;

  @override
  Future<String> saveScratchFrameFromLastCapture({
    required String deviceId,
    required String name,
    required FitsWriteHeader headerData,
  }) async {
    final dir = _scratch ??= await _scratchDirectory();
    await dir.create(recursive: true);
    final path = p.join(dir.path, p.basename(name));
    await _writeLastFrame(deviceId, path, headerData);
    return path;
  }

  @override
  Future<String> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
    bool keepCameraFile = false,
  }) async {
    await File(filePath).parent.create(recursive: true);
    await _writeLastFrame(deviceId, filePath, headerData);
    return filePath;
  }

  Future<void> _writeLastFrame(
    String deviceId,
    String path,
    FitsWriteHeader header,
  ) async {
    final camera = _connectedCamera(deviceId);
    final last = camera.lastFrame;
    if (last == null) {
      throw demoRigUnavailable('saving before the first exposure');
    }
    final frame = last.frame;
    final t = _clock();
    final start = last.endedAt.subtract(
      Duration(microseconds: (last.exposureSeconds * 1e6).round()),
    );
    final cards = <(String, Object, String?)>[
      ('DATE-OBS', start.toIso8601String(), 'UTC start of exposure'),
      ('EXPTIME', header.exposureTime, 'seconds'),
      ('IMAGETYP', header.frameType, null),
      ('INSTRUME', camera.name, null),
      ('XBINNING', camera.binX, null),
      ('YBINNING', camera.binY, null),
      ('GAIN', camera.gain, null),
      ('OFFSET', camera.offset, null),
      ('XPIXSZ', DemoCamera.pixelSizeUm * camera.binX, 'microns'),
      ('YPIXSZ', DemoCamera.pixelSizeUm * camera.binY, 'microns'),
      if (camera.canCool) ('CCD-TEMP', camera.sensorTempAt(t), 'degrees C'),
      if (header.objectName != null) ('OBJECT', header.objectName!, null),
      if (_filterWheel.connected)
        if (_filterWheel.nameOf(_filterWheel.positionAt(t)) case final name?)
          ('FILTER', name, null),
      // The keywords the native writer uses (frame_header/mod.rs), so a demo
      // frame reads like a rig's.
      if (_focuser.connected) ('FOCUSPOS', _focuser.positionAt(t), 'steps'),
      if (_mount.connected) ...[
        ('RA', _mount.position().raHours * 15.0, 'degrees'),
        ('OBJCTRA', demoSexagesimal(_mount.position().raHours), null),
        ('DEC', _mount.position().decDeg, 'degrees'),
        (
          'OBJCTDEC',
          demoSexagesimal(_mount.position().decDeg, signed: true),
          null,
        ),
      ],
      if (header.focalLength case final focal?) ('FOCALLEN', focal, 'mm'),
      if (header.aperture case final aperture?) ('APTDIA', aperture, 'mm'),
      if (header.telescope != null) ('TELESCOP', header.telescope!, null),
      if (header.observer != null) ('OBSERVER', header.observer!, null),
      if (header.siteLatitude case final lat?) ('SITELAT', lat, 'degrees'),
      if (header.siteLongitude case final long?) ('SITELONG', long, 'degrees'),
      if (header.siteElevation case final elevation?)
        ('SITEELEV', elevation, 'meters'),
    ];
    final bytes = encodeDemoFits(
      width: frame.width,
      height: frame.height,
      samples: frame.raw,
      cards: cards,
    );
    await File(path).writeAsBytes(bytes, flush: true);
  }
}
