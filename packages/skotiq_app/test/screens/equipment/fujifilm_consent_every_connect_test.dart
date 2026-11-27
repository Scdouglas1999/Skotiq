// The Fujifilm warranty notice is asked once on every connect the operator
// starts, Connect all too, and shown once after a connect nobody was asked
// for (auto-connect at launch), which never skips the camera.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/screens/equipment/utils/connect_all_action.dart';
import 'package:skotiq_app/startup/fujifilm_notice_after_connect.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../harness/harness.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _FakeProfile extends Fake implements EquipmentProfileModel {}

class _CameraNotifier extends CameraStateNotifier {
  _CameraNotifier(super.ref);

  void connectAs(String id, String name) {
    // ignore: invalid_use_of_protected_member
    state = CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: id,
      deviceName: name,
    );
  }

  void dropConnection() {
    // ignore: invalid_use_of_protected_member
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.disconnected,
    );
  }
}

const _notice = 'Fujifilm camera control SDK notice';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(_FakeProfile()));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Connect all asks, and a no leaves only the camera out', (
    tester,
  ) async {
    final devices = _MockDeviceService();
    EquipmentProfileModel? swept;
    when(() => devices.connectProfile(any())).thenAnswer((call) async {
      swept = call.positionalArguments.first as EquipmentProfileModel;
      return (connected: 1, failures: const <DeviceConnectProgress>[]);
    });
    const profile = EquipmentProfileModel(
      id: 1,
      name: 'X-T5 rig',
      cameraId: 'fujifilm:camera:x-t5',
      cameraName: 'Fujifilm X-T5',
      mountId: 'ascom:mount:eq6',
    );
    final handle = await pumpAppScreen(
      tester,
      Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => runConnectAllForProfile(context, ref, profile),
          child: const Text('connect all'),
        ),
      ),
      extraOverrides: [deviceServiceProvider.overrideWithValue(devices)],
    );
    expect(handle, isNotNull);

    await tester.tap(find.text('connect all'));
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(swept?.cameraId, isEmpty);
    expect(swept?.mountId, 'ascom:mount:eq6');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a camera auto-connect brought up gets the notice once', (
    tester,
  ) async {
    late _CameraNotifier camera;
    await pumpAppScreen(
      tester,
      const FujifilmNoticeAfterConnect(child: SizedBox.shrink()),
      extraOverrides: [
        cameraStateProvider
            .overrideWith((ref) => camera = _CameraNotifier(ref)),
      ],
    );

    camera.connectAs('fujifilm:camera:x-t5', 'Fujifilm X-T5');
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsOneWidget);
    expect(find.text('Cancel'), findsNothing, reason: 'it is connected');
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();

    camera.dropConnection();
    await tester.pump();
    camera.connectAs('fujifilm:camera:x-t5', 'Fujifilm X-T5');
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsNothing);
  });

  testWidgets('a camera already up when the app shows gets the notice too', (
    tester,
  ) async {
    await pumpAppScreen(
      tester,
      const FujifilmNoticeAfterConnect(child: SizedBox.shrink()),
      extraOverrides: [
        cameraStateProvider.overrideWith(
          (ref) => _CameraNotifier(ref)
            ..connectAs('fujifilm:camera:x-t5', 'Fujifilm X-T5'),
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text(_notice), findsOneWidget);
    await tester.tap(find.text('I understand'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('fujifilm_disclaimer_acknowledged'), isTrue);
  });
}
