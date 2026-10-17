// Marking a region ON the stacked pixels.
//
// The stacker warps every frame into its reference sub's pixel grid, so a
// rectangle drawn on the stacked image is a rectangle in that sub's pixels.
// These tests hold that identity to account: the canvas hosts the tool, the
// rectangles come out in stack pixel coordinates whatever the zoom and pan,
// and the moment the two grids could disagree the tool is blocked.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_region_layer.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_selection.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack_canvas.dart';
import 'package:skotiq_app/screens/imaging/widgets/preview_viewport.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart'
    show stackedPreviewStretchProvider;
import 'package:skotiq_app/utils/preview_transform.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';
import 'depthlock_settings_dao_double.dart';

const int _stackWidth = 200;
const int _stackHeight = 150;
const String _referencePath = '/data/M51/L_0001.fits';

class _FakeLiveStacking extends LiveStackingNotifier {
  _FakeLiveStacking(super.ref, LiveStackingState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

/// A stretch that produces a correctly sized RGBA buffer without the native
/// library — the injection point `stackedPreviewStretchProvider` exists for.
Uint8List _flatStretch({
  required int width,
  required int height,
  required List<int> data,
  required int channels,
}) =>
    Uint8List(width * height * 4);

LiveStackingState _running({
  String? referencePath = _referencePath,
  int width = _stackWidth,
  int height = _stackHeight,
  bool withPreview = true,
}) =>
    LiveStackingState(
      status: LiveStackingStatus.running,
      referenceImagePath: referencePath,
      previewData: withPreview ? Uint16List(width * height) : null,
      previewWidth: withPreview ? width : 0,
      previewHeight: withPreview ? height : 0,
    );

DepthLockReferenceInfo _referenceInfo({
  int width = _stackWidth,
  int height = _stackHeight,
  bool monochrome = true,
  bool headerSolution = false,
}) =>
    DepthLockReferenceInfo(
      width: width,
      height: height,
      pixelType: 'U16',
      monochrome: monochrome,
      acquisition: depthLockAcquisitionFixture,
      geometry: headerSolution
          ? ReferenceGeometry(
              width: width,
              height: height,
              crval1: 90.0,
              crval2: 30.0,
              crpix1: width / 2.0 + 0.5,
              crpix2: height / 2.0 + 0.5,
              cd1_1: -2.0 / 3600.0,
              cd1_2: 0.0,
              cd2_1: 0.0,
              cd2_2: 2.0 / 3600.0,
            )
          : null,
    );

Future<ProviderContainer> _pumpCanvas(
  WidgetTester tester, {
  required FakeDepthLockBackend backend,
  LiveStackingState? stack,
  double zoomLevel = 1.0,
  Offset panOffset = Offset.zero,
  bool toolActive = true,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: <Override>[
      depthLockBackendProvider.overrideWithValue(backend),
      depthLockEventStreamProvider.overrideWithValue(
        const Stream<SkotiqEvent>.empty(),
      ),
      settingsDaoProvider.overrideWithValue(RecordingSettingsDao()),
      stackedPreviewStretchProvider.overrideWithValue(_flatStretch),
      liveStackingProvider.overrideWith(
        (ref) => _FakeLiveStacking(ref, stack ?? _running()),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(depthLockCanvasProvider.notifier).state =
      DepthLockCanvas.liveStack;
  container.read(depthLockRegionToolActiveProvider.notifier).state = toolActive;
  container.read(stackCanvasViewProvider.notifier).state = StackCanvasView(
    zoomLevel: zoomLevel,
    panOffset: panOffset,
  );

  // The stacked image is decoded through a real platform codec, so the pump
  // has to run under `runAsync` for that future to complete at all. It is
  // polled for rather than waited on for a fixed time, and `pumpAndSettle` is
  // avoided throughout: the "rendering" spinner is an endless animation, so
  // settling would simply time out.
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: LiveStackCanvas()),
        ),
      ),
    );
    for (var attempt = 0; attempt < 50; attempt++) {
      await tester.pump();
      if (find.byType(PreviewViewport).evaluate().isNotEmpty) break;
      await Future<void>.delayed(Duration.zero);
    }
  });
  await tester.pump();
  return container;
}

/// Drag between two STACK-pixel points, through the geometry the viewport
/// actually laid out.
Future<void> _dragStackRect(
  WidgetTester tester, {
  required Offset from,
  required Offset to,
  required double zoomLevel,
  required Offset panOffset,
}) async {
  final Rect viewport = tester.getRect(find.byType(PreviewViewport));
  final double fitScale = _fitScale(viewport.size);
  final double displayScale = fitScale * zoomLevel;
  final Offset imageOffset = computeImageOffset(
    viewportSize: viewport.size,
    imageSize: Size(_stackWidth.toDouble(), _stackHeight.toDouble()),
    zoomLevel: displayScale,
    panOffset: panOffset,
  );
  Offset screen(Offset stackPoint) =>
      viewport.topLeft +
      imageToViewport(
        imagePoint: stackPoint,
        imageOffset: imageOffset,
        zoomLevel: displayScale,
      );

  final Offset begin = screen(from);
  final Offset end = screen(to);
  final gesture = await tester.startGesture(begin);
  for (var step = 1; step <= 4; step++) {
    await gesture.moveTo(Offset.lerp(begin, end, step / 4)!);
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

double _fitScale(Size viewportSize) {
  final double byWidth = viewportSize.width / _stackWidth;
  final double byHeight = viewportSize.height / _stackHeight;
  final double fit = byWidth < byHeight ? byWidth : byHeight;
  return fit < 1.0 ? fit : 1.0;
}

void main() {
  testWidgets('the stacked image is a canvas with the region tool on it', (
    tester,
  ) async {
    await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
    );

    expect(find.byType(PreviewViewport), findsOneWidget);
    expect(find.byType(DepthLockRegionLayer), findsOneWidget);
    expect(
      find.textContaining('Drag a box over the faint structure'),
      findsOneWidget,
    );
  });

  testWidgets('two drags on the stack produce two rectangles', (tester) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
    );

    await _dragStackRect(
      tester,
      from: const Offset(20, 60),
      to: const Offset(80, 120),
      zoomLevel: 1.0,
      panOffset: Offset.zero,
    );
    await _dragStackRect(
      tester,
      from: const Offset(110, 60),
      to: const Offset(170, 120),
      zoomLevel: 1.0,
      panOffset: Offset.zero,
    );

    final draft = container.read(depthLockRegionDraftProvider);
    expect(draft.step, DepthLockRegionStep.ready);
    expect(draft.structure!.left, closeTo(20, 1));
    expect(draft.structure!.top, closeTo(60, 1));
    expect(draft.background!.left, closeTo(110, 1));
  });

  testWidgets('a rectangle is in stack pixels whatever the zoom and pan', (
    tester,
  ) async {
    const Offset from = Offset(30, 50);
    const Offset to = Offset(90, 110);

    final flat = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
    );
    await _dragStackRect(
      tester,
      from: from,
      to: to,
      zoomLevel: 1.0,
      panOffset: Offset.zero,
    );
    final unzoomed = flat.read(depthLockRegionDraftProvider).structure!;

    const double zoom = 2.5;
    const Offset pan = Offset(-35, 25);
    final zoomed = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
      zoomLevel: zoom,
      panOffset: pan,
    );
    await _dragStackRect(
      tester,
      from: from,
      to: to,
      zoomLevel: zoom,
      panOffset: pan,
    );
    final magnified = zoomed.read(depthLockRegionDraftProvider).structure!;

    expect(magnified.left, closeTo(unzoomed.left, 1));
    expect(magnified.top, closeTo(unzoomed.top, 1));
    expect(magnified.right, closeTo(unzoomed.right, 1));
    expect(magnified.bottom, closeTo(unzoomed.bottom, 1));
    // And it is the rectangle that was asked for, not merely a repeatable one.
    expect(magnified.left, closeTo(from.dx, 1));
    expect(magnified.bottom, closeTo(to.dy, 1));
  });

  testWidgets('a stack and a reference of different sizes is blocked', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      // The reference sub is the full sensor; the stack is a crop.
      backend: FakeDepthLockBackend()
        ..referenceInfo = _referenceInfo(width: 4144, height: 2822),
    );

    final selection = container.read(depthLockStackSelectionProvider);
    expect(selection.canSelect, isFalse);
    expect(
      selection.blocker,
      'The stack is 200 × 150 but its reference sub L_0001.fits is '
      '4144 × 2822. A region drawn here would not land on the reference '
      'frame, so DepthLock cannot anchor it.',
    );
    final mark = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Stop marking'),
    );
    expect(mark.onPressed, isNull);
  });

  testWidgets('a stack started without a file cannot anchor anything', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
      stack: _running(referencePath: null),
    );

    final selection = container.read(depthLockStackSelectionProvider);
    expect(selection.canSelect, isFalse);
    expect(selection.blocker, contains('was not started from a file'));
  });

  testWidgets('a stack with no frames yet says so', (tester) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
      stack: _running(withPreview: false),
    );

    expect(
      container.read(depthLockStackSelectionProvider).blocker,
      contains('no image yet'),
    );
    expect(find.text('Waiting for the first stacked frame'), findsOneWidget);
  });

  testWidgets('a colour reference sub is refused', (tester) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()
        ..referenceInfo = _referenceInfo(monochrome: false),
    );

    expect(
      container.read(depthLockStackSelectionProvider).blocker,
      contains('monochrome, linear data'),
    );
  });

  testWidgets('with a solved reference the tool is offered and explained', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
    );

    final selection = container.read(depthLockStackSelectionProvider);
    expect(selection.canSelect, isTrue);
    expect(selection.referencePath, _referencePath);
    expect(selection.isLiveStackReference, isTrue);
    // Neither a DB plate solve nor a header solution in this container: the
    // panel says so and names the remedy.
    expect(selection.wcs, isNull);
    expect(selection.geometry, isNull);
    expect(selection.advisory, contains('Neither Skotiq nor the file'));
  });

  testWidgets('a header solution on the reference sub draws and anchors', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()
        ..referenceInfo = _referenceInfo(headerSolution: true),
    );

    final selection = container.read(depthLockStackSelectionProvider);
    expect(selection.canSelect, isTrue);
    expect(selection.wcs, isNull, reason: 'no DB solve in this container');
    expect(selection.geometry, isNotNull, reason: 'the header solution draws');
    expect(selection.advisory, contains('through its own header solution'));
  });

  testWidgets('the active selection follows the tab, not the canvas widget', (
    tester,
  ) async {
    final container = await _pumpCanvas(
      tester,
      backend: FakeDepthLockBackend()..referenceInfo = _referenceInfo(),
    );

    expect(
      container.read(depthLockActiveSelectionProvider).referencePath,
      _referencePath,
    );

    container.read(depthLockCanvasProvider.notifier).state =
        DepthLockCanvas.liveView;
    // The live view has no frame in this container, so the active answer
    // changes with the tab rather than staying on the stack's — and it points
    // at the sub to open rather than at the stack.
    expect(
      container.read(depthLockActiveSelectionProvider).blocker,
      contains('Open that sub in the viewer'),
    );
  });
}
