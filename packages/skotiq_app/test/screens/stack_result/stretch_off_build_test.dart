// The display stretch must not run inside `build`.
//
// `_resolveDisplayRgba` was called from the build path and, on a cold cache,
// rendered the whole image inline: two full passes over the integrated buffer
// plus a `width * height * 4` allocation. For a 6000x4000 master that is 48
// million loop iterations and a 96 MB allocation on the UI isolate, during
// layout, with no progress indication — a multi-hundred-millisecond frame stall
// every time a result opens or the stretch is toggled.

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/stack_result/stack_result_screen.dart';
import 'package:skotiq_app/widgets/astro_image_viewer.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/stacking_engine_seam.dart'
    show LinearFrameData, StackingEngineSeam;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A stretch seam that returns a constant RGBA buffer without the native STF.
class _StubSeam implements StackingEngineSeam {
  @override
  Uint8List autoStretch({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) =>
      Uint8List(width * height * 4);

  @override
  bool isActive() => false;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    required LiveStackingConfig config,
  }) async =>
      const LiveStackingStats();

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    required LiveStackingConfig config,
  }) async =>
      const LiveStackingStats();

  @override
  Future<LinearFrameData> readLinearFrame(String filePath) async =>
      const LinearFrameData(
        width: 0,
        height: 0,
        linearData: <double>[],
        bayerPattern: null,
      );

  @override
  Future<void> stop() async {}
}

class _FakeStackAndShare extends StackAndShareNotifier {
  _FakeStackAndShare(super.ref, StackAndShareState initial) {
    state = initial;
  }
}

StackAndShareResult _result() => StackAndShareResult(
      id: 21,
      targetName: 'Veil',
      sessionId: 1,
      framesStacked: 12,
      framesAttempted: 12,
      integrationSecs: 1440,
      avgAlignmentResidual: 0.4,
      width: 2,
      height: 2,
      channels: 3,
      isColor: true,
      createdAt: DateTime.utc(2026, 8, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the first frame does not carry the stretched image',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final result = _result();
    final buffer =
        Uint16List.fromList(List<int>.generate(2 * 2 * 3, (i) => i * 1000));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          stackResultViewerProvider(result.id!)
              .overrideWith((ref) async => result),
          stackAndShareProvider.overrideWith(
            (ref) => _FakeStackAndShare(
              ref,
              StackAndShareState(
                progress: const StackAndShareProgress(
                  phase: StackAndSharePhase.complete,
                ),
                result: result,
                resultMono: buffer,
                resultChannels: 3,
                resultWidth: 2,
                resultHeight: 2,
              ),
            ),
          ),
          stackResultStretchEngineProvider.overrideWithValue(_StubSeam()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: StackResultScreen(resultId: result.id!),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byType(AstroImageViewer),
      findsNothing,
      reason: 'pixels produced during this frame means the stretch ran inside '
          'build, which is the stall',
    );

    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byType(AstroImageViewer),
      findsOneWidget,
      reason: 'and the render must still land, one frame later',
    );
  });

  test('the linear stretches survive the isolate hop unchanged', () async {
    // 2x2 mono, then 2x2 interleaved RGB16. Byte-for-byte equality across the
    // hop is what makes moving them off the UI isolate behaviour-preserving:
    // a closure that captured anything non-sendable would throw instead.
    final mono = Uint16List.fromList([0, 100, 200, 65535]);
    expect(
      await Isolate.run(() => renderLinearGrayRgba(mono)),
      renderLinearGrayRgba(mono),
    );

    final rgb = Uint16List.fromList(
      List<int>.generate(2 * 2 * 3, (i) => i * 1000),
    );
    expect(
      await Isolate.run(() => renderLinearColorRgba(rgb, 4)),
      renderLinearColorRgba(rgb, 4),
    );
  });

  test('the linear mono stretch maps the extent onto 0..255', () {
    final rgba = renderLinearGrayRgba(Uint16List.fromList([100, 100, 600]));
    // min 100, max 600 -> span 500; 0, 0, 255.
    expect(rgba.sublist(0, 4), [0, 0, 0, 255]);
    expect(rgba.sublist(8, 12), [255, 255, 255, 255]);
  });

  test('the linear colour stretch balances each channel on its own extent', () {
    // One pixel at each channel's floor, one at its ceiling.
    final rgb = Uint16List.fromList([10, 20, 30, 110, 220, 330]);
    final rgba = renderLinearColorRgba(rgb, 2);
    expect(rgba.sublist(0, 4), [0, 0, 0, 255]);
    expect(rgba.sublist(4, 8), [255, 255, 255, 255]);
  });
}
