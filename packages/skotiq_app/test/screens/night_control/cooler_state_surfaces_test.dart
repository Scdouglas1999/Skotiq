// What every surface that reads the camera's cooler says about one reading:
// Tonight's Camera tab, its equipment summary row and its Before you start
// check, the update gate and the disconnect guard.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/before_you_start_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/equipment_summary_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/services/app_update.dart';
import 'package:skotiq_app/utils/cooled_camera_guard.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_updater/skotiq_updater.dart' show UpdateException;

import 'data/session/session_test_support.dart';

const _connected = DeviceConnectionState.connected;

/// The readings, by name.
final Map<String, CameraStateSnapshot> _readings = {
  'disconnected': const CameraStateSnapshot(
    connectionState: DeviceConnectionState.disconnected,
    temperature: -10,
    coolerOn: true,
  ),
  'warming': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -5,
    coolerOn: true,
    isWarming: true,
  ),
  'cooler not reported': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -9.5,
  ),
  'no temperature': const CameraStateSnapshot(
    connectionState: _connected,
    coolerOn: true,
  ),
  '0.4 off the setpoint': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -9.6,
    coolerOn: true,
  ),
  '0.5 off the setpoint': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -9.5,
    coolerOn: true,
  ),
  '0.6 off the setpoint': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -9.4,
    coolerOn: true,
  ),
  'cooler off, still drawing power': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: 5,
    coolerOn: false,
    coolerPower: 3,
  ),
  'cooler off at the setpoint': const CameraStateSnapshot(
    connectionState: _connected,
    temperature: -9.5,
    coolerOn: false,
  ),
};

/// Per reading: the Camera tab's state, the equipment row's first detail,
/// the Before you start detail, whether the update gate refuses, and whether
/// the disconnect guard asks.
typedef _Answers = ({
  CoolerState panel,
  String? equipment,
  String? check,
  bool updateRefused,
  bool disconnectAsks,
});

final Map<String, _Answers> _expected = {
  'disconnected': (
    panel: CoolerState.notConnected,
    equipment: null,
    check: 'nightSessionDeviceNotConnected',
    updateRefused: false,
    disconnectAsks: false,
  ),
  'warming': (
    panel: CoolerState.warming,
    equipment: 'nightScrCoolingTo',
    check: 'nightSessionCheckCameraCooling',
    updateRefused: true,
    disconnectAsks: true,
  ),
  'cooler not reported': (
    panel: CoolerState.notReported,
    equipment: 'literal',
    check: 'nightSessionCheckCameraAt',
    updateRefused: false,
    disconnectAsks: false,
  ),
  'no temperature': (
    panel: CoolerState.cooling,
    equipment: null,
    check: 'nightSessionCheckConnected',
    updateRefused: true,
    disconnectAsks: true,
  ),
  '0.4 off the setpoint': (
    panel: CoolerState.atSetpoint,
    equipment: 'literal',
    check: 'nightSessionCheckCameraAt',
    updateRefused: true,
    disconnectAsks: true,
  ),
  // Tonight showed "At setpoint" in its Camera tab beside "cooling to" in
  // its equipment row and Before you start for this one reading.
  '0.5 off the setpoint': (
    panel: CoolerState.atSetpoint,
    equipment: 'literal',
    check: 'nightSessionCheckCameraAt',
    updateRefused: true,
    disconnectAsks: true,
  ),
  '0.6 off the setpoint': (
    panel: CoolerState.cooling,
    equipment: 'nightScrCoolingTo',
    check: 'nightSessionCheckCameraCooling',
    updateRefused: true,
    disconnectAsks: true,
  ),
  'cooler off, still drawing power': (
    panel: CoolerState.off,
    equipment: 'literal',
    check: 'nightSessionCheckCameraAt',
    updateRefused: true,
    disconnectAsks: false,
  ),
  'cooler off at the setpoint': (
    panel: CoolerState.off,
    equipment: 'literal',
    check: 'nightSessionCheckCameraAt',
    updateRefused: false,
    disconnectAsks: false,
  ),
};

Future<SessionHarness> _rig(CameraStateSnapshot camera) => sessionHarness(
      overrides: [
        cameraStateProvider.overrideWith((ref) => FixedCamera(ref, camera)),
      ],
    );

/// The camera row's first detail: its key, `literal` for a plain reading, or
/// null when the row has none.
String? _equipmentDetail(SessionHarness h) {
  final row = h
      .read(nightEquipmentProvider)
      .firstWhere((r) => r.kind == EquipmentKind.camera);
  if (row.details.isEmpty) return null;
  final first = row.details.first;
  return first.literal != null ? 'literal' : first.key;
}

String? _checkDetail(SessionHarness h) => h
    .read(nightBeforeYouStartProvider)
    .firstWhere((i) => i.id == ChecklistItemId.camera)
    .detail
    ?.key;

Future<bool> _updateRefused(SessionHarness h) async {
  try {
    await defaultUpdateApplySafetyCheckWithReader(h.container.read);
    return false;
  } on UpdateException {
    return true;
  }
}

void main() {
  for (final MapEntry(key: name, value: camera) in _readings.entries) {
    final want = _expected[name]!;

    test('$name: Tonight, Before you start and the update gate', () async {
      final h = await _rig(camera);
      expect(camera.coolerState, want.panel, reason: 'Camera tab');
      if (camera.connectionState == _connected) {
        expect(_equipmentDetail(h), want.equipment, reason: 'equipment row');
      }
      expect(_checkDetail(h), want.check, reason: 'Before you start');
      expect(await _updateRefused(h), want.updateRefused,
          reason: 'update gate');
    });

    testWidgets('$name: the disconnect guard', (tester) async {
      final container = ProviderContainer(overrides: [
        cameraStateProvider.overrideWith((ref) => FixedCamera(ref, camera)),
      ]);
      addTearDown(container.dispose);
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(builder: (context, ref, _) {
              widgetRef = ref;
              return const SizedBox();
            }),
          ),
        ),
      );
      bool? proceeded;
      unawaited(
        confirmDisconnectCooledCamera(
          tester.element(find.byType(SizedBox)),
          widgetRef,
        ).then((value) => proceeded = value),
      );
      await tester.pumpAndSettle();
      final asked = find.text('Disconnect anyway').evaluate().isNotEmpty;
      expect(asked, want.disconnectAsks, reason: 'disconnect guard');
      if (!asked) expect(proceeded, isTrue);
    });
  }
}
