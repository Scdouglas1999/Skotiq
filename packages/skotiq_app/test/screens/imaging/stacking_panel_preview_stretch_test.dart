// The stacked preview must render through the app's shared auto-stretch, not
// through a local linear min/max map.
//
// A linear map renders a real stacked light as a black rectangle: on a star
// field the maximum is a saturated star and the minimum is the sky floor, so
// every background pixel and every faint star lands on 0-3 of 255. On a
// 1000 +/- 50 ADU sky with saturated stars the median output byte is 0.
//
// The stretch itself is the MAD-based STF in Rust (imaging/src/stretch.rs,
// Rust-tested); what is pinned here is that the preview asks for it, with the
// right channel layout, and displays exactly what it returns.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Records what the preview asked for and answers with a flat, unmistakable
/// grey so the rendered pixels can be traced back to this stretch.
class _RecordingStretch {
  final calls = <({int width, int height, int channels, int samples})>[];

  static const int marker = 137;

  Uint8List render({
    required int width,
    required int height,
    required List<int> data,
    required int channels,
  }) {
    calls.add((
      width: width,
      height: height,
      channels: channels,
      samples: data.length,
    ));
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      rgba[i * 4] = marker;
      rgba[i * 4 + 1] = marker;
      rgba[i * 4 + 2] = marker;
      rgba[i * 4 + 3] = 255;
    }
    return rgba;
  }
}

class _PreviewNotifier extends LiveStackingNotifier {
  _PreviewNotifier(super.ref, LiveStackingState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

Future<_RecordingStretch> _pumpPreview(
  WidgetTester tester, {
  required Uint16List previewData,
  required int width,
  required int height,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 2000);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final stretch = _RecordingStretch();
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      stackedPreviewStretchProvider.overrideWithValue(stretch.render),
      liveStackingProvider.overrideWith(
        (ref) => _PreviewNotifier(
          ref,
          LiveStackingState(
            status: LiveStackingStatus.running,
            stats: const LiveStackingStats(
              stackedFrameCount: 8,
              totalFramesAttempted: 8,
            ),
            previewData: previewData,
            previewWidth: width,
            previewHeight: height,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: StackingPanel(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  // Decoding the RGBA buffer into a ui.Image goes through the engine, which
  // only runs under runAsync.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  return stretch;
}

Future<Uint8List> _renderedPixels(WidgetTester tester) async {
  final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
  // toByteData is resolved by the engine, so it only completes under runAsync.
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mono preview renders the shared auto-stretch of 1 channel',
      (tester) async {
    final data = Uint16List(16);
    for (var i = 0; i < data.length; i++) {
      data[i] = 1000 + i;
    }

    final stretch = await _pumpPreview(
      tester,
      previewData: data,
      width: 4,
      height: 4,
    );

    expect(stretch.calls, hasLength(1));
    expect(stretch.calls.single.channels, 1);
    expect(stretch.calls.single.width, 4);
    expect(stretch.calls.single.height, 4);

    final pixels = await _renderedPixels(tester);
    expect(pixels[0], _RecordingStretch.marker,
        reason: 'the preview must display the shared stretch, not its own map');
    expect(pixels[1], _RecordingStretch.marker);
    expect(pixels[2], _RecordingStretch.marker);
    expect(pixels[3], 255);
  });

  testWidgets('OSC preview asks the shared auto-stretch for 3 channels',
      (tester) async {
    final data = Uint16List(16 * 3);
    for (var i = 0; i < data.length; i++) {
      data[i] = 500 + i;
    }

    final stretch = await _pumpPreview(
      tester,
      previewData: data,
      width: 4,
      height: 4,
    );

    expect(stretch.calls, hasLength(1));
    expect(stretch.calls.single.channels, 3);
    expect(stretch.calls.single.samples, 48);
  });
}
