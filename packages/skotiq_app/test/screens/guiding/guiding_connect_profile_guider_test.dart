// With the guider disconnected, the Guiding screen's Connect button connects
// the profile's guider. A profile set up for the built-in guider must not get
// a PHD2 connect.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';

import '../../harness/harness.dart';

class _RecordingDeviceService extends DeviceService {
  _RecordingDeviceService(super.ref, super.backend);

  final List<String> guiderConnects = <String>[];

  @override
  Future<void> connect(
    DeviceType type,
    String deviceId, {
    String? host,
    int? port,
  }) async {
    if (type == DeviceType.guider) guiderConnects.add(deviceId);
  }

  @override
  Future<void> connectDeviceGuider(
    String guiderId, {
    String? guideCameraId,
  }) async {
    guiderConnects.add(guiderId);
  }
}

class _RecordingPhd2Controller extends Phd2Controller {
  _RecordingPhd2Controller(super.ref, super.backend);

  int connects = 0;

  @override
  Future<void> connect(String host, int port) async {
    connects++;
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Connect reconnects the built-in guider, not PHD2',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(1280, 800),
      settle: false,
      extraOverrides: <Override>[
        deviceServiceProvider.overrideWith((ref) {
          final service =
              _RecordingDeviceService(ref, ref.watch(backendProvider));
          ref.onDispose(service.dispose);
          return service;
        }),
        phd2ControllerProvider.overrideWith((ref) {
          final controller =
              _RecordingPhd2Controller(ref, ref.watch(backendProvider));
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    final dao = handle.container.read(equipmentProfilesDaoProvider);
    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(
        name: 'Built-in rig',
        guiderId: const Value(builtinGuiderDeviceId),
        isActive: const Value(true),
      ),
    );
    expect(id, isNotNull);
    await _drain(tester);

    expect(find.text('Connect'), findsOneWidget);
    await tester.tap(find.text('Connect'));
    await _drain(tester);

    final service =
        handle.container.read(deviceServiceProvider) as _RecordingDeviceService;
    final phd2 = handle.container.read(phd2ControllerProvider)
        as _RecordingPhd2Controller;
    expect(service.guiderConnects, <String>[builtinGuiderDeviceId]);
    expect(phd2.connects, 0);
    expect(find.text('Built-in guider disconnected'), findsOneWidget);
  });
}
