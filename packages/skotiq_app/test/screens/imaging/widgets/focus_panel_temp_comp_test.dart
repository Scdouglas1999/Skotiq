// Imaging → Focus must show the temperature-compensation model.
//
// Without it, the model those autofocus runs build has only two surfaces — the
// mobile Devices tab and a Settings page documented "Remote-only" — so an
// operator running autofocus on this very screen cannot see the slope/R² their
// own runs produced.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_app/widgets/focus_model_curve_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _ConnectedFocuser extends FocuserStateNotifier {
  _ConnectedFocuser(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'focuser-1',
      deviceName: 'Test Focuser',
      position: 12000,
      isAbsolute: true,
      hasTemperature: true,
      temperature: 6.5,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Focus tab renders the temperature-compensation model',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(500, 2400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final profileData = ProfileFocusData(
      profileId: '7',
      dataPoints: [
        FocusHistoryPoint(
          timestamp: DateTime.utc(2026, 7, 13),
          temperatureCelsius: 6.5,
          focusPosition: 11800,
          hfr: 1.9,
        ),
      ],
      temperatureModel: FocusModel(
        slope: -31.0,
        intercept: 12000,
        rSquared: 0.95,
        dataPointCount: 7,
        lastUpdated: DateTime.utc(2026, 7, 13),
      ),
    );

    await pumpAppScreen(
      tester,
      const FocusPanel(colors: SkotiqColors.dark),
      extraOverrides: [
        focuserStateProvider.overrideWith(_ConnectedFocuser.new),
        activeEquipmentProfileProvider.overrideWithValue(
          const EquipmentProfileModel(id: 7, name: 'Test rig'),
        ),
        focusProfileDataProvider('7').overrideWith((ref) async => profileData),
      ],
      // The panel hosts continuously-animating chrome, so pumpAndSettle never
      // returns; pump a couple of frames to let the async model resolve.
      settle: false,
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Temperature Compensation'), findsOneWidget);
    expect(find.byType(FocusModelCurveCard), findsOneWidget);
    // The model itself, not just a heading: quality + R² off the fitted model.
    expect(find.text('Excellent · R²=0.95'), findsOneWidget);
  });
}
