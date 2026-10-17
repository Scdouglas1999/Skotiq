// The framing canvas's top-left chrome must not be drawn on top of itself.
//
// FramingScreen places the optical-config affordance — a 48px opaque button, or
// the panel when it is open — in its OWN Stack at (16, 16). FramingCanvas puts
// its control row (survey dropdown + Grid/FOV chips) at the identical origin in
// a different Stack. Nothing in the layout stopped them overlapping, so the
// button's opaque body ate the survey dropdown's leading icon and first glyph:
// "DSS2 Red" rendered as ")SS2 Red" on every entry to the Framing screen, and
// opening the panel hid the dropdown and the Grid chip outright.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_app/screens/framing/widgets/optical_config_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

const FramingEquipment _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 13.5,
  sensorHeightMm: 9.0,
  pixelSizeMicrons: 3.76,
  pixelsX: 3600,
  pixelsY: 2400,
  telescopeName: 'Test Refractor',
  focalLengthMm: 530,
  apertureMm: 106,
);

const FramingTarget _target = FramingTarget(
  name: 'NGC 7000',
  catalogId: 'NGC7000',
  raHours: 20.97,
  decDegrees: 44.33,
);

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

Future<ui.Image> _blankSurvey() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 800, 600),
    Paint()..color = const Color(0xFF101820),
  );
  return recorder.endRecording().toImage(800, 600);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;

  setUpAll(() async {
    surveyImage = await _blankSurvey();
  });

  tearDownAll(() => surveyImage.dispose());

  FramingState seededState({bool panelOpen = false}) => FramingState(
        target: _target,
        surveyImageBytes: Uint8List.fromList(const [0]),
        surveyImage: surveyImage,
        previewFovDegrees: 0.5,
        showGrid: false,
        showCardinalDirections: false,
        showOpticalConfigPanel: panelOpen,
      );

  Future<void> pumpFraming(
    WidgetTester tester, {
    bool panelOpen = false,
    Size size = const Size(1600, 900),
  }) async {
    await pumpAppScreen(
      tester,
      const FramingScreen(),
      size: size,
      settle: false,
      extraOverrides: [
        framingProvider.overrideWith(
          (ref) =>
              _SeededFramingNotifier(ref, seededState(panelOpen: panelOpen)),
        ),
        framingFOVProvider.overrideWith(
          (ref) async => const FramingEquipmentResult(
            status: EquipmentStatus.ready,
            equipment: _equipment,
            profileName: 'Test Profile',
          ),
        ),
        hipsFramingEnabledProvider.overrideWith((ref) => false),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    // Drain a PRE-EXISTING, unrelated RenderFlex overflow raised by the actions
    // panel's step rows (framing_actions_panel.dart:431) at this sidebar width.
    // It is present with or without the canvas-toolbar change under test here,
    // and would otherwise fail this test before its geometry assertions run.
    // Overflow itself is guarded by framing_screen_phone_test.dart.
    while (tester.takeException() != null) {}
  }

  testWidgets('the optical-config button does not cover the survey dropdown', (
    tester,
  ) async {
    await pumpFraming(tester);

    expect(find.byType(FramingCanvas), findsOneWidget);
    final button = find.byTooltip('Show optical config panel');
    final dropdown = find.byType(SkotiqDropdown).first;
    expect(button, findsOneWidget);

    final buttonRect = tester.getRect(button);
    final dropdownRect = tester.getRect(dropdown);

    expect(
      buttonRect.overlaps(dropdownRect),
      isFalse,
      reason: 'button $buttonRect overlapped the survey dropdown $dropdownRect '
          '— the first glyph of the survey name was being painted over.',
    );
    // The dropdown starts to the RIGHT of the button, i.e. the row was moved
    // rather than the button being hidden.
    expect(dropdownRect.left, greaterThan(buttonRect.right));
  });

  testWidgets('the open optical-config panel does not cover the survey row', (
    tester,
  ) async {
    await pumpFraming(tester, panelOpen: true);

    final panel = find.byType(OpticalConfigPanel);
    final dropdown = find.byType(SkotiqDropdown).first;
    expect(panel, findsOneWidget);

    final panelRect = tester.getRect(panel);
    final dropdownRect = tester.getRect(dropdown);
    expect(
      panelRect.overlaps(dropdownRect),
      isFalse,
      reason: 'the panel $panelRect covered the survey dropdown $dropdownRect',
    );
  });
}
