// The region tool's two drags, and the one property that must hold for them:
// the rectangles are in IMAGE pixels, so the same structure marked at a
// different zoom and pan produces the same goal.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_geometry.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_region_layer.dart';
import 'package:skotiq_app/utils/preview_transform.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_test_doubles.dart';

/// Where the layer is laid out on the 800 x 600 test surface.
///
/// It takes most of the surface so the drags below can stay clear of the
/// instruction strip the tool floats over the top of the canvas — a drag that
/// starts on the strip is a press on its Cancel button, not a region.
const Size _layerSize = Size(600, 500);
const Offset _layerOrigin = Offset(100, 50);

Future<ProviderContainer> _pumpLayer(
  WidgetTester tester, {
  required double zoomLevel,
  required Offset imageOffset,
}) async {
  final container = ProviderContainer(
    overrides: <Override>[
      depthLockBackendProvider.overrideWithValue(FakeDepthLockBackend()),
      depthLockEventStreamProvider.overrideWithValue(
        const Stream<SkotiqEvent>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(depthLockRegionToolActiveProvider.notifier).state = true;

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: _layerSize.width,
              height: _layerSize.height,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: DepthLockRegionLayer(
                      zoomLevel: zoomLevel,
                      imageOffset: imageOffset,
                      imageSize: const Size(4144, 2822),
                      geometry: null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// Drag from one IMAGE point to another, through the transform the preview
/// would be using.
Future<void> _dragImageRect(
  WidgetTester tester, {
  required Offset from,
  required Offset to,
  required double zoomLevel,
  required Offset imageOffset,
}) async {
  Offset screen(Offset imagePoint) =>
      _layerOrigin +
      imageToViewport(
        imagePoint: imagePoint,
        imageOffset: imageOffset,
        zoomLevel: zoomLevel,
      );

  final Offset begin = screen(from);
  final Offset end = screen(to);
  final gesture = await tester.startGesture(begin);
  // Several steps, not one: the pan recogniser only accepts the gesture once
  // it has travelled past the platform's pan slop, and a single jump to the
  // halfway point is below that slop at a small display scale — which would
  // deliver a start and an end with no updates in between.
  for (var step = 1; step <= 4; step++) {
    await gesture.moveTo(Offset.lerp(begin, end, step / 4)!);
    await tester.pump();
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  _handleGeometryTests();
  _editingTests();

  testWidgets('the first drag is the structure and the second the background', (
    tester,
  ) async {
    const zoom = 1.0;
    const offset = Offset.zero;
    final container = await _pumpLayer(
      tester,
      zoomLevel: zoom,
      imageOffset: offset,
    );

    expect(
      container.read(depthLockRegionDraftProvider).step,
      DepthLockRegionStep.structure,
    );

    await _dragImageRect(
      tester,
      from: const Offset(60, 180),
      to: const Offset(180, 260),
      zoomLevel: zoom,
      imageOffset: offset,
    );
    var draft = container.read(depthLockRegionDraftProvider);
    expect(draft.structure, isNotNull);
    expect(draft.background, isNull);
    expect(draft.step, DepthLockRegionStep.background);

    await _dragImageRect(
      tester,
      from: const Offset(300, 180),
      to: const Offset(420, 260),
      zoomLevel: zoom,
      imageOffset: offset,
    );
    draft = container.read(depthLockRegionDraftProvider);
    expect(draft.background, isNotNull);
    expect(draft.step, DepthLockRegionStep.ready);
    expect(draft.structure!.left, closeTo(60, 0.5));
    expect(draft.background!.left, closeTo(300, 0.5));
  });

  testWidgets(
      'the same structure marked zoomed and panned gives the same '
      'image rectangle', (tester) async {
    const Offset from = Offset(60, 180);
    const Offset to = Offset(180, 260);

    final unzoomed = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    await _dragImageRect(
      tester,
      from: from,
      to: to,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    final flat = unzoomed.read(depthLockRegionDraftProvider).structure!;

    // The same sky, seen at 2x with the frame panned: different pixels under
    // the pointer, same rectangle on the image.
    const double zoom = 2.0;
    const Offset pan = Offset(-40, -30);
    final zoomed = await _pumpLayer(
      tester,
      zoomLevel: zoom,
      imageOffset: pan,
    );
    await _dragImageRect(
      tester,
      from: from,
      to: to,
      zoomLevel: zoom,
      imageOffset: pan,
    );
    final magnified = zoomed.read(depthLockRegionDraftProvider).structure!;

    expect(magnified.left, closeTo(flat.left, 0.5));
    expect(magnified.top, closeTo(flat.top, 0.5));
    expect(magnified.right, closeTo(flat.right, 0.5));
    expect(magnified.bottom, closeTo(flat.bottom, 0.5));
  });

  testWidgets('a click that never became a drag is not a region', (
    tester,
  ) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    await _dragImageRect(
      tester,
      from: const Offset(100, 200),
      to: const Offset(102, 201),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    expect(container.read(depthLockRegionDraftProvider).isEmpty, isTrue);
  });

  testWidgets('cancelling leaves the tool and discards the boxes', (
    tester,
  ) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    await _dragImageRect(
      tester,
      from: const Offset(60, 180),
      to: const Offset(180, 260),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    expect(container.read(depthLockRegionDraftProvider).structure, isNotNull);

    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(container.read(depthLockRegionToolActiveProvider), isFalse);
    expect(container.read(depthLockRegionDraftProvider).isEmpty, isTrue);
  });

  testWidgets('the prompt names the box it is waiting for', (tester) async {
    await _pumpLayer(tester, zoomLevel: 1.0, imageOffset: Offset.zero);
    expect(
      find.textContaining('Drag a box over the faint structure'),
      findsOneWidget,
    );

    await _dragImageRect(
      tester,
      from: const Offset(60, 180),
      to: const Offset(180, 260),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    expect(
      find.textContaining('second box over nearby blank sky'),
      findsOneWidget,
    );
  });
}

/// Pure handle arithmetic. The widget tests below prove the pointer reaches
/// these; this proves they are right.
void _handleGeometryTests() {
  const rect = Rect.fromLTRB(100, 200, 300, 400);

  test('each handle sits where its name says', () {
    expect(
      depthLockHandlePosition(rect, DepthLockHandle.topLeft),
      const Offset(100, 200),
    );
    expect(
      depthLockHandlePosition(rect, DepthLockHandle.bottomRight),
      const Offset(300, 400),
    );
    expect(
      depthLockHandlePosition(rect, DepthLockHandle.top),
      const Offset(200, 200),
    );
    expect(
      depthLockHandlePosition(rect, DepthLockHandle.left),
      const Offset(100, 300),
    );
  });

  test('an edge handle moves only its own edge', () {
    final resized = depthLockResize(
      rect,
      DepthLockHandle.top,
      const Offset(999, 150),
    );
    expect(resized, const Rect.fromLTRB(100, 150, 300, 400));
  });

  test('a corner handle moves both of its edges', () {
    final resized = depthLockResize(
      rect,
      DepthLockHandle.bottomRight,
      const Offset(260, 350),
    );
    expect(resized, const Rect.fromLTRB(100, 200, 260, 350));
  });

  test('dragging an edge past its opposite flips rather than inverts', () {
    final resized = depthLockResize(
      rect,
      DepthLockHandle.left,
      const Offset(360, 0),
    );
    expect(resized.left, 300);
    expect(resized.right, 360);
    expect(resized.width, greaterThan(0));
  });

  test('a corner wins the shared hit area with its edges', () {
    expect(
      depthLockHandleAt(rect, const Offset(103, 203), tolerance: 12),
      DepthLockHandle.topLeft,
    );
    expect(
      depthLockHandleAt(rect, const Offset(200, 203), tolerance: 12),
      DepthLockHandle.top,
    );
    expect(depthLockHandleAt(rect, rect.center, tolerance: 12), isNull);
  });

  test('moving translates without resizing', () {
    final moved = depthLockMove(rect, const Offset(-40, 15));
    expect(moved, const Rect.fromLTRB(60, 215, 260, 415));
  });
}

/// Adjusting rectangles that already exist. All assertions are in IMAGE
/// pixels, because that is the only frame in which a region means anything.
void _editingTests() {
  testWidgets('dragging inside a box moves it, in image pixels', (
    tester,
  ) async {
    const zoom = 2.0;
    const pan = Offset(-40, -30);
    final container = await _pumpLayer(
      tester,
      zoomLevel: zoom,
      imageOffset: pan,
    );
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: const Rect.fromLTRB(100, 200, 200, 280),
          background: const Rect.fromLTRB(300, 200, 400, 280),
        );
    await tester.pump();

    // Grab the structure box well inside it and carry it 30 image pixels
    // right and 20 down.
    await _dragImageRect(
      tester,
      from: const Offset(150, 240),
      to: const Offset(180, 260),
      zoomLevel: zoom,
      imageOffset: pan,
    );

    final moved = container.read(depthLockRegionDraftProvider).structure!;
    expect(moved.left, closeTo(130, 0.5));
    expect(moved.top, closeTo(220, 0.5));
    expect(moved.width, closeTo(100, 0.5));
    expect(moved.height, closeTo(80, 0.5));
    // The other box is untouched.
    expect(
      container.read(depthLockRegionDraftProvider).background,
      const Rect.fromLTRB(300, 200, 400, 280),
    );
  });

  testWidgets('dragging a corner resizes that box only', (tester) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: const Rect.fromLTRB(100, 200, 200, 280),
          background: const Rect.fromLTRB(300, 200, 400, 280),
        );
    await tester.pump();

    await _dragImageRect(
      tester,
      from: const Offset(200, 280),
      to: const Offset(260, 340),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );

    final resized = container.read(depthLockRegionDraftProvider).structure!;
    expect(resized.left, closeTo(100, 0.5));
    expect(resized.top, closeTo(200, 0.5));
    expect(resized.right, closeTo(260, 0.5));
    expect(resized.bottom, closeTo(340, 0.5));
  });

  testWidgets('a handle is as easy to grab zoomed out as zoomed in', (
    tester,
  ) async {
    // At 0.25x a 12 screen-pixel tolerance is 48 image pixels, so a grab that
    // lands 20 image pixels off the corner still takes the corner.
    const zoom = 0.25;
    final container = await _pumpLayer(
      tester,
      zoomLevel: zoom,
      imageOffset: Offset.zero,
    );
    // Placed low on the canvas so the grab is nowhere near the instruction
    // strip the tool floats over the top of the frame.
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: const Rect.fromLTRB(1000, 1000, 1400, 1400),
          background: const Rect.fromLTRB(1800, 1000, 2200, 1400),
        );
    await tester.pump();

    // 20 image pixels off the corner — five screen pixels at this scale, and
    // well inside the 12-screen-pixel grip.
    await _dragImageRect(
      tester,
      from: const Offset(1414, 1414),
      to: const Offset(1700, 1700),
      zoomLevel: zoom,
      imageOffset: Offset.zero,
    );

    final resized = container.read(depthLockRegionDraftProvider).structure!;
    expect(resized.right, closeTo(1700, 4));
    expect(resized.bottom, closeTo(1700, 4));
    expect(resized.left, closeTo(1000, 0.5));
  });

  testWidgets('collapsing a box puts it back rather than storing a sliver', (
    tester,
  ) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    const original = Rect.fromLTRB(100, 200, 200, 280);
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: original,
          background: const Rect.fromLTRB(300, 200, 400, 280),
        );
    await tester.pump();

    // Drag the right edge almost onto the left one.
    await _dragImageRect(
      tester,
      from: const Offset(200, 240),
      to: const Offset(103, 240),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );

    expect(container.read(depthLockRegionDraftProvider).structure, original);
  });

  testWidgets('Use these announces the boxes are finished', (tester) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    expect(container.read(depthLockRegionCommitProvider), 0);
    expect(find.widgetWithText(SkotiqButton, 'Use these'), findsNothing);

    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: const Rect.fromLTRB(100, 200, 200, 280),
          background: const Rect.fromLTRB(300, 200, 400, 280),
        );
    await tester.pump();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Use these'));
    await tester.pump();
    expect(container.read(depthLockRegionCommitProvider), 1);
    // The boxes survive the commit: the editor may yet be cancelled.
    expect(container.read(depthLockRegionDraftProvider).isEmpty, isFalse);
  });

  testWidgets('a handle under the instruction strip can still be grabbed', (
    tester,
  ) async {
    // The strip floats over the top of the frame, which is exactly where a
    // region's top edge usually is. While it was hit-testable it swallowed
    // every grab beneath it, and a handle under it could not be taken at all.
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    // A box whose top-left grip sits under the caption plate: the strip starts
    // 16 px below the top of the layer and the plate is around 50 px tall.
    const under = Rect.fromLTRB(220, 40, 420, 260);
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: under,
          background: const Rect.fromLTRB(460, 40, 560, 260),
        );
    await tester.pump();

    await _dragImageRect(
      tester,
      from: const Offset(220, 40),
      to: const Offset(160, 120),
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );

    final resized = container.read(depthLockRegionDraftProvider).structure!;
    expect(resized.left, closeTo(160, 1));
    expect(resized.top, closeTo(120, 1));
    expect(resized.right, closeTo(420, 0.5));
  });

  testWidgets('cancelling clears the edit target as well as the boxes', (
    tester,
  ) async {
    final container = await _pumpLayer(
      tester,
      zoomLevel: 1.0,
      imageOffset: Offset.zero,
    );
    container.read(depthLockRegionEditTargetProvider.notifier).state = 'goal-1';
    container.read(depthLockRegionDraftProvider.notifier).load(
          structure: const Rect.fromLTRB(100, 200, 200, 280),
          background: const Rect.fromLTRB(300, 200, 400, 280),
        );
    await tester.pump();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
    await tester.pump();

    expect(container.read(depthLockRegionEditTargetProvider), isNull);
    expect(container.read(depthLockRegionDraftProvider).isEmpty, isTrue);
    expect(container.read(depthLockRegionToolActiveProvider), isFalse);
  });
}
