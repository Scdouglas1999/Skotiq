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

class _CoverNotifier extends CoverCalibratorStateNotifier {
  _CoverNotifier(super.ref) {
    state = const CoverCalibratorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'cover-1',
      deviceName: 'Test Cover',
      coverStatus: CoverStatus.closed,
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
      const ConnectedDeviceCard(type: DeviceType.guider),
    );

    expect(find.widgetWithText(SkotiqButton, 'Start guiding'), findsNothing);
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
      const ConnectedDeviceCard(type: DeviceType.guider),
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

  testWidgets(
      'a command the old host answers late leaves the new host\'s command '
      'running', (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    final serviceA = _MockDeviceService();
    final serviceB = _MockDeviceService();
    final oldStart = Completer<void>();
    final newStart = Completer<void>();
    when(() => serviceA.startGuiding()).thenAnswer((_) => oldStart.future);
    when(() => serviceB.startGuiding()).thenAnswer((_) => newStart.future);
    late _SwitchableBackendNotifier backendNotifier;

    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: DeviceType.guider),
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
    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    await tester.tap(find.text('Start guiding'));
    await tester.pump();
    expect(_button(tester, 'Start guiding').onPressed, isNull);

    oldStart.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      _button(tester, 'Start guiding').onPressed,
      isNull,
      reason: 'the old host\'s answer must not free the card while the new '
          'host\'s start is still running',
    );
    expect(find.text('Guiding started'), findsNothing);

    newStart.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_button(tester, 'Start guiding').onPressed, isNotNull);
    expect(find.text('Guiding started'), findsOneWidget);
  });

  testWidgets(
      'a cover the old host opens after a host switch writes nothing to the '
      'new host\'s cover', (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    final oldOpen = Completer<void>();
    when(() => backendA.coverOpen('cover-1')).thenAnswer((_) => oldOpen.future);
    late _SwitchableBackendNotifier backendNotifier;

    final handle = await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: DeviceType.coverCalibrator),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        coverCalibratorStateProvider.overrideWith(_CoverNotifier.new),
        coverCalibratorCapabilityFetcherProvider.overrideWithValue(
          (_) async => const CoverCalibratorCapabilitySnapshot(
            coverPresent: true,
            calibratorPresent: false,
            coverStatus: CoverStatus.closed,
            maxBrightness: 0,
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Open cover'));
    await tester.pump();
    backendNotifier.replaceBackend(backendB);
    await tester.pump();

    oldOpen.complete();
    await tester.pumpAndSettle();
    expect(
      handle.container.read(coverCalibratorStateProvider).coverStatus,
      CoverStatus.closed,
      reason: 'the old host\'s "moving" must not land on the new host',
    );
    expect(find.text('Opening cover'), findsNothing);
    verifyNever(() => backendB.coverOpen(any()));
  });
}
