// Widget tests for the Stack Result viewer screen and the Stack & Share
// launcher dialog (component C9).
//
// These exercise the UI surfaces with overridden providers so they never touch
// the Rust dynamic library or platform channels:
//  * `stackResultViewerProvider` is overridden with a canned
//    `StackAndShareResult`.
//  * `stackAndShareProvider` is overridden with a fake notifier carrying a small
//    in-memory RGBA buffer (so the viewer renders without a native re-stretch)
//    and recording `runForSession` invocations.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/stack_result/stack_and_share_dialog.dart';
import 'package:skotiq_app/screens/stack_result/stack_result_screen.dart';
import 'package:skotiq_app/widgets/astro_image_viewer.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The stretch-engine seam type is needed to stub the colour STF in the result
// viewer without loading the native dynamic library. (Matches the screen's own
// implementation-import precedent.)
// ignore: implementation_imports
import 'package:skotiq_core/src/services/stacking_engine_seam.dart'
    show LinearFrameData, StackingEngineSeam;
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A stretch-engine seam that records the channel count it was asked to
/// auto-stretch and returns a constant RGBA buffer, so the colour vs mono branch
/// is observable without touching native code.
class _RecordingStretchSeam implements StackingEngineSeam {
  int? lastChannels;

  @override
  Uint8List autoStretch({
    required int width,
    required int height,
    required List<int> data,
    int channels = 1,
  }) {
    lastChannels = channels;
    final out = Uint8List(width * height * 4);
    for (var i = 3; i < out.length; i += 4) {
      out[i] = 255;
    }
    return out;
  }

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

/// A fake orchestrator notifier that starts in a caller-supplied state and
/// records every [runForSession] call instead of driving the real pipeline.
class _FakeStackAndShareNotifier extends StackAndShareNotifier {
  _FakeStackAndShareNotifier(super.ref, StackAndShareState initial) {
    state = initial;
  }

  int runCount = 0;
  int? lastSessionId;
  StackAndShareConfig? lastConfig;

  @override
  Future<void> runForSession(int sessionId,
      {StackAndShareConfig? config}) async {
    runCount++;
    lastSessionId = sessionId;
    lastConfig = config;
  }
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// Build a canned 2x2 result with a matching RGBA buffer.
StackAndShareResult _cannedResult({int id = 7}) {
  return StackAndShareResult(
    id: id,
    sessionId: 1,
    targetName: 'M51',
    width: 2,
    height: 2,
    framesStacked: 18,
    framesAttempted: 20,
    integrationSecs: 5400, // 01:30:00
    avgAlignmentResidual: 0.42,
    filter: 'L',
    createdAt: DateTime(2026, 5, 28),
    stats: const LiveStackingStats(stackedFrameCount: 18),
  );
}

Uint8List _rgba2x2() {
  // 4 pixels x RGBA, mid-gray opaque.
  final out = Uint8List(2 * 2 * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = 128;
    out[i + 1] = 128;
    out[i + 2] = 128;
    out[i + 3] = 255;
  }
  return out;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required StackAndShareResult result,
  StackAndShareState? liveState,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final effectiveLive = liveState ??
      StackAndShareState(
        progress:
            const StackAndShareProgress(phase: StackAndSharePhase.complete),
        result: result,
        resultRgba: _rgba2x2(),
        resultWidth: result.width,
        resultHeight: result.height,
      );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        stackResultViewerProvider(result.id!)
            .overrideWith((ref) async => result),
        stackAndShareProvider.overrideWith(
          (ref) => _FakeStackAndShareNotifier(ref, effectiveLive),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: StackResultScreen(resultId: result.id!),
      ),
    ),
  );
  // Let the FutureProvider resolve and the image decode.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<_FakeStackAndShareNotifier> _pumpDialog(
  WidgetTester tester, {
  required StackSelectionSummary selection,
  StackAndShareState? liveState,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 1200);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late _FakeStackAndShareNotifier notifier;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        // No connected camera in these tests, so the dialog shows the manual
        // OSC controls directly (no auto-detected colour summary). Overriding
        // keeps the pump hermetic — no backend / native query.
        connectedCameraIdProvider.overrideWithValue(null),
        stackAndShareProvider.overrideWith((ref) {
          notifier = _FakeStackAndShareNotifier(
            ref,
            liveState ?? const StackAndShareState(),
          );
          return notifier;
        }),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => StackAndShareDialog.show(
                  context,
                  sessionId: 42,
                  selection: selection,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StackResultScreen', () {
    testWidgets('remote mode renders host metadata and preview',
        (tester) async {
      final backend = NetworkBackend(
        serverHost: '10.0.0.8',
        serverPort: 8080,
        webSocketPort: 8080,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);
      final result = _cannedResult();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            remoteStackResultProvider(7).overrideWith(
              (ref) async => RemoteStackedResult(
                result: result,
                previewAvailable: true,
              ),
            ),
            stackResultPreviewProvider(7).overrideWith(
              (ref) async => _rgba2x2(),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const StackResultScreen(resultId: 7),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('M51'), findsOneWidget);
      expect(find.byType(AstroImageViewer), findsOneWidget);
      expect(find.text('Open this stacked result on the imaging host'),
          findsNothing);
    });

    testWidgets('renders header title, subtitle, and stats', (tester) async {
      final result = _cannedResult();
      await _pumpScreen(tester, result: result);

      // Header title is the target name.
      expect(find.text('M51'), findsOneWidget);
      // The three headline numbers are Readouts now (05 §3), not a subtitle.
      expect(find.text('18'), findsWidgets);
      expect(find.text('STACKED'), findsOneWidget);
      expect(find.text('01:30:00'), findsWidgets);
      expect(find.text('INTEGRATED'), findsOneWidget);

      // The rejected count is the third Readout; the residual stays in the
      // key/value list below.
      expect(find.text('REJECTED'), findsOneWidget);
      expect(find.text('2'), findsWidgets); // 20 attempted - 18 stacked.
      expect(find.text('Avg residual'), findsOneWidget);
      expect(find.text('0.42 px'), findsOneWidget);
    });

    testWidgets('the export menu carries every export action', (tester) async {
      // The header keeps one primary (Refine in Darkroom) and one export menu
      // (05 §5); the four export actions live inside the menu.
      await _pumpScreen(tester, result: _cannedResult());

      final menu = find.byKey(const ValueKey('stack_result_export_menu'));
      expect(menu, findsOneWidget);
      await tester.tap(menu);
      // Not pumpAndSettle: the viewer keeps an animation alive, so settle
      // never returns. A few frames open the popup.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('Export PNG'), findsOneWidget);
      expect(find.text('Export JPEG'), findsOneWidget);
      expect(find.text('Share card'), findsOneWidget);
      expect(find.text('AstroBin'), findsOneWidget);
    });

    testWidgets('renders the stretch dropdown', (tester) async {
      // Use the orchestrator's already-stretched RGBA (no mono buffer) so the
      // viewer renders without invoking the native STF re-stretch. The dropdown
      // is still present (disabled, with the explanatory caption) so the control
      // is verifiable in a headless test.
      await _pumpScreen(tester, result: _cannedResult());

      expect(find.text('Stretch'), findsOneWidget);
      expect(find.byType(SkotiqDropdown), findsOneWidget);
      expect(find.text('Auto (STF)'), findsOneWidget);
    });

    testWidgets(
        'colour result (channels==3) auto-stretches via the colour STF '
        'branch', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final result = _cannedResult(id: 11).copyWith(isColor: true, channels: 3);
      // 2x2 interleaved RGB16 buffer (width*height*3 = 12 samples).
      final colorBuffer = Uint16List.fromList(
        List<int>.generate(2 * 2 * 3, (i) => i * 1000),
      );
      final liveState = StackAndShareState(
        progress:
            const StackAndShareProgress(phase: StackAndSharePhase.complete),
        result: result,
        resultMono: colorBuffer,
        resultChannels: 3,
        resultWidth: 2,
        resultHeight: 2,
      );
      final seam = _RecordingStretchSeam();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            stackResultViewerProvider(result.id!)
                .overrideWith((ref) async => result),
            stackAndShareProvider.overrideWith(
              (ref) => _FakeStackAndShareNotifier(ref, liveState),
            ),
            stackResultStretchEngineProvider.overrideWithValue(seam),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: StackResultScreen(resultId: result.id!),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The colour buffer was routed through the 3-channel STF branch, not the
      // mono `apiAutoStretchImage` path.
      expect(seam.lastChannels, 3);
    });

    testWidgets('shows EmptyState when the result is missing', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            stackResultViewerProvider(99).overrideWith(
              (ref) async =>
                  throw StateError('No stacked result found for id 99'),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const StackResultScreen(resultId: 99),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.text('Result not found'), findsOneWidget);
    });
  });

  group('StackAndShareDialog', () {
    StackSelectionSummary buildSelection() {
      return const StackSelectionSummary(
        selected: [
          StackedFrameSelection(imageId: 1, filePath: '/a.fits', filter: 'L'),
          StackedFrameSelection(imageId: 2, filePath: '/b.fits', filter: 'L'),
        ],
        perFilterCounts: {'L': 2},
        totalIntegrationSecs: 600,
        targetName: 'NGC 7000',
      );
    }

    testWidgets('renders switches, quality field, and Start', (tester) async {
      await _pumpDialog(tester, selection: buildSelection());

      // Title + summary.
      expect(find.text('Stack & Share'), findsOneWidget);
      expect(find.text('NGC 7000'), findsOneWidget);

      // Three switch rows: calibration, auto-stretch, and OSC / Color.
      expect(find.text('Apply calibration'), findsOneWidget);
      expect(find.text('Auto-stretch'), findsOneWidget);
      expect(find.text('OSC / Color'), findsOneWidget);
      expect(find.byType(SkotiqSwitchRow), findsNWidgets(3));

      // Quality-gate field.
      expect(find.text('Quality threshold'), findsOneWidget);
      expect(find.byType(SkotiqTextField), findsOneWidget);

      // OSC defaults to 'auto' (non-mono), so the Bayer-pattern and
      // demosaic-quality dropdowns are revealed (no live colour camera, so the
      // manual controls are shown directly rather than behind the auto-detected
      // override expander).
      expect(find.text('Bayer pattern'), findsOneWidget);
      expect(find.text('Demosaic quality'), findsOneWidget);
      expect(find.byType(SkotiqDropdown), findsNWidgets(2));

      // There is deliberately no stretch-*method* dropdown: the run stretches
      // the in-memory u16 result via the engine's STF path only, so a method
      // knob would offer choices that all yield the same output. See
      // StackAndShareConfig.
      expect(find.text('Stretch method'), findsNothing);

      // Start action present.
      expect(find.widgetWithText(SkotiqButton, 'Start'), findsOneWidget);
    });

    testWidgets('tapping Start invokes the notifier with the session id',
        (tester) async {
      final notifier = await _pumpDialog(tester, selection: buildSelection());

      await tester.tap(find.widgetWithText(SkotiqButton, 'Start'));
      await tester.pump();

      expect(notifier.runCount, 1);
      expect(notifier.lastSessionId, 42);
      // Default config flows through.
      expect(notifier.lastConfig, isNotNull);
      expect(notifier.lastConfig!.applyCalibration, isTrue);
      expect(notifier.lastConfig!.autoStretch, isTrue);
      // OSC defaults: auto sensor mode, no Bayer override (engine resolves from
      // the frame geometry), VNG demosaic.
      expect(notifier.lastConfig!.sensorMode, 'auto');
      expect(notifier.lastConfig!.bayerPatternOverride, isNull);
      expect(notifier.lastConfig!.demosaicQuality, 'vng');
    });

    testWidgets(
        'a bridge failure is shown as its sentence, with the raw union behind '
        'technical details', (tester) async {
      const raw = 'SkotiqError.imageError(field0: Failed to initialize '
          'stacker: Reference frame has only 0 stars, need at least 5 for '
          'alignment)';
      await _pumpDialog(
        tester,
        selection: buildSelection(),
        liveState: const StackAndShareState(
          progress: StackAndShareProgress(phase: StackAndSharePhase.error),
          errorMessage: raw,
        ),
      );

      // The operator sees the sentence, never the Dart union wrapper or the
      // flutter_rust_bridge positional-field label.
      expect(
        find.textContaining(
          'Reference frame has only 0 stars, need at least 5 for alignment',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('SkotiqError.imageError'), findsNothing);
      expect(find.textContaining('field0'), findsNothing);
      // …and a next step they can act on.
      expect(find.textContaining('Check focus'), findsOneWidget);

      // The raw text is still one tap away.
      expect(find.text(raw), findsNothing);
      await tester.tap(find.widgetWithText(
          SkotiqButton,
          'Technical '
          'details'));
      await tester.pumpAndSettle();
      expect(find.text(raw), findsOneWidget);
    });

    testWidgets('surfaces a LiveStackBusy error as an alert', (tester) async {
      const busyState = StackAndShareState(
        progress: StackAndShareProgress(phase: StackAndSharePhase.error),
        errorMessage:
            'LiveStackBusyException: Stop live stacking before running '
            'Stack-and-Share',
      );
      await _pumpDialog(
        tester,
        selection: buildSelection(),
        liveState: busyState,
      );

      // The banner sets title + message in one RichText, so match the widget
      // and its title span rather than a bare Text.
      expect(find.byType(SkotiqBanner), findsOneWidget);
      expect(
        find.byWidgetPredicate(
            (w) => w is SkotiqBanner && w.title == 'Live stacking is active'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Stop live stacking'),
        findsOneWidget,
      );
    });
  });
}
