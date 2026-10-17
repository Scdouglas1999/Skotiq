// The shell's device count must count every device the app can connect.
//
// Tallying only the slots the profile editor lists first drops the dome and the
// weather station: with six simulated devices attached (camera, mount, focuser,
// filter wheel, dome, weather station) the global status bar reads "My
// Equipment / 4 connected" while the Equipment header reads "6 connected · 6
// unsaved" in the same frame — and the chip is the one readout an operator
// glances at before starting an unattended run.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/equipment_status_indicator.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/pump_app_screen.dart';

const _connected = DeviceConnectionState.connected;

class _FakeCameraNotifier extends StateNotifier<CameraStateSnapshot>
    implements CameraStateNotifier {
  _FakeCameraNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDomeNotifier extends StateNotifier<DomeState>
    implements DomeStateNotifier {
  _FakeDomeNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWeatherNotifier extends StateNotifier<WeatherState>
    implements WeatherStateNotifier {
  _FakeWeatherNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _profile = EquipmentProfileModel(
  id: 1,
  name: 'My Equipment',
  focalLength: 600,
  aperture: 100,
);

Future<void> _pumpIndicator(WidgetTester tester, {ThemeData? theme}) async {
  await pumpAppScreen(
    tester,
    const EquipmentStatusIndicator(),
    settle: false,
    theme: theme,
    extraOverrides: [
      activeEquipmentProfileProvider.overrideWithValue(_profile),
      cameraStateProvider.overrideWith(
        (ref) => _FakeCameraNotifier(
          const CameraStateSnapshot(
            connectionState: _connected,
            deviceId: 'sim:camera:1',
            deviceName: 'Simulated Camera',
          ),
        ),
      ),
      domeStateProvider.overrideWith(
        (ref) => _FakeDomeNotifier(
          const DomeState(
            connectionState: _connected,
            deviceId: 'sim:dome:1',
            deviceName: 'Simulated Dome',
          ),
        ),
      ),
      weatherStateProvider.overrideWith(
        (ref) => _FakeWeatherNotifier(
          const WeatherState(
            connectionState: _connected,
            deviceId: 'sim:weather:1',
            deviceName: 'Simulated Weather Station',
          ),
        ),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('the chip counts auxiliary devices, not just the first six slots',
      (tester) async {
    await _pumpIndicator(tester);

    expect(
      find.text('3 connected'),
      findsOneWidget,
      reason: 'camera + dome + weather station are all attached',
    );
  });

  testWidgets('the dropdown accounts for every device the chip counted',
      (tester) async {
    await _pumpIndicator(tester);

    await tester.tap(find.byType(EquipmentStatusIndicator));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Simulated Camera'), findsOneWidget);
    expect(find.text('Simulated Dome'), findsOneWidget);
    expect(find.text('Simulated Weather Station'), findsOneWidget);
  });

  // A profile the operator never gave an icon to. The chip used to fill that in
  // with a literal 🔭, and a colour emoji is painted by the platform's emoji
  // font: under Red night a pixel scan of the whole 1600x900 window found
  // exactly one saturated non-red cluster, and it was this glyph.
  testWidgets('the app\'s own profile badge is a glyph, not a colour emoji', (
    tester,
  ) async {
    await _pumpIndicator(tester);

    expect(_profile.profileIcon, isNull, reason: 'the case under test');
    expect(find.text('🔭'), findsNothing);

    final colors = SkotiqColors.of(
      tester.element(find.byType(EquipmentStatusIndicator)),
    );
    final badge = tester.widget<Icon>(
      find.byIcon(SkotiqIcons.mount).first,
    );
    expect(badge.color, colors.textSecondary);
  });

  testWidgets('under red night the badge takes the red palette', (
    tester,
  ) async {
    await _pumpIndicator(tester, theme: SkotiqTheme.redNight);

    final colors = SkotiqColors.of(
      tester.element(find.byType(EquipmentStatusIndicator)),
    );
    expect(colors.textSecondary, SkotiqColors.redNight.textSecondary);

    final badge = tester.widget<Icon>(
      find.byIcon(SkotiqIcons.mount).first,
    );
    expect(
      badge.color,
      colors.textSecondary,
      reason: 'the one thing an emoji could never do',
    );
  });
}
