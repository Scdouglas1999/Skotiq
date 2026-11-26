import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_star_field.dart';
import 'package:skotiq_core/src/errors/skotiq_exception.dart';

final _start = DateTime.utc(2026, 11, 26, 3);

/// A demo backend on a fake clock, with a small camera, a frame renderer that
/// runs inline and a scratch folder of the test's own.
({DemoBackend backend, List<SkotiqEvent> events}) _demo(
  FakeAsync async,
  Directory scratch,
) {
  final clock = async.getClock(_start);
  final backend = DemoBackend(
    latitudeDeg: 40,
    longitudeDeg: -105,
    now: clock.now,
    renderFrame: (request) async => renderDemoFrame(request),
    scratchDirectory: () async => scratch,
    cameraWidth: 160,
    cameraHeight: 120,
  );
  final events = <SkotiqEvent>[];
  backend.eventStream.listen(events.add);
  return (backend: backend, events: events);
}

Future<void> _connect(
  FakeAsync async,
  DemoBackend backend,
  DeviceType type,
  String id,
) {
  final done = backend.connectDevice(type, id);
  async.elapse(const Duration(milliseconds: 400));
  return done;
}

Matcher get _unavailable => throwsA(
  isA<SkotiqException>().having(
    (e) => e.userMessage,
    'userMessage',
    'Not available in the demo rig',
  ),
);

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('demo_backend_test_');
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('discovery offers a demo device in every slot', () {
    fakeAsync((async) {
      final (:backend, events: _) = _demo(async, scratch);
      final found = <DeviceType, List<DeviceInfo>>{};
      for (final type in [
        DeviceType.camera,
        DeviceType.mount,
        DeviceType.focuser,
        DeviceType.filterWheel,
        DeviceType.rotator,
        DeviceType.guider,
        DeviceType.weather,
        DeviceType.safetyMonitor,
      ]) {
        backend.discoverDevices(type).then((d) => found[type] = d);
      }
      async.flushMicrotasks();
      expect(found.length, 8);
      for (final devices in found.values) {
        expect(devices, isNotEmpty);
        expect(devices.every((d) => d.name.startsWith('Demo ')), isTrue);
        expect(
          devices.every((d) => d.driverType == DriverType.simulator),
          isTrue,
        );
      }
      expect(found[DeviceType.camera]!.map((d) => d.name), [
        'Demo Camera',
        'Demo Guide Camera',
      ]);
      backend.dispose();
    });
  });

  test('connect and disconnect report the state and the events', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.mount, DemoDeviceIds.mount);
      final connected = <DeviceInfo>[];
      backend.getConnectedDevices().then(connected.addAll);
      async.flushMicrotasks();
      expect(connected.map((d) => d.id), [DemoDeviceIds.mount]);
      final connectEvent = events.single;
      expect(connectEvent.eventType, 'Connected');
      expect(connectEvent.data['device_id'], DemoDeviceIds.mount);
      expect(equipmentEventOf(connectEvent), isNotNull);

      backend.disconnectDevice(DeviceType.mount, DemoDeviceIds.mount);
      async.flushMicrotasks();
      expect(events.last.eventType, 'Disconnected');
      MountStatus? status;
      backend.getMountStatus(DemoDeviceIds.mount).then((s) => status = s);
      async.flushMicrotasks();
      expect(status!.connected, isFalse);
      backend.dispose();
    });
  });

  test('the cooler cools toward its setpoint over time', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.camera, DemoDeviceIds.camera);
      CameraStatus? status;
      void read() {
        backend.getCameraStatus(DemoDeviceIds.camera).then((s) => status = s);
        async.flushMicrotasks();
      }

      read();
      expect(status!.sensorTemp, closeTo(15, 0.01));
      backend.cameraSetCooling(
        deviceId: DemoDeviceIds.camera,
        enabled: true,
        targetTemp: -10,
      );
      async.elapse(const Duration(seconds: 10));
      read();
      expect(status!.sensorTemp, closeTo(10, 0.1));
      expect(status!.coolerOn, isTrue);
      expect(status!.coolerPower, greaterThan(0));
      async.elapse(const Duration(seconds: 60));
      read();
      expect(status!.sensorTemp, closeTo(-10, 0.01));
      expect(
        events.map((e) => e.eventType),
        containsAllInOrder(['CameraCoolingStarted', 'CameraCoolingReached']),
      );
      backend.dispose();
    });
  });

  test('a slew takes a few seconds and ends where it was sent', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.mount, DemoDeviceIds.mount);
      MountStatus? status;
      void read() {
        backend.getMountStatus(DemoDeviceIds.mount).then((s) => status = s);
        async.flushMicrotasks();
      }

      read();
      expect(status!.parked, isTrue);
      expect(
        backend.mountSlewToCoordinates(DemoDeviceIds.mount, 5.6, -5.4),
        throwsA(isA<ValidationException>()),
      );
      backend.mountUnpark(DemoDeviceIds.mount);
      async.flushMicrotasks();
      GuiderForMove? guider;
      backend
          .mountSlewToCoordinates(DemoDeviceIds.mount, 5.6, -5.4)
          .then((g) => guider = g);
      async.elapse(const Duration(milliseconds: 500));
      expect(guider, GuiderForMove.idle);
      read();
      expect(status!.slewing, isTrue);
      async.elapse(const Duration(seconds: 9));
      read();
      expect(status!.slewing, isFalse);
      expect(status!.tracking, isTrue);
      expect(status!.rightAscension, closeTo(5.6, 0.001));
      expect(status!.declination, closeTo(-5.4, 0.001));
      expect(
        events.map((e) => e.eventType),
        containsAllInOrder(['MountSlewStarted', 'MountSlewCompleted']),
      );

      backend.mountPark(DemoDeviceIds.mount);
      async.elapse(const Duration(seconds: 6));
      read();
      expect(status!.parked, isTrue);
      expect(status!.tracking, isFalse);
      backend.dispose();
    });
  });

  test('the focuser and filter wheel move and report it', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.focuser, DemoDeviceIds.focuser);
      _connect(
        async,
        backend,
        DeviceType.filterWheel,
        DemoDeviceIds.filterWheel,
      );
      backend.focuserMoveTo(DemoDeviceIds.focuser, 31000);
      async.elapse(const Duration(seconds: 2));
      FocuserStatus? focuser;
      backend.getFocuserStatus(DemoDeviceIds.focuser).then((s) => focuser = s);
      async.flushMicrotasks();
      expect(focuser!.position, 31000);
      expect(focuser!.moving, isFalse);

      List<String>? names;
      backend
          .filterWheelGetNames(DemoDeviceIds.filterWheel)
          .then((n) => names = n);
      async.flushMicrotasks();
      expect(names, ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII']);
      var changed = false;
      backend
          .filterWheelSetByName(DemoDeviceIds.filterWheel, 'Ha')
          .then((_) => changed = true);
      async.elapse(const Duration(seconds: 3));
      expect(changed, isTrue);
      FilterWheelStatus? wheel;
      backend
          .getFilterWheelStatus(DemoDeviceIds.filterWheel)
          .then((s) => wheel = s);
      async.flushMicrotasks();
      expect(wheel!.position, 4);
      expect(
        events.map((e) => e.eventType),
        containsAllInOrder([
          'FocuserMoveStarted',
          'FocuserMoveCompleted',
          'FilterChanging',
          'FilterChanged',
        ]),
      );
      backend.dispose();
    });
  });

  test('an exposure ends after its time with a star field', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.camera, DemoDeviceIds.camera);
      var done = false;
      backend
          .cameraStartExposure(
            deviceId: DemoDeviceIds.camera,
            exposureTime: 5,
            frameType: FrameType.light,
          )
          .then((_) => done = true);
      async.elapse(const Duration(seconds: 4));
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(done, isTrue);

      final types = events.map((e) => e.eventType).toList();
      expect(types.first, 'Connected');
      expect(types, contains('ExposureProgress'));
      expect(types.last, 'ExposureComplete');
      final complete = events.last;
      expect(complete.data['device_id'], DemoDeviceIds.camera);
      expect(imagingEventOf(complete), isNotNull);

      CapturedImageResult? image;
      List<int>? raw;
      backend.cameraGetLastImage(DemoDeviceIds.camera).then((i) => image = i);
      backend.getLastRawImageData(DemoDeviceIds.camera).then((r) => raw = r);
      async.flushMicrotasks();
      expect(image!.width, 160);
      expect(image!.height, 120);
      expect(image!.displayData.length, 160 * 120 * 4);
      expect(raw!.length, 160 * 120);
      expect(image!.stats.starCount, greaterThan(0));
      expect(image!.exposureTime, 5);
      expect(
        DateTime.parse(image!.timestamp),
        // Connecting took 400 ms; the timestamp marks the end of the exposure.
        _start.add(const Duration(milliseconds: 5400)),
      );

      backend.dispose();
    });
  });

  test('the same pointing renders the same stars, the noise differs', () {
    DemoFrameRequest request(int frameSeed) => DemoFrameRequest(
      width: 96,
      height: 64,
      exposureSeconds: 10,
      frameKind: 'light',
      fieldSeed: 1234,
      frameSeed: frameSeed,
      starSigmaPx: 2,
      filterThroughput: 1,
      gain: 100,
      offset: 10,
      sensorTempC: -10,
      binning: 1,
    );
    final a = renderDemoFrame(request(1));
    final b = renderDemoFrame(request(1));
    final c = renderDemoFrame(request(2));
    expect(a.raw, b.raw);
    expect(a.raw, isNot(c.raw));
    expect(a.starCount, c.starCount);
  });

  test('an abort ends the exposure with an error and a cancelled event', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.camera, DemoDeviceIds.camera);
      Object? error;
      backend
          .cameraStartExposure(
            deviceId: DemoDeviceIds.camera,
            exposureTime: 30,
            frameType: FrameType.light,
          )
          .catchError((Object e) => error = e);
      async.elapse(const Duration(seconds: 2));
      backend.cameraAbortExposure(DemoDeviceIds.camera);
      async.flushMicrotasks();
      expect(error, isA<SkotiqException>());
      expect(events.last.eventType, 'ExposureCancelled');
      async.elapse(const Duration(seconds: 40));
      expect(
        events.map((e) => e.eventType),
        isNot(contains('ExposureComplete')),
      );
      backend.dispose();
    });
  });

  test('guiding settles and sends corrections; a slew stops it', () {
    fakeAsync((async) {
      final (:backend, :events) = _demo(async, scratch);
      _connect(async, backend, DeviceType.guider, DemoDeviceIds.guider);
      _connect(async, backend, DeviceType.mount, DemoDeviceIds.mount);
      backend.mountUnpark(DemoDeviceIds.mount);
      backend.guiderStartGuiding();
      async.elapse(const Duration(seconds: 7));
      Phd2Status? status;
      backend.guiderGetStatus().then((s) => status = s);
      async.flushMicrotasks();
      expect(status!.state, 'Guiding');
      expect(events.map((e) => e.eventType), contains('GuideStep'));
      expect(guidingEventOf(events.last), isNotNull);

      GuiderForMove? guider;
      backend
          .mountSlewToCoordinates(DemoDeviceIds.mount, 1, 20)
          .then((g) => guider = g);
      async.flushMicrotasks();
      expect(guider, GuiderForMove.stopped);
      backend.guiderGetStatus().then((s) => status = s);
      async.flushMicrotasks();
      expect(status!.state, 'Stopped');
      backend.dispose();
    });
  });

  test('what the demo rig does not do fails, never a fake success', () {
    fakeAsync((async) {
      final (:backend, events: _) = _demo(async, scratch);
      final SkotiqBackend contract = backend;
      expect(contract.sequencerStart(), _unavailable);
      expect(contract.getProfiles(), _unavailable);
      expect(contract.depthLockStatus(), _unavailable);
      expect(contract.phd2Connect(), _unavailable);
      expect(contract.discoverAlpacaAtAddress('10.0.0.2', 11111), _unavailable);
      expect(
        () => contract.autoStretchImage(width: 1, height: 1, data: const [0]),
        _unavailable,
      );
      async.flushMicrotasks();
      backend.dispose();
    });
  });

  test('a frame of a device that is not connected is refused', () {
    fakeAsync((async) {
      final (:backend, events: _) = _demo(async, scratch);
      expect(
        backend.cameraStartExposure(
          deviceId: DemoDeviceIds.camera,
          exposureTime: 1,
          frameType: FrameType.light,
        ),
        throwsA(isA<SkotiqException>()),
      );
      async.flushMicrotasks();
      backend.dispose();
    });
  });

  test(
    'dispose ends an exposure in flight and removes the scratch folder',
    () async {
      final backend = DemoBackend(
        latitudeDeg: 40,
        longitudeDeg: -105,
        renderFrame: (request) async => renderDemoFrame(request),
        scratchDirectory: () async => scratch,
        cameraWidth: 64,
        cameraHeight: 48,
      );
      await backend.connectDevice(DeviceType.camera, DemoDeviceIds.camera);
      await backend.cameraStartExposure(
        deviceId: DemoDeviceIds.camera,
        exposureTime: 0,
        frameType: FrameType.light,
      );
      final path = await backend.saveScratchFrameFromLastCapture(
        deviceId: DemoDeviceIds.camera,
        name: 'frame',
        headerData: const FitsWriteHeader(
          exposureTime: 0,
          captureTimestamp: '2026-11-26T03:00:00Z',
          frameType: 'Light',
        ),
      );
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length % 2880, 0);
      expect(String.fromCharCodes(bytes.take(30)), startsWith('SIMPLE  ='));
      final pending = backend.cameraStartExposure(
        deviceId: DemoDeviceIds.camera,
        exposureTime: 60,
        frameType: FrameType.light,
      );
      final failed = expectLater(pending, throwsA(isA<SkotiqException>()));
      backend.dispose();
      await failed;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File(path).existsSync(), isFalse);
    },
  );

  test('the default renderer draws the frame on another isolate', () async {
    final backend = DemoBackend(
      latitudeDeg: 40,
      longitudeDeg: -105,
      cameraWidth: 64,
      cameraHeight: 48,
    );
    addTearDown(backend.dispose);
    await backend.connectDevice(DeviceType.camera, DemoDeviceIds.camera);
    await backend.cameraStartExposure(
      deviceId: DemoDeviceIds.camera,
      exposureTime: 0.1,
      frameType: FrameType.light,
    );
    final image = await backend.cameraGetLastImage(DemoDeviceIds.camera);
    expect(image, isNotNull);
    expect(image!.displayData.length, 64 * 48 * 4);
    expect(
      (await backend.getLastRawImageData(DemoDeviceIds.camera)).length,
      64 * 48,
    );
  });
}
