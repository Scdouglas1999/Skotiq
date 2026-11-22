import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_desktop/headless_api/handlers/auxiliary_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/dome_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/imaging_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/post_session_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';
import 'package:skotiq_desktop/headless_api/job_manager.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_remote_protocol/wire.dart';

import 'handler_test_helpers.dart';

/// What the host answers on the dome, switch, cover, post-session, FITS and
/// secondary-rig routes, and which native calls each answer made, pinned in
/// `fixtures/accessory_native_replies.json`.
///
/// The native library is replaced at its own boundary ([bridge.RustLibApi]),
/// so a row passes through whatever Dart sits between a handler and the
/// bridge. The replies are published (OpenAPI, the dashboard, tools, rig
/// scripts): the fixture is the contract. `SKOTIQ_RECORD_REPLIES=1` rewrites
/// it.
final _fixture = File(
  'test/headless_api/fixtures/accessory_native_replies.json',
);

typedef _Script = Map<String, Function>;

/// The native library: answers each call from the row's script and records
/// the call with its arguments.
class _Native implements bridge.RustLibApi {
  _Script script = {};
  final List<Map<String, Object?>> calls = [];

  static String _name(Symbol symbol) {
    final raw = RegExp(r'Symbol\("(.*)"\)').firstMatch('$symbol')!.group(1)!;
    return raw.substring(raw.lastIndexOf('Api') + 3);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = _name(invocation.memberName);
    calls.add({
      'fn': name,
      'args': {
        for (final MapEntry(:key, :value) in invocation.namedArguments.entries)
          _name2(key): _plain(value),
      },
    });
    final answer = script[name];
    if (answer == null) {
      return Future<Never>.error(StateError('unscripted native call $name'));
    }
    return (answer as dynamic)();
  }

  static String _name2(Symbol symbol) =>
      RegExp(r'Symbol\("(.*)"\)').firstMatch('$symbol')!.group(1)!;
}

Object? _plain(Object? value) => switch (value) {
  null || bool() || num() || String() => value,
  List() => [for (final v in value) _plain(v)],
  bridge.SecondaryRigConfigApi() => {
    'cameraId': value.cameraId,
    'exposureSecs': value.exposureSecs,
    'gain': value.gain,
    'offset': value.offset,
    'binX': value.binX,
    'binY': value.binY,
    'frameCount': value.frameCount,
    'filterName': value.filterName,
    'targetTempC': value.targetTempC,
    'rigLabel': value.rigLabel,
    'cameraMake': value.cameraMake,
    'cameraModel': value.cameraModel,
    'telescopeName': value.telescopeName,
    'telescopeFocalLengthMm': value.telescopeFocalLengthMm,
    'telescopeApertureMm': value.telescopeApertureMm,
    'saveBasePath': value.saveBasePath,
    'saveTo': value.saveTo,
    'ditherMaxWaitSecs': value.ditherMaxWaitSecs,
    'inFlightPolicy': value.inFlightPolicy,
    'targetName': value.targetName,
    'targetRaHours': value.targetRaHours,
    'targetDecDegrees': value.targetDecDegrees,
    'observerName': value.observerName,
    'siteLatitudeDeg': value.siteLatitudeDeg,
    'siteLongitudeDeg': value.siteLongitudeDeg,
    'siteElevationM': value.siteElevationM,
  },
  _ => '$value',
};

final _native = _Native();

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// The host's own backend, with the connected-device list a row sets.
class _HostBackend extends FfiBackend {
  _HostBackend(this.connected)
    : super(nativeEvents: () => const Stream.empty());

  final List<DeviceInfo> connected;

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => connected;
}

class _FixedClock implements Clock {
  static final _at = DateTime.utc(2026, 11, 22, 3, 4, 5);

  @override
  DateTime now() => _at;

  @override
  DateTime nowUtc() => _at;

  @override
  Duration get utcOffset => Duration.zero;

  @override
  DateTime fromUtc(DateTime utc) => utc;
}

const _dome = DeviceInfo(
  id: 'dome-1',
  name: 'Roof',
  deviceType: DeviceType.dome,
  driverType: DriverType.alpaca,
  description: '',
  driverVersion: '1',
);
const _switch = DeviceInfo(
  id: 'switch-1',
  name: 'Power box',
  deviceType: DeviceType.switch_,
  driverType: DriverType.alpaca,
  description: '',
  driverVersion: '1',
);
const _switch2 = DeviceInfo(
  id: 'switch-2',
  name: 'Dew box',
  deviceType: DeviceType.switch_,
  driverType: DriverType.alpaca,
  description: '',
  driverVersion: '1',
);
const _cover = DeviceInfo(
  id: 'cover-1',
  name: 'Flip-flat',
  deviceType: DeviceType.coverCalibrator,
  driverType: DriverType.alpaca,
  description: '',
  driverVersion: '1',
);

bridge.DomeCapabilities _domeCaps({
  bool all = true,
  bridge.ShutterStatus? shutter = bridge.ShutterStatus.closing,
}) => bridge.DomeCapabilities(
  canSetAzimuth: all,
  canPark: all,
  canFindHome: all,
  canSetShutter: all,
  canSyncAzimuth: all,
  azimuth: all ? 182.5 : null,
  slewing: all,
  atHome: !all,
  atPark: all,
  shutterStatus: shutter,
  canSlave: all,
  slaved: !all,
  canAbort: all,
);

bridge.DomeStatus _domeStatus({
  bool connected = true,
  bridge.ShutterState shutter = bridge.ShutterState.open,
  bool canSetShutter = true,
}) => bridge.DomeStatus(
  connected: connected,
  azimuth: 90.25,
  altitude: null,
  shutterStatus: shutter,
  slewing: true,
  atHome: false,
  atPark: true,
  canSetAltitude: false,
  canSetAzimuth: true,
  canSetShutter: canSetShutter,
  canSlave: true,
  isSlaved: false,
);

final _switchCaps = bridge.SwitchCapabilities(
  switchCount: 3,
  switches: const [
    bridge.SwitchInfo(
      index: 0,
      name: 'Mount',
      description: '12 V mount',
      isBoolean: true,
      minValue: 0,
      maxValue: 1,
      step: 1,
      canWrite: true,
      value: 1,
    ),
    bridge.SwitchInfo(
      index: 1,
      name: 'Dew A',
      description: 'PWM heater',
      isBoolean: false,
      minValue: 0,
      maxValue: 100,
      step: 1,
      canWrite: true,
      value: 40,
    ),
    bridge.SwitchInfo(
      index: 2,
      name: 'Sensor',
      description: 'read only',
      isBoolean: false,
      minValue: -10,
      maxValue: 10,
      step: 0.5,
      canWrite: false,
      value: 0,
    ),
  ],
);

bridge.CoverCalibratorStatus _coverStatus({
  bridge.CoverState cover = bridge.CoverState.open,
  bridge.CalibratorState calibrator = bridge.CalibratorState.ready,
  bool connected = true,
}) => bridge.CoverCalibratorStatus(
  connected: connected,
  coverState: cover,
  calibratorState: calibrator,
  brightness: 77,
  maxBrightness: 255,
);

const _nativeDown = bridge.SkotiqError.notConnected('dome-1');
const _nativeBusy = bridge.SkotiqError.deviceBusy(
  deviceId: 'dome-1',
  currentOperation: 'slewing',
);

/// One pinned exchange: the request, the devices connected, and what the
/// native library answers.
class _Row {
  const _Row(
    this.handler,
    this.method,
    this.path, {
    this.body,
    this.devices = const [_dome, _switch, _switch2, _cover],
    this.script = const {},
  });

  final String handler;
  final String method;
  final String path;
  final Object? body;
  final List<DeviceInfo> devices;
  final _Script script;
}

Future<Never> _fails(Object error) => Future<Never>.error(error);

final Map<String, _Row> _rows = {
  // Dome commands.
  for (final (route, capability) in [
    ('open', 'canSetShutter'),
    ('close', 'canSetShutter'),
    ('park', 'canPark'),
    ('home', 'canFindHome'),
    ('halt', 'canAbort'),
  ]) ...{
    'dome.$route.ok': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: {'deviceId': 'dome-1'},
      script: {
        'GetDomeCapabilities': () async => _domeCaps(),
        'DomeOpenShutter': () async {},
        'DomeCloseShutter': () async {},
        'DomePark': () async {},
        'DomeFindHome': () async {},
        'DomeAbortSlew': () async {},
      },
    ),
    'dome.$route.unsupported_$capability': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: {'deviceId': 'dome-1'},
      script: {'GetDomeCapabilities': () async => _domeCaps(all: false)},
    ),
    'dome.$route.not_connected': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: {'deviceId': 'dome-9'},
    ),
    'dome.$route.no_device_id': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: const <String, Object?>{},
    ),
    'dome.$route.capabilities_fail': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: {'deviceId': 'dome-1'},
      script: {'GetDomeCapabilities': () => _fails(_nativeDown)},
    ),
    'dome.$route.command_busy': _Row(
      'dome',
      'POST',
      '/api/dome/$route',
      body: {'deviceId': 'dome-1'},
      script: {
        'GetDomeCapabilities': () async => _domeCaps(),
        'DomeOpenShutter': () => _fails(_nativeBusy),
        'DomeCloseShutter': () => _fails(_nativeBusy),
        'DomePark': () => _fails(_nativeBusy),
        'DomeFindHome': () => _fails(_nativeBusy),
        'DomeAbortSlew': () => _fails(_nativeBusy),
      },
    ),
  },
  'dome.slew.ok': _Row(
    'dome',
    'POST',
    '/api/dome/slew',
    body: {'deviceId': 'dome-1', 'azimuth': 271.5},
    script: {
      'GetDomeCapabilities': () async => _domeCaps(),
      'DomeSlewToAzimuth': () async {},
    },
  ),
  'dome.slew.unsupported': _Row(
    'dome',
    'POST',
    '/api/dome/slew',
    body: {'deviceId': 'dome-1', 'azimuth': 271.5},
    script: {'GetDomeCapabilities': () async => _domeCaps(all: false)},
  ),
  'dome.slew.out_of_range': _Row(
    'dome',
    'POST',
    '/api/dome/slew',
    body: {'deviceId': 'dome-1', 'azimuth': 360},
  ),
  'dome.slew.not_connected': _Row(
    'dome',
    'POST',
    '/api/dome/slew',
    body: {'deviceId': 'dome-9', 'azimuth': 10},
  ),
  'dome.slew.command_fail': _Row(
    'dome',
    'POST',
    '/api/dome/slew',
    body: {'deviceId': 'dome-1', 'azimuth': 10},
    script: {
      'GetDomeCapabilities': () async => _domeCaps(),
      'DomeSlewToAzimuth': () =>
          _fails(const bridge.SkotiqError.timeout('slew')),
    },
  ),
  'dome.sync.enable': _Row(
    'dome',
    'POST',
    '/api/dome/sync',
    body: {'deviceId': 'dome-1'},
    script: {
      'GetDomeCapabilities': () async => _domeCaps(),
      'DomeSetSlaved': () async {},
    },
  ),
  'dome.sync.disable': _Row(
    'dome',
    'POST',
    '/api/dome/sync',
    body: {'deviceId': 'dome-1', 'enable': false},
    script: {
      'GetDomeCapabilities': () async => _domeCaps(),
      'DomeSetSlaved': () async {},
    },
  ),
  'dome.sync.unsupported': _Row(
    'dome',
    'POST',
    '/api/dome/sync',
    body: {'deviceId': 'dome-1'},
    script: {'GetDomeCapabilities': () async => _domeCaps(all: false)},
  ),
  'dome.sync.bad_enable': _Row(
    'dome',
    'POST',
    '/api/dome/sync',
    body: {'deviceId': 'dome-1', 'enable': 'yes'},
    script: {
      'GetDomeCapabilities': () async => _domeCaps(),
      'DomeSetSlaved': () async {},
    },
  ),
  'dome.status.ok': _Row(
    'dome',
    'GET',
    '/api/dome/status?deviceId=dome-1',
    script: {'GetDomeStatus': () async => _domeStatus()},
  ),
  for (final shutter in bridge.ShutterState.values)
    'dome.status.shutter_${shutter.name}': _Row(
      'dome',
      'GET',
      '/api/dome/status?deviceId=dome-1',
      script: {'GetDomeStatus': () async => _domeStatus(shutter: shutter)},
    ),
  'dome.status.no_shutter': _Row(
    'dome',
    'GET',
    '/api/dome/status?deviceId=dome-1',
    script: {
      'GetDomeStatus': () async => _domeStatus(
        canSetShutter: false,
        shutter: bridge.ShutterState.closed,
      ),
    },
  ),
  'dome.status.reports_disconnected': _Row(
    'dome',
    'GET',
    '/api/dome/status?deviceId=dome-1',
    script: {'GetDomeStatus': () async => _domeStatus(connected: false)},
  ),
  'dome.status.no_device_id': const _Row('dome', 'GET', '/api/dome/status'),
  'dome.status.not_connected': const _Row(
    'dome',
    'GET',
    '/api/dome/status?deviceId=dome-9',
  ),
  'dome.status.native_fail': _Row(
    'dome',
    'GET',
    '/api/dome/status?deviceId=dome-1',
    script: {'GetDomeStatus': () => _fails(_nativeDown)},
  ),
  'dome.capabilities.ok': _Row(
    'dome',
    'GET',
    '/api/dome/capabilities?deviceId=dome-1',
    script: {'GetDomeCapabilities': () async => _domeCaps()},
  ),
  'dome.capabilities.none': _Row(
    'dome',
    'GET',
    '/api/dome/capabilities?deviceId=dome-1',
    script: {
      'GetDomeCapabilities': () async => _domeCaps(all: false, shutter: null),
    },
  ),
  for (final shutter in bridge.ShutterStatus.values)
    'dome.capabilities.shutter_${shutter.name}': _Row(
      'dome',
      'GET',
      '/api/dome/capabilities?deviceId=dome-1',
      script: {'GetDomeCapabilities': () async => _domeCaps(shutter: shutter)},
    ),
  'dome.capabilities.no_device_id': const _Row(
    'dome',
    'GET',
    '/api/dome/capabilities',
  ),
  'dome.capabilities.not_connected': const _Row(
    'dome',
    'GET',
    '/api/dome/capabilities?deviceId=dome-9',
  ),
  'dome.capabilities.native_fail': _Row(
    'dome',
    'GET',
    '/api/dome/capabilities?deviceId=dome-1',
    script: {'GetDomeCapabilities': () => _fails(_nativeDown)},
  ),

  // Switches.
  'switch.status.none_connected': const _Row(
    'aux',
    'GET',
    '/api/switch/status',
    devices: [_dome],
  ),
  'switch.status.all': _Row(
    'aux',
    'GET',
    '/api/switch/status',
    script: {
      'GetSwitchCapabilities': () {
        final failSecond = _native.calls
            .where((c) => c['fn'] == 'GetSwitchCapabilities')
            .any((c) => (c['args'] as Map)['deviceId'] == 'switch-2');
        return failSecond
            ? _fails(const bridge.SkotiqError.timeout('switch-2'))
            : Future.value(_switchCaps);
      },
      'SwitchGetValue': () async => 1.0,
    },
  ),
  'switch.status.one': _Row(
    'aux',
    'GET',
    '/api/switch/status?deviceId=switch-1',
    script: {
      'GetSwitchCapabilities': () async => _switchCaps,
      'SwitchGetValue': () {
        final reads = _native.calls.where((c) => c['fn'] == 'SwitchGetValue');
        return switch (reads.length) {
          1 => Future.value(0.4),
          2 => Future.value(55.0),
          _ => _fails(const bridge.SkotiqError.operationFailed('no read')),
        };
      },
    },
  ),
  'switch.status.one_capabilities_fail': _Row(
    'aux',
    'GET',
    '/api/switch/status?deviceId=switch-1',
    script: {'GetSwitchCapabilities': () => _fails(_nativeDown)},
  ),
  'switch.status.not_connected': const _Row(
    'aux',
    'GET',
    '/api/switch/status?deviceId=switch-9',
  ),
  'switch.set.bool': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 0, 'value': true},
    script: {'SwitchGetMax': () async => 3, 'SwitchSetState': () async {}},
  ),
  'switch.set.number': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 1, 'value': 42},
    script: {'SwitchGetMax': () async => 3, 'SwitchSetValue': () async {}},
  ),
  'switch.set.string': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 1, 'value': 'on'},
    script: {'SwitchGetMax': () async => 3},
  ),
  'switch.set.no_value': const _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 1},
  ),
  'switch.set.out_of_range': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 3, 'value': true},
    script: {'SwitchGetMax': () async => 3},
  ),
  'switch.set.negative': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': -1, 'value': true},
    script: {'SwitchGetMax': () async => 3},
  ),
  'switch.set.not_connected': const _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-9', 'switchId': 0, 'value': true},
  ),
  'switch.set.max_fail': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 0, 'value': true},
    script: {'SwitchGetMax': () => _fails(_nativeDown)},
  ),
  'switch.set.write_fail': _Row(
    'aux',
    'POST',
    '/api/switch/set',
    body: {'deviceId': 'switch-1', 'switchId': 0, 'value': false},
    script: {
      'SwitchGetMax': () async => 3,
      'SwitchSetState': () => _fails(_nativeBusy),
    },
  ),

  // Cover calibrator.
  'cover.status.ok': _Row(
    'aux',
    'GET',
    '/api/cover/status?deviceId=cover-1',
    script: {'CoverCalibratorGetStatus': () async => _coverStatus()},
  ),
  for (final cover in bridge.CoverState.values)
    'cover.status.cover_${cover.name}': _Row(
      'aux',
      'GET',
      '/api/cover/status?deviceId=cover-1',
      script: {
        'CoverCalibratorGetStatus': () async => _coverStatus(cover: cover),
      },
    ),
  for (final calibrator in bridge.CalibratorState.values)
    'cover.status.calibrator_${calibrator.name}': _Row(
      'aux',
      'GET',
      '/api/cover/status?deviceId=cover-1',
      script: {
        'CoverCalibratorGetStatus': () async =>
            _coverStatus(calibrator: calibrator, connected: false),
      },
    ),
  'cover.status.no_device_id': const _Row('aux', 'GET', '/api/cover/status'),
  'cover.status.not_connected': const _Row(
    'aux',
    'GET',
    '/api/cover/status?deviceId=cover-9',
  ),
  'cover.status.native_fail': _Row(
    'aux',
    'GET',
    '/api/cover/status?deviceId=cover-1',
    script: {'CoverCalibratorGetStatus': () => _fails(_nativeDown)},
  ),
  for (final (route, body) in [
    ('open', {'deviceId': 'cover-1'}),
    ('close', {'deviceId': 'cover-1'}),
    ('brightness', {'deviceId': 'cover-1', 'brightness': 12}),
    ('calibrator-on', {'deviceId': 'cover-1'}),
    ('calibrator-on', {'deviceId': 'cover-1', 'brightness': 200}),
    ('calibrator-off', {'deviceId': 'cover-1'}),
  ]) ...{
    'cover.$route.ok${body.length}': _Row(
      'aux',
      'POST',
      '/api/cover/$route',
      body: body,
      script: {
        'CoverCalibratorOpenCover': () async {},
        'CoverCalibratorCloseCover': () async {},
        'CoverCalibratorCalibratorOn': () async {},
        'CoverCalibratorCalibratorOff': () async {},
      },
    ),
    'cover.$route.not_connected${body.length}': _Row(
      'aux',
      'POST',
      '/api/cover/$route',
      body: {...body, 'deviceId': 'cover-9'},
    ),
  },

  // Post-session jobs.
  for (final (route, body, native) in [
    (
      'integrate',
      {
        'lightPaths': ['/d/a.fits', '/d/b.fits'],
        'exposuresSec': [60, 60],
        'calibration': <String, Object?>{},
        'settings': {'sigmaHigh': 3.0},
        'output': {'path': '/d/out.fits'},
        'extra': 'kept',
      },
      'IntegrateSession',
    ),
    (
      'drizzle',
      {
        'frames': [
          {'fitsPath': '/d/a.fits', 'weight': 1},
        ],
        'refW': 10,
        'refH': 20,
        'config': {'scale': 2},
        'outputFits': '/d/dz.fits',
      },
      'DrizzleIntegrate',
    ),
    (
      'analyze-night',
      {
        'qualities': [
          {'noise': 1, 'snr': 2},
        ],
        'weights': [1],
        'exposuresS': [300],
      },
      'AnalyzeNight',
    ),
    (
      'build-master-flat',
      {
        'flatPaths': ['/d/f1.fits'],
        'output': '/d/mf.fits',
      },
      'BuildMasterFlat',
    ),
    (
      'color-calibrate',
      {
        'inputFits': '/d/in.fits',
        'outputFits': '/d/cc.fits',
        'channels': 3,
        'matchedStars': <Object?>[],
        'whiteRefBv': 0.65,
      },
      'ColorCalibrate',
    ),
    (
      'detect-stars',
      {'inputFits': '/d/in.fits', 'maxStars': 50},
      'DetectStarsPhotometry',
    ),
    (
      'extract-background',
      {'inputFits': '/d/in.fits', 'outputFits': '/d/bg.fits'},
      'ExtractBackground',
    ),
    (
      'master-accumulate',
      {
        'op': 'add',
        'lightPaths': ['/d/a.fits'],
        'exposuresSec': [120],
      },
      'MasterAccumulate',
    ),
    ('master-accumulate', {'op': 'info', 'path': '/d/acc'}, 'MasterAccumulate'),
  ]) ...{
    'post.$route.ok${body.length}': _Row(
      'post',
      'POST',
      '/api/post-session/$route',
      body: body,
      script: {native: () async => '{"outputPath":"/d/x.fits","n":2}'},
    ),
    'post.$route.native_fail${body.length}': _Row(
      'post',
      'POST',
      '/api/post-session/$route',
      body: body,
      script: {
        native: () =>
            _fails(const bridge.SkotiqError.invalidInput('bad frame list')),
      },
    ),
    'post.$route.non_object${body.length}': _Row(
      'post',
      'POST',
      '/api/post-session/$route',
      body: body,
      script: {native: () async => '[1,2]'},
    ),
  },

  // Host FITS files.
  'imaging.fits_dimensions.ok': _Row(
    'imaging',
    'GET',
    '/api/imaging/fits-dimensions?path=<light>',
    script: {
      'ReadFitsFile': () async => bridge.FitsReadResult(
        width: 640,
        height: 480,
        bitpix: 16,
        displayData: Uint8List(0),
        histogram: Uint32List(0),
        stats: const bridge.ImageStatsResult(
          min: 0,
          max: 1,
          mean: 0.5,
          median: 0.5,
          stdDev: 0.1,
          starCount: 0,
        ),
      ),
    },
  ),
  'imaging.fits_dimensions.native_fail': _Row(
    'imaging',
    'GET',
    '/api/imaging/fits-dimensions?path=<light>',
    script: {
      'ReadFitsFile': () =>
          _fails(const bridge.SkotiqError.ioError('truncated')),
    },
  ),
  'imaging.calibrate.ok': _Row(
    'imaging',
    'POST',
    '/api/imaging/calibrate-file',
    body: {
      'lightPath': '<light>',
      'darkPath': '<light>',
      'outputPath': '<tmp>/out/cal.fits',
    },
    script: {'CalibrateImageFile': () async {}},
  ),
  'imaging.calibrate.native_fail': _Row(
    'imaging',
    'POST',
    '/api/imaging/calibrate-file',
    body: {
      'lightPath': '<light>',
      'flatPath': '<light>',
      'biasPath': '<light>',
      'outputPath': '<tmp>/out/cal.fits',
    },
    script: {
      'CalibrateImageFile': () =>
          _fails(const bridge.SkotiqError.invalidInput('size mismatch')),
    },
  ),

  // Secondary rig.
  'secondary.status.ok': _Row(
    'sequencer',
    'GET',
    '/api/sequencer/secondary-rig',
    script: {
      'SecondaryRigGetStatus': () async => const bridge.SecondaryRigStatusApi(
        armed: true,
        running: true,
        cameraId: 'cam-2',
        rigLabel: 'Wide',
        framesCaptured: 4,
        framesAborted: 1,
        plannedFrames: 20,
        waitingForDither: false,
        exposing: true,
        ditherPending: false,
        forcedProceeds: 2,
        lastError: null,
      ),
    },
  ),
  'secondary.status.native_fail': _Row(
    'sequencer',
    'GET',
    '/api/sequencer/secondary-rig',
    script: {'SecondaryRigGetStatus': () => _fails(_nativeDown)},
  ),
  'secondary.start.minimal': _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/start',
    body: {'cameraId': 'cam-2', 'exposureSecs': 30, 'saveBasePath': '/d/w'},
    script: {'SecondaryRigStart': () async {}},
  ),
  'secondary.start.full': _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/start',
    body: {
      'cameraId': 'cam-2',
      'exposureSecs': 120.5,
      'saveBasePath': '/d/w',
      'gain': 100,
      'offset': 30,
      'binX': 2,
      'binY': 2,
      'frameCount': 12,
      'filterName': 'L',
      'targetTempC': -10,
      'rigLabel': 'Wide',
      'ditherMaxWaitSecs': 45,
      'inFlightPolicy': 'abort_immediately',
      'targetName': 'M 31',
      'targetRaHours': 0.71,
      'targetDecDegrees': 41.27,
      'observerName': 'Owner',
      'siteLatitudeDeg': 45.5,
      'siteLongitudeDeg': -73.6,
      'siteElevationM': 120,
    },
    script: {'SecondaryRigStart': () async {}},
  ),
  'secondary.start.native_fail': _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/start',
    body: {'cameraId': 'cam-2', 'exposureSecs': 30, 'saveBasePath': '/d/w'},
    script: {'SecondaryRigStart': () => _fails(_nativeBusy)},
  ),
  'secondary.start.bad_policy': const _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/start',
    body: {
      'cameraId': 'cam-2',
      'exposureSecs': 30,
      'saveBasePath': '/d/w',
      'inFlightPolicy': 'later',
    },
  ),
  'secondary.stop.ok': _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/stop',
    script: {'SecondaryRigStop': () async {}},
  ),
  'secondary.stop.native_fail': _Row(
    'sequencer',
    'POST',
    '/api/sequencer/secondary-rig/stop',
    script: {'SecondaryRigStop': () => _fails(_nativeDown)},
  ),
};

late Directory _tmp;
late File _light;

String _fill(String text) =>
    text.replaceAll('<light>', _light.path).replaceAll('<tmp>', _tmp.path);

Object? _unfill(Object? value) => switch (value) {
  String() =>
    value.replaceAll(_light.path, '<light>').replaceAll(_tmp.path, '<tmp>'),
  List() => [for (final v in value) _unfill(v)],
  Map() => {for (final e in value.entries) '${e.key}': _unfill(e.value)},
  _ => value,
};

Future<Map<String, Object?>> _run(_Row row) async {
  _native
    ..script = row.script
    ..calls.clear();
  final logs = await Directory('${_tmp.path}/logs').create(recursive: true);
  final logger = LoggingService(
    applicationSupportDirectoryProvider: () async => logs,
    nativeInitWithLogging: ({logDirectory}) {},
    nativeInit: () {},
    currentLogFileProvider: () => null,
  );
  await logger.ensureInitialized();
  addTearDown(logger.dispose);
  final backend = _HostBackend(row.devices);
  final container = createHeadlessTestContainer(
    overrides: [
      loggingServiceProvider.overrideWithValue(logger),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      clockProvider.overrideWithValue(_FixedClock()),
    ],
  );
  addTearDown(container.dispose);
  final jobManager = JobManager(emitEvent: (_) {});
  addTearDown(jobManager.dispose);

  final Map<ApiEndpointKey, Function> routes = switch (row.handler) {
    'dome' => _keyed(DomeHandlers(container).routes),
    'aux' => _keyed(AuxiliaryHandlers(container).routes),
    'post' => _keyed(
      PostSessionHandlers(container, jobManager: jobManager).routes,
    ),
    'imaging' => _keyed(
      ImagingHandlers(container, jobManager: jobManager).routes,
    ),
    'sequencer' => _keyed(SequencerHandlers(container).routes),
    _ => throw ArgumentError(row.handler),
  };
  final uri = Uri.parse('http://localhost${_fill(row.path)}');
  final handler = routes[(row.method, uri.path)];
  if (handler == null) throw StateError('no route ${row.method} ${uri.path}');
  final body = row.body == null ? null : _fill(jsonEncode(row.body));
  final request = Request(row.method, uri, body: body);
  final middleware = errorTranslationMiddleware(
    logError: (_, {fields}) {},
    requestIdFor: (_) => 'test-request-id',
  );
  final response = await middleware(
    (r) async => await (handler as dynamic)(r) as Response,
  )(request);
  final text = await response.readAsString();
  Object? job;
  final decoded = jsonDecode(text);
  if (row.handler == 'post' && decoded is Map && decoded['jobId'] is String) {
    final id = decoded['jobId'] as String;
    for (var i = 0; i < 200; i++) {
      final current = jobManager.get(id);
      if (current != null && current.state.isTerminal) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final done = jobManager.get(id)!;
    job = {
      'state': done.state.wireName,
      'result': done.result,
      'error': done.error,
    };
    decoded['jobId'] = '<job>';
  }
  return _unfill({
        'status': response.statusCode,
        'body': row.handler == 'post' ? jsonEncode(decoded) : text,
        if (job != null) 'job': job,
        'native': List.of(_native.calls),
      })
      as Map<String, Object?>;
}

typedef ApiEndpointKey = (String, String);

Map<ApiEndpointKey, Function> _keyed(Map<ApiEndpoint, Function> routes) => {
  for (final MapEntry(:key, :value) in routes.entries)
    (key.route.method.name.toUpperCase(), key.route.path): value,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  bridge.RustLib.initMock(api: _native);

  final record = Platform.environment['SKOTIQ_RECORD_REPLIES'] == '1';
  final recorded = <String, Object?>{};
  final expected = record
      ? const <String, Object?>{}
      : jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

  setUpAll(() async {
    _tmp = await Directory.systemTemp.createTemp('sk_accessory_pin_');
    _light = File('${_tmp.path}/light.fits')..writeAsStringSync('SIMPLE');
  });
  tearDownAll(() async {
    if (record) {
      _fixture.parent.createSync(recursive: true);
      _fixture.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(recorded)}\n',
      );
    }
    await _tmp.delete(recursive: true);
  });

  test('every pinned exchange has a row and every row a pin', () {
    if (record) return;
    expect(_rows.keys.toSet(), expected.keys.toSet());
  });

  for (final MapEntry(key: id, value: row) in _rows.entries) {
    test(id, () async {
      final reply = await _run(row);
      if (record) {
        recorded[id] = reply;
        return;
      }
      expect(reply, expected[id]);
    });
  }
}
