// A camera card offers cooling only for a camera that has a cooler: a DSLR or
// mirrorless body gets no "Cool to" or "Warm up" button, and no cooler rows.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_app/screens/equipment/widgets/device_tile_width.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _deviceId = 'native:gphoto2:0:757362:canon_eos_6d';

CameraCapabilities _caps({required bool cooled, List<int> iso = const []}) =>
    CameraCapabilities(
      maxWidth: 5472,
      maxHeight: 3648,
      bitDepth: 14,
      canSetCcdTemperature: cooled,
      canSetCooler: cooled,
      canGetCoolerPower: cooled,
      canSetGain: true,
      isoSpeeds: iso,
      canSetOffset: cooled,
      isColor: true,
    );

Future<void> _pump(WidgetTester tester, CameraCapabilities caps) async {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      equipmentCameraCapabilitiesProvider.overrideWith((ref, id) async => caps),
      cameraCapabilitiesProvider.overrideWith((ref, id) async => caps),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        // A grid cell wide enough for both cooling buttons inline.
        home: const Scaffold(
          body: SingleChildScrollView(
            child: DeviceTileWidth(
              width: 520,
              child: ConnectedDeviceCard(type: DeviceType.camera),
            ),
          ),
        ),
      ),
    ),
  );
  final notifier = container.read(cameraStateProvider.notifier);
  notifier.setConnecting(_deviceId, 'Canon EOS 6D');
  notifier.setConnected();
  notifier.updateReadout(gain: 800, offset: 0, binX: 1, binY: 1);
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Show details'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a DSLR card offers no cooling and reads its ISO',
      (tester) async {
    await _pump(tester, _caps(cooled: false, iso: const [100, 400, 800, 1600]));
    expect(find.textContaining('Cool to'), findsNothing);
    expect(find.text('Warm up'), findsNothing);
    expect(find.text('Cooler'), findsNothing);

    await _openDetails(tester);
    expect(find.text('Cooling'), findsNothing);
    expect(find.text('Target temp'), findsNothing);
    expect(find.text('Offset'), findsNothing);
    expect(find.text('ISO'), findsOneWidget);
    expect(find.text('800'), findsOneWidget);
  });

  testWidgets('a cooled camera card keeps its cooling buttons', (tester) async {
    await _pump(tester, _caps(cooled: true));
    expect(find.textContaining('Cool to'), findsOneWidget);
    expect(find.text('Warm up'), findsOneWidget);

    await _openDetails(tester);
    expect(find.text('Cooling'), findsOneWidget);
    expect(find.text('Gain'), findsOneWidget);
  });
}
