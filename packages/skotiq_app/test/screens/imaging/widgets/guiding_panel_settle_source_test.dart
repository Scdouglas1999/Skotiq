// Imaging's guiding panel shows and uses the one settle setting the Guiding
// screen and Tonight use, in guide-camera pixels. It kept its own copy, 1.0
// marked in arcseconds, while Tonight read 1.5 px from the setting.
import 'package:flutter/material.dart';
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
      isGuiding: true,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the panel shows and uses the settle setting, in pixels', (
    tester,
  ) async {
    final service = _MockDeviceService();
    when(
      () => service.dither(
        amount: any(named: 'amount'),
        raOnly: any(named: 'raOnly'),
        settlePixels: any(named: 'settlePixels'),
        settleTime: any(named: 'settleTime'),
        settleTimeout: any(named: 'settleTimeout'),
      ),
    ).thenAnswer((_) async {});

    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(
        child: SizedBox(
          width: 300,
          child: GuidingPanel(colors: SkotiqColors.dark),
        ),
      ),
      extraOverrides: [
        deviceServiceProvider.overrideWithValue(service),
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
      ],
      settle: false,
    );
    final settings = handle.container.read(appSettingsProvider.notifier);
    await tester.runAsync(() async {
      await handle.container.read(appSettingsProvider.future);
      await settings.setSettleThreshold(2.5);
      await settings.setSettleTime(20);
      await settings.setSettleTimeout(90);
      await settings.setDitherScale('Large');
      await settings.setDitherRaOnly(true);
    });
    await tester.pump();

    expect(find.text('2.5px'), findsOneWidget, reason: 'settle threshold');
    expect(find.text('20.0s'), findsOneWidget, reason: 'settle time');
    expect(find.text('10.0px'), findsOneWidget, reason: 'dither amount');
    expect(
      find.textContaining('"'),
      findsNothing,
      reason: 'a pixel value is never marked in arcseconds',
    );

    await tester.tap(find.text('Dither'));
    await tester.pump();
    verify(
      () => service.dither(
        amount: 10,
        raOnly: true,
        settlePixels: 2.5,
        settleTime: 20,
        settleTimeout: 90,
      ),
    ).called(1);
  });
}
