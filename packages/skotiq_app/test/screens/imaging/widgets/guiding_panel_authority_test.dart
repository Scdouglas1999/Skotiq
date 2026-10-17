import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
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

final _serviceSlotProvider = StateProvider<DeviceService>(
  (ref) => throw UnimplementedError(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('late start-guiding completion cannot mutate the new host',
      (tester) async {
    final serviceA = _MockDeviceService();
    final serviceB = _MockDeviceService();
    final resultA = Completer<void>();
    when(
      () => serviceA.startGuiding(
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
      ),
    ).thenAnswer((_) => resultA.future);
    when(
      () => serviceB.startGuiding(
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
      ),
    ).thenAnswer((_) async {});

    final handle = await pumpAppScreen(
      tester,
      const GuidingPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        _serviceSlotProvider.overrideWith((ref) => serviceA),
        deviceServiceProvider.overrideWith(
          (ref) => ref.watch(_serviceSlotProvider),
        ),
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
      ],
      settle: false,
    );
    await tester.pump();

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(find.text('Starting...'), findsOneWidget);

    handle.container.read(_serviceSlotProvider.notifier).state = serviceB;
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);

    resultA.complete();
    await tester.pump();
    expect(handle.container.read(sessionStateProvider).isGuiding, isFalse);

    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(handle.container.read(sessionStateProvider).isGuiding, isTrue);
    verify(
      () => serviceA.startGuiding(
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
      ),
    ).called(1);
    verify(
      () => serviceB.startGuiding(
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
      ),
    ).called(1);
  });
}
