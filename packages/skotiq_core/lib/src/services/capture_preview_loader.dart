import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/fwhm_conversion.dart';
import '../backend/disconnected_backend.dart';
import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../models/imaging/imaging_models.dart';
import '../providers/backend_provider.dart';
import '../providers/imaging_provider.dart';
import 'imaging_service.dart';

/// Publishes JPEG-first capture previews and loads host raw data in the background.
class CapturePreviewPublisher {
  int _generation = 0;

  /// Show [preview] immediately, then fetch raw pixels when supported.
  ///
  /// Accepts a Riverpod [Ref] or a test [ProviderContainer] (both expose `.read`).
  void publish(dynamic ref, CapturedImageData preview, String deviceId) {
    final generation = ++_generation;
    final backend = _read(ref, backendProvider);
    final source = backend is NetworkBackend
        ? CapturePreviewSource.remote
        : CapturePreviewSource.local;

    final withSource = preview.copyWith(
      previewSource: source,
      rawLoadStatus: _shouldScheduleRawLoad(backend)
          ? RawLoadStatus.loading
          : RawLoadStatus.idle,
      clearRawU16: true,
    );

    _read(ref, currentImageProvider.notifier).state = withSource;
    _read(ref, lastImageStatsProvider.notifier).state = withSource.stats;

    if (!_shouldScheduleRawLoad(backend)) {
      return;
    }

    unawaited(
      _loadRawInBackground(
        ref: ref,
        expectedBackend: backend,
        generation: generation,
        deviceId: deviceId,
        capturedAt: withSource.capturedAt,
        expectedWidth: withSource.width,
        expectedHeight: withSource.height,
      ),
    );
  }

  /// Cancel in-flight raw loads (e.g. new capture starting).
  void cancelPending() {
    _generation++;
  }

  bool _shouldScheduleRawLoad(SkotiqBackend backend) {
    if (backend is DisconnectedBackend) {
      return false;
    }
    return true;
  }

  T _read<T>(dynamic ref, ProviderListenable<T> provider) {
    return ref.read(provider) as T;
  }

  Future<void> _loadRawInBackground({
    required dynamic ref,
    required SkotiqBackend expectedBackend,
    required int generation,
    required String deviceId,
    required DateTime capturedAt,
    required int expectedWidth,
    required int expectedHeight,
  }) async {
    try {
      final rawList = await expectedBackend.getLastRawImageData(deviceId);

      if (generation != _generation ||
          !identical(_read(ref, backendProvider), expectedBackend)) {
        return;
      }

      final current = _read(ref, currentImageProvider);
      if (current == null || current.capturedAt != capturedAt) {
        return;
      }

      if (rawList.isEmpty) {
        _read(ref, currentImageProvider.notifier).state = current.copyWith(
          rawLoadStatus: RawLoadStatus.failed,
        );
        return;
      }

      // getLastRawImageData returns u16 samples, one per pixel, from both the
      // native bridge and the network backend.
      final expectedPixels = expectedWidth * expectedHeight;
      if (rawList.length != expectedPixels) {
        developer.log(
          '[CapturePreview] Raw sample count ${rawList.length} does not match '
          '${expectedWidth}x$expectedHeight ($expectedPixels pixels)',
          name: 'CapturePreview',
          level: 900,
        );
        _read(ref, currentImageProvider.notifier).state = current.copyWith(
          rawLoadStatus: RawLoadStatus.failed,
        );
        return;
      }

      final rawU16 = rawList is Uint16List
          ? rawList
          : Uint16List.fromList(rawList);

      _read(ref, currentImageProvider.notifier).state = current.copyWith(
        rawU16: rawU16,
        rawLoadStatus: RawLoadStatus.ready,
      );
    } catch (e, st) {
      developer.log(
        '[CapturePreview] Background raw load failed: $e',
        name: 'CapturePreview',
        level: 900,
        error: e,
        stackTrace: st,
      );

      if (generation != _generation ||
          !identical(_read(ref, backendProvider), expectedBackend)) {
        return;
      }

      final current = _read(ref, currentImageProvider);
      if (current == null || current.capturedAt != capturedAt) {
        return;
      }

      // Keep JPEG preview; only mark raw as unavailable.
      _read(ref, currentImageProvider.notifier).state = current.copyWith(
        rawLoadStatus: RawLoadStatus.failed,
      );
    }
  }
}

final capturePreviewPublisherProvider = Provider<CapturePreviewPublisher>((
  ref,
) {
  ref.watch(backendProvider);
  final publisher = CapturePreviewPublisher();
  ref.onDispose(publisher.cancelPending);
  return publisher;
});

/// Build UI image data from a backend capture result.
CapturedImageData capturedImageDataFromResult({
  required CapturedImageResult capturedImage,
  required ExposureSettings settings,
  required DateTime capturedAt,
  String? targetName,
  String? filePath,
  CapturePreviewSource previewSource = CapturePreviewSource.local,
}) {
  return CapturedImageData(
    width: capturedImage.width,
    height: capturedImage.height,
    displayData: Uint8List.fromList(capturedImage.displayData),
    histogram: capturedImage.histogram,
    stats: ImageStats(
      min: capturedImage.stats.min,
      max: capturedImage.stats.max,
      mean: capturedImage.stats.mean,
      median: capturedImage.stats.median,
      stdDev: capturedImage.stats.stdDev,
      hfr: capturedImage.stats.hfr,
      fwhm: capturedImage.stats.hfr != null
          ? capturedImage.stats.hfr! * kFwhmPerHfr
          : null,
      eccentricity: capturedImage.stats.eccentricity,
      starCount: capturedImage.stats.starCount > 0
          ? capturedImage.stats.starCount
          : null,
      background: capturedImage.stats.mean - capturedImage.stats.stdDev,
      noise: capturedImage.stats.stdDev,
      snr: capturedImage.stats.stdDev > 0
          ? capturedImage.stats.mean / capturedImage.stats.stdDev
          : 0.0,
    ),
    capturedAt: capturedAt,
    settings: settings,
    targetName: targetName,
    filePath: filePath,
    isColor: capturedImage.isColor,
    previewSource: previewSource,
  );
}
