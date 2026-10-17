// Scrolling the sub rail must not re-fetch a thumbnail it already has.
//
// The rail is a `GridView.builder`, so a cell is disposed the moment it leaves
// the viewport and rebuilt from scratch when it comes back. The thumbnail fetch
// lived in `_SubThumbnailState.initState` with no cache anywhere below it — the
// FFI backend re-reads and re-decodes the file, the network backend re-issues a
// full HTTP GET of `images/$id/thumbnail`. Reviewing a 300-sub night on a
// paired tablet therefore paid one round trip per tile, every time.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _ReviewController extends Mock implements SessionReviewController {
  @override
  RemoveListener addListener(
    void Function(SessionReviewState) listener, {
    bool fireImmediately = true,
  }) {
    return () {};
  }

  @override
  CullRecommendationOffer get cullRecommendationOffer =>
      CullRecommendationOffer.none;
}

/// Counts thumbnail requests per image id.
class _CountingBackend extends Mock implements ImagingBackend {
  final Map<int, int> requests = <int, int>{};

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    requests[imageId] = (requests[imageId] ?? 0) + 1;
    return Uint8List(0);
  }
}

DbCapturedImage _sub(int id) => DbCapturedImage(
      id: id,
      filePath: '/tmp/light-$id.fits',
      fileName: 'light-$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 15),
      createdAt: DateTime.utc(2026, 7, 15),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a recycled cell reuses the thumbnail it already fetched',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final backend = _CountingBackend();
    final subs = ValueNotifier<List<DbCapturedImage>>([_sub(7), _sub(8)]);
    addTearDown(subs.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [imagingBackendProvider.overrideWithValue(backend)],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ValueListenableBuilder<List<DbCapturedImage>>(
              valueListenable: subs,
              builder: (context, value, child) => SubCullRail(
                subs: value,
                controller: _ReviewController(),
                onTapSub: (_) {},
                onSetAccepted: (_, __) {},
                onBulkCull: ({hfrThreshold, qualityThreshold}) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(backend.requests[7], 1, reason: 'first mount fetches once');

    // Empty the rail, then bring the same subs back: exactly what scrolling a
    // tile out of the viewport and back does to its cell.
    subs.value = const [];
    await tester.pump();
    subs.value = [_sub(7), _sub(8)];
    await tester.pump();

    expect(
      backend.requests[7],
      1,
      reason: 'the bytes for sub 7 were already in hand',
    );
    expect(backend.requests[8], 1);
  });
}
