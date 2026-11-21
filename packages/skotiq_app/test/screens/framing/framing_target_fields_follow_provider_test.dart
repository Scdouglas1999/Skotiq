import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/framing_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

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

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

Future<ui.Image> _survey() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 8, 8),
    Paint()..color = const Color(0xFF101820),
  );
  return recorder.endRecording().toImage(8, 8);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ui.Image survey;

  setUpAll(() async {
    survey = await _survey();
  });

  tearDownAll(() => survey.dispose());

  testWidgets('mounted framing fields follow a target set on the provider', (
    tester,
  ) async {
    const target = FramingTarget(
      name: 'M31',
      raHours: 0.7123,
      decDegrees: 41.269,
    );
    late _SeededFramingNotifier framing;
    final handle = await pumpAppScreen(
      tester,
      const FramingView(),
      size: const Size(1600, 900),
      settle: false,
      extraOverrides: [
        framingProvider.overrideWith((ref) {
          framing = _SeededFramingNotifier(
            ref,
            FramingState(
              surveyImageBytes: Uint8List.fromList(const [0]),
              surveyImage: survey,
              previewFovDegrees: 0.5,
              showCardinalDirections: false,
              showGrid: false,
            ),
          );
          return framing;
        }),
        framingFOVProvider.overrideWith(
          (ref) async => const FramingEquipmentResult(
            status: FramingEquipmentStatus.ready,
            equipment: _equipment,
            profileName: 'Test Profile',
          ),
        ),
        hipsFramingEnabledProvider.overrideWith((ref) => false),
      ],
    );
    addTearDown(handle.database.close);
    await tester.pump();

    // ignore: invalid_use_of_protected_member
    framing.state = framing.state.copyWith(target: target);
    await tester.pump();

    final texts = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .map((field) => field.controller.text)
        .toList();
    expect(texts, contains(target.name));
    expect(texts, contains(target.raFormatted));
    expect(texts, contains(target.decFormatted));
  });
}
