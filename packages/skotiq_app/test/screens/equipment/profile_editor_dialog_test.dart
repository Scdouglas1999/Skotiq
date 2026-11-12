import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The editor watches the device slots, whose providers hold database query
/// streams; closing them schedules a zero-length timer that has to run before
/// the test ends.
Future<void> _closeEditor(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}

void main() {
  testWidgets('new profile editor exposes its complete single-page form',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: ProfileEditorDialog(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('New profile'), findsOneWidget);
    expect(find.text('Profile identity'), findsOneWidget);
    expect(find.text('Optical train'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('Camera defaults'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Create profile'), findsOneWidget);

    await _closeEditor(tester);
  });

  // qa-surfaces S12: a new profile with no camera chosen showed "IMAGE SCALE
  // at 3.76µm", the connected camera's pixel size.
  testWidgets('a new profile with no camera shows no camera pixel size',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer(
      overrides: [
        cameraCapabilitiesProvider.overrideWith(
          (ref, id) async => const CameraCapabilities(
            maxWidth: 1920,
            maxHeight: 1080,
            pixelSizeX: 3.76,
            pixelSizeY: 3.76,
            bitDepth: 16,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final camera = container.read(cameraStateProvider.notifier);
    camera.setConnecting('sim_camera_1', 'Simulated Camera');
    camera.setConnected();
    await container.read(cameraCapabilitiesProvider('sim_camera_1').future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ProfileEditorDialog()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('3.76'), findsNothing);

    await _closeEditor(tester);
  });
}
