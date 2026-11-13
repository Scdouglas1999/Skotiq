// Imaging's guiding panel shows the one settle setting the Guiding screen and
// Tonight use, in guide-camera pixels, and dithers through the one guiding
// controller, which sends that setting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _MockGuider extends Mock implements Phd2Controller {}

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

  testWidgets('the panel shows the settle setting, in pixels, and dithers with it', (
    tester,
  ) async {
    final guider = _MockGuider();
    when(() => guider.dither()).thenAnswer((_) async {});

    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(
        child: SizedBox(
          width: 300,
          child: GuidingPanel(colors: SkotiqColors.dark),
        ),
      ),
      extraOverrides: [
        phd2ControllerProvider.overrideWithValue(guider),
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
    verify(() => guider.dither()).called(1);
  });
}
