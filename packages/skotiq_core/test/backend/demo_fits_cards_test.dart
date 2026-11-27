// A frame the demo rig saves carries the header keywords the native writer
// puts on a rig's frame, so what reads a rig's frames reads the demo's.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/backend/demo_backend/demo_star_field.dart';

void main() {
  test('a saved demo frame names focus, pointing, optics and site as a rig '
      'frame does', () async {
    final scratch = Directory.systemTemp.createTempSync('demo-cards-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final demo = DemoBackend(
      latitudeDeg: 40,
      longitudeDeg: -105,
      renderFrame: (request) async => renderDemoFrame(request),
      scratchDirectory: () async => scratch,
      cameraWidth: 32,
      cameraHeight: 24,
    );
    addTearDown(demo.dispose);
    await demo.connectDevice(DeviceType.camera, DemoDeviceIds.camera);
    await demo.connectDevice(DeviceType.focuser, DemoDeviceIds.focuser);
    await demo.connectDevice(DeviceType.mount, DemoDeviceIds.mount);
    await demo.cameraStartExposure(
      deviceId: DemoDeviceIds.camera,
      exposureTime: 1,
      frameType: FrameType.light,
    );
    final path = await demo.saveFitsFromLastCapture(
      deviceId: DemoDeviceIds.camera,
      filePath: '${scratch.path}/frame.fits',
      headerData: const FitsWriteHeader(
        exposureTime: 1,
        captureTimestamp: '2026-11-26T03:00:00Z',
        frameType: 'Light',
        focalLength: 530,
        aperture: 106,
        siteLatitude: 40,
        siteLongitude: -105,
      ),
    );

    final bytes = File(path).readAsBytesSync();
    final header = ascii.decode(bytes.sublist(0, 2880 * 2), allowInvalid: true);
    final keys = {
      for (var i = 0; i + 80 <= header.length; i += 80)
        header.substring(i, i + 8).trim(),
    };
    expect(
      keys,
      containsAll(<String>[
        'FOCUSPOS',
        'OBJCTRA',
        'OBJCTDEC',
        'FOCALLEN',
        'APTDIA',
        'SITELAT',
        'SITELONG',
      ]),
    );
    expect(keys, isNot(contains('FOCPOS')));
    expect(RegExp(r"OBJCTRA = '\d\d \d\d \d\d\.\d\d").hasMatch(header), isTrue);
  });
}
