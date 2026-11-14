import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

CapturedImageData frame(Uint16List raw) => CapturedImageData(
  width: raw.length,
  height: 1,
  displayData: Uint8List(0),
  histogram: List<int>.filled(256, 3),
  stats: const ImageStats(),
  capturedAt: DateTime.utc(2026, 11, 14),
  settings: const ExposureSettings(exposureTime: 2, gain: 0, offset: 0),
  rawU16: raw,
  rawLoadStatus: RawLoadStatus.ready,
);

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  Future<List<int>> waitForRaw() {
    final ready = Completer<List<int>>();
    final subscription = container.listen(previewDisplayHistogramProvider, (
      _,
      next,
    ) {
      if (next != null && next.isRaw && !ready.isCompleted) {
        ready.complete(next.bins);
      }
    }, fireImmediately: true);
    addTearDown(subscription.close);
    return ready.future;
  }

  test(
    'raw-ready pixels retain display bins until raw counts finish',
    () async {
      final image = frame(Uint16List.fromList([0, 256, 65535]));
      container.read(currentImageProvider.notifier).state = image;
      final ready = waitForRaw();
      final pending = container.read(previewDisplayHistogramProvider)!;
      expect(pending.isRaw, isFalse);
      expect(pending.bins, same(image.histogram));

      final bins = await ready;
      expect(bins[0], 1);
      expect(bins[1], 1);
      expect(bins[255], 1);
      expect(container.read(previewDisplayHistogramProvider)!.isRaw, isTrue);
    },
  );

  test('metadata-only updates reuse the completed raw histogram', () async {
    final image = frame(Uint16List.fromList([1024, 2048]));
    container.read(currentImageProvider.notifier).state = image;
    final bins = await waitForRaw();

    container.read(currentImageProvider.notifier).state = image.copyWith(
      filePath: '/captures/frame.fits',
    );
    final updated = container.read(previewDisplayHistogramProvider)!;
    expect(updated.isRaw, isTrue);
    expect(updated.bins, same(bins), reason: 'the pixels have not changed');
  });

  test('an older scan cannot replace a newer frame histogram', () async {
    final older = frame(Uint16List(1024 * 1024));
    container.read(currentImageProvider.notifier).state = older;
    final rawResults = <List<int>>[];
    final subscription = container.listen(previewDisplayHistogramProvider, (
      _,
      next,
    ) {
      if (next != null && next.isRaw) rawResults.add(next.bins);
    }, fireImmediately: true);
    addTearDown(subscription.close);
    await Future<void>.delayed(Duration.zero);

    final newer = frame(Uint16List.fromList([65535, 65535]));
    container.read(currentImageProvider.notifier).state = newer;
    final ready = waitForRaw();
    expect(container.read(previewDisplayHistogramProvider)!.isRaw, isFalse);
    final bins = await ready;
    await pumpEventQueue(times: 30);

    expect(bins[255], 2);
    expect(bins.fold<int>(0, (sum, count) => sum + count), 2);
    expect(rawResults, [same(bins)]);
    expect(container.read(previewDisplayHistogramProvider)!.bins, same(bins));
  });

  test('clearing the image discards a pending raw histogram', () async {
    container.read(currentImageProvider.notifier).state = frame(
      Uint16List(1024 * 1024),
    );
    final subscription = container.listen(
      previewDisplayHistogramProvider,
      (_, next) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    container.read(currentImageProvider.notifier).state = null;
    await pumpEventQueue(times: 30);
    expect(container.read(previewDisplayHistogramProvider), isNull);
  });
}
