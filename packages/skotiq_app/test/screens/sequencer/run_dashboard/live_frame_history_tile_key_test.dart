// Capturing one frame must not refetch every thumbnail already on screen.
//
// The history column renders `images.reversed` (newest-first), so every frame
// that lands shifts each tile's index by one. With no `key` on the tile,
// Flutter reuses elements by POSITION: tile 0 keeps the element holding the
// previous frame and `didUpdateWidget` sees a different `image.id`, so it
// re-runs `_loadBytes()`. One capture then costs up to 24 `getImageThumbnail`
// calls — over HTTP on a remote/Pi session, the burst shape that trips request
// timeouts.
//
// The assertion is on the BACKEND CALL COUNT, not on the widget tree, because
// the call count is the cost the operator actually pays.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/live_frame_panel.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

/// Counts thumbnail fetches per image id. Every other member is unused by the
/// history column, so `noSuchMethod` would only hide a real call — the tile is
/// deliberately given a backend that implements exactly what it may touch.
class _CountingImagingBackend implements ImagingBackend {
  final List<int> thumbnailRequests = [];

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    thumbnailRequests.add(imageId);
    return Uint8List(0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CapturedImage _frame(int id) => CapturedImage(
      id: '$id',
      filePath: '/tmp/skotiq_captures/light-$id.fits',
      capturedAt: DateTime.utc(2026, 8, 11, 22, id),
      settings: const ExposureSettings(
        exposureTime: 120,
        gain: 100,
        offset: 10,
        filter: 'L',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a newly-captured frame does not refetch the existing thumbnails',
      (tester) async {
    final backend = _CountingImagingBackend();
    final frames = StateProvider<List<CapturedImage>>(
      (ref) => List.generate(6, (i) => _frame(i)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          imagingBackendProvider.overrideWithValue(backend),
          recentSessionFramesProvider.overrideWith((ref) => ref.watch(frames)),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SizedBox(
              // Wide enough to clear the history breakpoint (320), tall enough
              // that every one of the six tiles is laid out.
              width: 640,
              height: 900,
              child: RunDashboardLiveFrame(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.thumbnailRequests.toSet(), {0, 1, 2, 3, 4, 5},
        reason: 'first paint fetches each visible frame exactly once');
    backend.thumbnailRequests.clear();

    // One more frame lands — every existing tile shifts down by one index.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RunDashboardLiveFrame)),
    );
    container.read(frames.notifier).state = List.generate(7, (i) => _frame(i));
    await tester.pumpAndSettle();

    expect(backend.thumbnailRequests, [6],
        reason: 'only the new frame is unknown; the six already-loaded '
            'thumbnails must be reused, not refetched');
  });
}
