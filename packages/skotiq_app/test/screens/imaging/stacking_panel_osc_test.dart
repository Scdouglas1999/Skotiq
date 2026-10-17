// Tests for the OSC / Color controls in the live-stacking panel (component
// C14).
//
// The panel is exercised with overridden providers so it never reaches the
// native dynamic library: `liveStackingProvider` uses a real notifier (its
// `updateConfig` is a pure state mutation), and the camera providers are
// overridden to control the auto-detection path.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

CameraCapabilities _colorCaps({String? bayerPattern = 'RGGB'}) {
  return CameraCapabilities(
    maxWidth: 1000,
    maxHeight: 1000,
    bitDepth: 16,
    isColor: true,
    bayerPattern: bayerPattern,
  );
}

CameraCapabilities _monoCaps() {
  return const CameraCapabilities(
    maxWidth: 1000,
    maxHeight: 1000,
    bitDepth: 16,
    isColor: false,
  );
}

Future<void> _pumpPanel(
  WidgetTester tester, {
  String? cameraId,
  CameraCapabilities? caps,
  bool isRemote = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 1600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final overrides = <Override>[
    isRemoteModeProvider.overrideWithValue(isRemote),
    connectedCameraIdProvider.overrideWithValue(cameraId),
  ];
  if (cameraId != null && caps != null) {
    overrides.add(
      equipmentCameraCapabilitiesProvider(cameraId)
          .overrideWith((ref) async => caps),
    );
  }

  const colors = SkotiqColors.dark;
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: StackingPanel(colors: colors)),
      ),
    ),
  );
  // Resolve the caps FutureProvider + run the post-frame seeding callback.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StackingPanel OSC controls', () {
    testWidgets('remote mode identifies Stack & Share as host-only',
        (tester) async {
      await _pumpPanel(tester, isRemote: true);

      final action = find.widgetWithText(
        SkotiqButton,
        'Stack & Share on imaging host',
      );
      expect(action, findsOneWidget);
      expect(tester.widget<SkotiqButton>(action).onPressed, isNull);
    });

    testWidgets('Color section renders with the switch OFF by default',
        (tester) async {
      await _pumpPanel(tester);

      expect(find.text('COLOR (OSC)'), findsOneWidget);
      expect(find.text('OSC / color'), findsOneWidget);

      // No camera connected → pristine mono config → switch OFF → dropdowns
      // hidden.
      expect(find.text('Bayer pattern'), findsNothing);
      expect(find.text('Demosaic quality'), findsNothing);
    });

    testWidgets(
        'toggling the switch ON flips sensorMode off mono and reveals '
        'the Bayer + demosaic dropdowns', (tester) async {
      late ProviderContainer container;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 1600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const colors = SkotiqColors.dark;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            isRemoteModeProvider.overrideWithValue(false),
            connectedCameraIdProvider.overrideWithValue(null),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                theme: SkotiqTheme.dark,
                home: const Scaffold(body: StackingPanel(colors: colors)),
              );
            },
          ),
        ),
      );
      await tester.pump();

      // Default config is mono.
      expect(
        container.read(liveStackingProvider).config.sensorMode,
        'mono',
      );

      // Flip the OSC switch ON.
      final toggle = find.descendant(
        of: find.byType(SkotiqSwitchRow),
        matching: find.byType(SkotiqSwitch),
      );
      await tester.tap(toggle);
      await tester.pump();

      // Sensor mode left mono → resolves to auto.
      expect(
        container.read(liveStackingProvider).config.sensorMode,
        'auto',
      );
      expect(find.text('Bayer pattern'), findsOneWidget);
      expect(find.text('Demosaic quality'), findsOneWidget);
    });

    testWidgets(
        'a connected colour camera defaults the switch ON and '
        'preselects the detected pattern', (tester) async {
      await _pumpPanel(
        tester,
        cameraId: 'native:zwo:0',
        caps: _colorCaps(bayerPattern: 'RGGB'),
      );

      // Seeded ON → dropdowns visible, Auto entry names the detected pattern.
      expect(find.text('Bayer pattern'), findsOneWidget);
      expect(find.text('Demosaic quality'), findsOneWidget);
      expect(find.text('Auto (detected: RGGB)'), findsOneWidget);
    });

    testWidgets('a connected mono camera leaves the switch OFF',
        (tester) async {
      await _pumpPanel(
        tester,
        cameraId: 'native:zwo:0',
        caps: _monoCaps(),
      );

      expect(find.text('Bayer pattern'), findsNothing);
      expect(find.text('Demosaic quality'), findsNothing);
    });

    testWidgets('changing the Bayer dropdown updates bayerPattern',
        (tester) async {
      late ProviderContainer container;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(420, 1600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const colors = SkotiqColors.dark;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            isRemoteModeProvider.overrideWithValue(false),
            connectedCameraIdProvider.overrideWithValue('native:zwo:0'),
            equipmentCameraCapabilitiesProvider('native:zwo:0')
                .overrideWith((ref) async => _colorCaps(bayerPattern: 'RGGB')),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                theme: SkotiqTheme.dark,
                home: const Scaffold(body: StackingPanel(colors: colors)),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // Seeded to auto with RGGB preselected (null override + auto sensor mode).
      expect(container.read(liveStackingProvider).config.sensorMode, 'auto');
      expect(container.read(liveStackingProvider).config.bayerPattern, isNull);

      // Open the Bayer dropdown and pick an explicit BGGR.
      await tester.tap(find.text('Auto (detected: RGGB)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('BGGR').last);
      await tester.pumpAndSettle();

      expect(container.read(liveStackingProvider).config.bayerPattern, 'BGGR');

      // Switch back to automatic detection.
      // `LiveStackingConfig.copyWith(bayerPattern: null)` means "keep current",
      // so clearing has to go through a path that is not copyWith.
      await tester.tap(find.text('BGGR'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auto (detected: RGGB)').last);
      await tester.pumpAndSettle();

      expect(container.read(liveStackingProvider).config.bayerPattern, isNull);
    });
  });

  // The stacked-preview pixel conversion now delegates to the app's shared
  // auto-stretch; it is covered by stacking_panel_preview_stretch_test.dart.
}
