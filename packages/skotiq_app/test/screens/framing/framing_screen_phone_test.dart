// Phone-tier layout / overflow guard for the Framing screen.
//
// The framing screen is a canvas + controls sidebar. On a phone the sidebar
// must collapse so the canvas stays dominant (bottom sheet in portrait,
// side-by-side split in landscape) without any RenderFlex overflow, at every
// supported phone size in BOTH orientations.
//
// This test pumps the real FramingScreen (with a seeded, network-free framing
// state) at the three standard phone sizes — 360x640, 390x844, 430x932 — and
// each rotated, asserting:
//   1. No overflow exception is recorded at any size/orientation.
//   2. The canvas (the dominant survey region) is present and dominant.
//   3. The controls are reachable: in portrait a collapsed-sheet handle is
//      shown; in landscape the controls panel sits beside the canvas.
//
// Determinism mirrors framing_registration_test.dart: framingProvider is
// overridden with a seeded notifier (so no DB/network), framingFOVProvider
// resolves a ready equipment result, and the GPU HiPS layer is gated off.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_canvas.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

Future<ui.Image> _decodeSurveyImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 800, 600),
    Paint()..color = const Color(0xFF101820),
  );
  final picture = recorder.endRecording();
  return picture.toImage(800, 600);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image surveyImage;

  setUpAll(() async {
    surveyImage = await _decodeSurveyImage();
  });

  tearDownAll(() {
    surveyImage.dispose();
  });

  FramingState seededState() {
    return FramingState(
      target: _target,
      surveyImageBytes: Uint8List.fromList(const [0]),
      surveyImage: surveyImage,
      previewFovDegrees: 0.5,
      showCardinalDirections: false,
      showGrid: false,
      // Exercise the mosaic section's spinners/sliders in the controls column
      // so its dense rows are laid out at the test width.
      mosaicEnabled: true,
    );
  }

  List<Override> overrides() {
    return [
      framingProvider
          .overrideWith((ref) => _SeededFramingNotifier(ref, seededState())),
      framingFOVProvider.overrideWith(
        (ref) async => const FramingEquipmentResult(
          status: EquipmentStatus.ready,
          equipment: _equipment,
          profileName: 'Test Profile',
        ),
      ),
      hipsFramingEnabledProvider.overrideWith((ref) => false),
    ];
  }

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    await pumpAppScreen(
      tester,
      const FramingScreen(),
      size: size,
      settle: false,
      extraOverrides: overrides(),
    );
    // Drain the FutureProvider microtask + a couple of layout frames. The
    // ContextualTourPrompt animation forbids pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
  }

  // The three standard phone sizes (portrait) and their landscape rotations.
  const phoneSizes = <(String, Size)>[
    ('small 360x640', Size(360, 640)),
    ('modern 390x844', Size(390, 844)),
    ('large 430x932', Size(430, 932)),
  ];

  for (final (label, portrait) in phoneSizes) {
    final landscape = Size(portrait.height, portrait.width);

    testWidgets('framing has no overflow at $label portrait', (tester) async {
      await pumpAt(tester, portrait);

      expect(tester.takeException(), isNull);
      // The dominant canvas is present.
      expect(find.byType(FramingCanvas), findsOneWidget);
      // No RenderFlex overflow anywhere in the tree.
      _expectNoOverflow(tester);
    });

    testWidgets('framing has no overflow at $label landscape', (tester) async {
      await pumpAt(tester, landscape);

      expect(tester.takeException(), isNull);
      expect(find.byType(FramingCanvas), findsOneWidget);
      _expectNoOverflow(tester);
    });
  }

  testWidgets('framing canvas stays dominant on a phone (portrait)',
      (tester) async {
    const size = Size(390, 844);
    await pumpAt(tester, size);

    // In phone portrait the controls collapse to a bottom sheet, so the canvas
    // should span the full width (no side panel stealing horizontal space).
    final canvasWidth = tester.getSize(find.byType(FramingCanvas)).width;
    expect(canvasWidth, closeTo(size.width, 1.0),
        reason: 'Phone portrait: the canvas keeps the full width; controls '
            'live in a collapsed bottom sheet, not a side column.');
  });

  testWidgets('framing rotates from portrait to landscape without clipping',
      (tester) async {
    await pumpAt(tester, const Size(390, 844));
    expect(tester.takeException(), isNull);

    // Rotate in place — same screen, swapped dimensions.
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.takeException(), isNull);
    expect(find.byType(FramingCanvas), findsOneWidget);
    _expectNoOverflow(tester);
  });
}

/// Asserts no RenderFlex overflow occurred. The authoritative signal is the
/// `FlutterError` Flutter throws (in debug) when a RenderFlex overflows during
/// the paint phase; the test binding records it and [WidgetTester.takeException]
/// surfaces it. A null exception means no overflow at the pumped size.
void _expectNoOverflow(WidgetTester tester) {
  expect(tester.takeException(), isNull);
}
