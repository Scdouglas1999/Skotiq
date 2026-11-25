// A saved frame at full resolution: its own file decoded through the app's
// display stretch, the way the live frame is drawn.
//
// The decode is native and runs on the bridge's blocking pool, never on a Dart
// isolate. On the imaging host the frame is read where it was saved. A linked
// client has no file there, so it first downloads the frame through the
// host's image download (the same transfer "Download to device" uses) into a
// small cache, and decodes that copy.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import '../errors/error_text.dart';
import '../models/backend/image_result.dart';
import '../models/imaging/imaging_models.dart';
import '../services/capture_preview_loader.dart'
    show capturedImageDataFromResult, imageStatsFromResult;
import '../utils/logging_service.dart';
import 'backend_provider.dart';
import 'linked_host.dart' show linkedHostImagingRecordsProvider;
import 'current_frame_analysis_provider.dart';
import '../models/imaging/saved_frame.dart';

/// Decodes a frame file on this machine for the screen.
typedef FrameFileDecoder = Future<bridge.FitsReadResult> Function(String path);

/// The native decoder, the one the live frame's pixels come from.
final frameFileDecoderProvider = Provider<FrameFileDecoder>(
  (ref) =>
      (path) => bridge.apiReadFitsFile(filePath: path),
);

/// Whether this device can decode a FITS file itself. A phone carries no
/// native library, so its frames are drawn by the host instead.
final savedFrameDecodesOnDeviceProvider = Provider<bool>((ref) => true);

/// The longest edge a host-drawn frame is sent at: plenty for a phone screen
/// at 2-3x zoom, without a full sensor's RGBA in its memory.
const int hostDrawnFrameMaxEdge = 3000;

/// Where a linked client keeps the frames it downloaded to look at.
final savedFrameCacheDirProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory(
        p.join((await getTemporaryDirectory()).path, 'saved-frames'),
      ),
);

/// How many downloaded frames a linked client keeps.
const int savedFrameCacheSize = 8;

/// A saved frame loading at full resolution. Dropped, with its pixels, when
/// nothing shows it any more.
final savedFrameProvider = NotifierProvider.autoDispose
    .family<SavedFrameLoader, SavedFrameLoad, SavedFrameRef>(
      SavedFrameLoader.new,
    );

class SavedFrameLoader
    extends AutoDisposeFamilyNotifier<SavedFrameLoad, SavedFrameRef> {
  bool _disposed = false;

  @override
  SavedFrameLoad build(SavedFrameRef frame) {
    ref.onDispose(() => _disposed = true);
    if (frame.hostPath.isEmpty) {
      return const SavedFrameFailed('This frame has no saved file.');
    }
    final remote = ref.read(isRemoteModeProvider);
    if (remote && !ref.read(savedFrameDecodesOnDeviceProvider)) {
      unawaited(_loadDrawnByHost(frame));
      return const SavedFrameDownloading();
    }
    unawaited(_load(frame, remote: remote));
    return remote ? const SavedFrameDownloading() : const SavedFrameDecoding();
  }

  void _set(SavedFrameLoad next) {
    if (!_disposed) state = next;
  }

  Future<void> _load(SavedFrameRef frame, {required bool remote}) async {
    final watch = Stopwatch()..start();
    try {
      final localPath = remote ? await _download(frame) : frame.hostPath;
      if (_disposed) return;
      final downloadMs = watch.elapsedMilliseconds;
      _set(const SavedFrameDecoding());
      final decoded = await ref.read(frameFileDecoderProvider)(localPath);
      if (_disposed) return;
      Log.info(
        'Saved frame ${frame.imageId} at full resolution: '
        '${decoded.width}x${decoded.height} in ${watch.elapsedMilliseconds} ms'
        '${remote ? ' (download $downloadMs ms)' : ''}',
        source: 'SavedFrame',
      );
      _set(
        SavedFrameReady(
          image: _imageFrom(decoded, frame, localPath),
          localPath: localPath,
        ),
      );
    } catch (e) {
      Log.warning(
        'Saved frame ${frame.imageId} (${frame.hostPath}) did not load: $e',
        source: 'SavedFrame',
      );
      _set(SavedFrameFailed(userFacingError(e)));
    }
  }

  Future<void> _loadDrawnByHost(SavedFrameRef frame) async {
    try {
      final records = ref.read(linkedHostImagingRecordsProvider);
      if (records == null) {
        throw StateError('Not linked to an imaging host.');
      }
      final drawn = await records.getSavedFrameJpeg(
        frame.imageId,
        maxWidth: hostDrawnFrameMaxEdge,
      );
      if (_disposed) return;
      _set(
        SavedFrameReady(
          image: capturedImageDataFromResult(
            capturedImage: drawn,
            settings: ExposureSettings(
              exposureTime: drawn.exposureTime,
              gain: 0,
              offset: 0,
            ),
            capturedAt: frame.capturedAt,
            filePath: frame.hostPath,
            previewSource: CapturePreviewSource.remote,
          ),
          // No file on this device: nothing to detect stars in here.
          localPath: '',
        ),
      );
    } catch (e) {
      Log.warning(
        'Saved frame ${frame.imageId} (${frame.hostPath}) did not load from '
        'the host: $e',
        source: 'SavedFrame',
      );
      _set(SavedFrameFailed(userFacingError(e)));
    }
  }

  /// The frame's file on this machine, downloaded from the host unless an
  /// earlier look left it in the cache.
  Future<String> _download(SavedFrameRef frame) async {
    final dir = await ref.read(savedFrameCacheDirProvider)();
    await dir.create(recursive: true);
    final local = File(
      p.join(dir.path, '${frame.imageId}-${hostFileName(frame.hostPath)}'),
    );
    if (await local.exists()) return local.path;
    // The transfer lands beside the copy and takes its name only when whole,
    // so an interrupted one resumes instead of being decoded half written.
    final partial = File('${local.path}.part');
    await ref
        .read(imagingBackendProvider)
        .downloadImage(
          frame.imageId,
          partial.path,
          onProgress: (fraction) {
            final shown = state;
            final percent = (fraction * 100).floor();
            if (shown is SavedFrameDownloading &&
                shown.fraction != null &&
                (shown.fraction! * 100).floor() == percent) {
              return;
            }
            _set(SavedFrameDownloading(fraction));
          },
        );
    await partial.rename(local.path);
    await _prune(dir, keep: local.path);
    return local.path;
  }

  Future<void> _prune(Directory dir, {required String keep}) async {
    final files = <File, DateTime>{};
    await for (final entity in dir.list()) {
      if (entity is File && entity.path != keep) {
        files[entity] = (await entity.stat()).modified;
      }
    }
    final oldestFirst = files.keys.toList()
      ..sort((a, b) => files[a]!.compareTo(files[b]!));
    final excess = oldestFirst.length - (savedFrameCacheSize - 1);
    for (final file in oldestFirst.take(excess.clamp(0, oldestFirst.length))) {
      await file.delete();
    }
  }
}

/// The file name in [hostPath], whichever separator the host's system uses.
@visibleForTesting
String hostFileName(String hostPath) {
  final cut = hostPath.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? hostPath : hostPath.substring(cut + 1);
}

CapturedImageData _imageFrom(
  bridge.FitsReadResult decoded,
  SavedFrameRef frame,
  String localPath,
) {
  return CapturedImageData(
    width: decoded.width,
    height: decoded.height,
    displayData: decoded.displayData,
    histogram: decoded.histogram,
    stats: imageStatsFromResult(
      ImageStatsResult(
        min: decoded.stats.min,
        max: decoded.stats.max,
        mean: decoded.stats.mean,
        median: decoded.stats.median,
        stdDev: decoded.stats.stdDev,
        hfr: decoded.stats.hfr,
        eccentricity: decoded.stats.eccentricity,
        fwhm: decoded.stats.fwhm,
        starCount: decoded.stats.starCount,
      ),
    ),
    capturedAt: frame.capturedAt,
    // Only the pixels and their statistics are drawn from this; the frame's
    // row holds its capture settings.
    settings: ExposureSettings(
      exposureTime: decoded.exposureTime ?? 0,
      gain: 0,
      offset: 0,
      filter: decoded.filter?.trim(),
    ),
    filePath: localPath,
    isColor: decoded.bayerPattern != null,
  );
}

/// The stars in a saved frame's local file, detected while something watches.
final savedFrameStarsProvider = FutureProvider.autoDispose
    .family<StarDetectionResult, String>((ref, localPath) {
      return ref.read(frameStarDetectorProvider)(localPath);
    });
