import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/services/capture_preview_loader.dart';
import 'package:skotiq_core/src/services/imaging_service.dart';

import '../mocks/mock_backend.dart';
import '../services/imaging_service_test.dart' show makeCapturedImageResult;

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

void main() {
  late MockBackend mockBackend;
  late ProviderContainer container;
  late TestBackendNotifier backendNotifier;

  setUp(() {
    mockBackend = MockBackend();
    registerFallbackValue(FrameType.light);
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  CapturedImageData samplePreview() {
    final result = makeCapturedImageResult(width: 4, height: 2);
    return capturedImageDataFromResult(
      capturedImage: result,
      settings: const ExposureSettings(
        exposureTime: 1.0,
        gain: 0,
        offset: 0,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      ),
      capturedAt: DateTime.utc(2026, 5, 23, 12),
    );
  }

  test('publish shows JPEG immediately then merges raw when ready', () async {
    // u16 samples, one per pixel: what both real backends return.
    final rawSamples = Uint16List.fromList(
      List<int>.generate(4 * 2, (i) => 1000 + i),
    );

    when(
      () => mockBackend.getLastRawImageData(any()),
    ).thenAnswer((_) async => rawSamples);

    final publisher = container.read(capturePreviewPublisherProvider);
    final preview = samplePreview();

    publisher.publish(container, preview, 'cam-1');

    final immediate = container.read(currentImageProvider);
    expect(immediate, isNotNull);
    expect(immediate!.displayData, preview.displayData);
    expect(immediate.rawLoadStatus, RawLoadStatus.loading);
    expect(immediate.rawU16, isNull);

    await pumpEventQueue(times: 5);

    final merged = container.read(currentImageProvider);
    expect(merged, isNotNull);
    expect(merged!.rawLoadStatus, RawLoadStatus.ready);
    expect(merged.rawU16, isNotNull);
    expect(merged.rawU16!.length, 4 * 2);
    expect(merged.rawU16!.first, 1000);
    expect(merged.hasRawReady, isTrue);
    expect(merged.displayData, preview.displayData);
  });

  test('raw failure keeps JPEG preview', () async {
    when(
      () => mockBackend.getLastRawImageData(any()),
    ).thenThrow(Exception('503 unavailable'));

    final publisher = container.read(capturePreviewPublisherProvider);
    publisher.publish(container, samplePreview(), 'cam-1');

    await pumpEventQueue(times: 5);

    final after = container.read(currentImageProvider);
    expect(after, isNotNull);
    expect(after!.rawLoadStatus, RawLoadStatus.failed);
    expect(after.rawU16, isNull);
    expect(after.displayData.isNotEmpty, isTrue);
  });

  test('stale raw load does not overwrite newer capture', () async {
    var fetchCount = 0;
    when(() => mockBackend.getLastRawImageData(any())).thenAnswer((_) async {
      fetchCount++;
      if (fetchCount == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return Uint16List(4 * 2);
    });

    final publisher = container.read(capturePreviewPublisherProvider);
    final older = samplePreview();
    publisher.publish(container, older, 'cam-1');

    await Future<void>.delayed(const Duration(milliseconds: 20));

    final newer = samplePreview().copyWith(
      capturedAt: DateTime.utc(2026, 5, 23, 13),
    );
    publisher.publish(container, newer, 'cam-1');

    await pumpEventQueue(times: 20);
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final current = container.read(currentImageProvider);
    expect(current!.capturedAt, newer.capturedAt);
    expect(current.rawLoadStatus, RawLoadStatus.ready);
  });

  test(
    'raw completion from the old backend cannot update the new host',
    () async {
      final rawResult = Completer<List<int>>();
      when(
        () => mockBackend.getLastRawImageData(any()),
      ).thenAnswer((_) => rawResult.future);

      final publisher = container.read(capturePreviewPublisherProvider);
      publisher.publish(container, samplePreview(), 'cam-1');
      await untilCalled(() => mockBackend.getLastRawImageData('cam-1'));

      final replacementBackend = MockBackend();
      backendNotifier.replaceBackend(replacementBackend);
      container.read(currentImageProvider.notifier).state = null;

      rawResult.complete(Uint16List(4 * 2));
      await pumpEventQueue(times: 5);

      expect(container.read(currentImageProvider), isNull);
      expect(
        container.read(capturePreviewPublisherProvider),
        isNot(same(publisher)),
      );
    },
  );
}
