import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _MockDeviceService extends Mock implements DeviceService {}

class _ConnectedGuiderNotifier extends GuiderStateNotifier {
  _ConnectedGuiderNotifier(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'guider-1',
      deviceName: 'Test Guider',
    );
  }
}

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

SkotiqButton _button(WidgetTester tester, String label) =>
    tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, label),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('disconnected guider does not offer a start command',
      (tester) async {
    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.guider),
    );

    expect(_button(tester, 'Start guiding').onPressed, isNull);
  });

  testWidgets('host switch unlocks guiding and suppresses the old result',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    final serviceA = _MockDeviceService();
    final serviceB = _MockDeviceService();
    final oldStart = Completer<void>();
    when(() => serviceA.startGuiding()).thenAnswer((_) => oldStart.future);
    when(() => serviceB.startGuiding()).thenAnswer((_) async {});
    late _SwitchableBackendNotifier backendNotifier;

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.guider),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
        deviceServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          return identical(backend, backendA) ? serviceA : serviceB;
        }),
      ],
    );

    await tester.tap(find.text('Start guiding'));
    await tester.pump();
    expect(_button(tester, 'Start guiding').onPressed, isNull);

    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    expect(_button(tester, 'Start guiding').onPressed, isNotNull);

    oldStart.complete();
    await tester.pump();
    expect(find.text('Guiding started'), findsNothing);

    await tester.tap(find.text('Start guiding'));
    await tester.pump();
    verify(() => serviceB.startGuiding()).called(1);
    expect(find.text('Guiding started'), findsOneWidget);
  });
}
