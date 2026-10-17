// Sidecar JPEG thumbnail caching for captured FITS frames.
//
// Without caching, every `GET /api/images/{id}/thumbnail` request triggers
// a cold FITS read + stretch + JPEG encode in Rust. Loading a 200-image
// gallery from a phone over a slow link took minutes on Pi-class hardware.
//
// This service generates a `{filePath}.thumb.jpg` next to every newly
// captured FITS (asynchronously via `unawaited(...)` so the capture path
// never blocks) and self-heals legacy rows on demand. Every reader consults
// the sidecar first and only falls back to a fresh decode when the file is
// missing: the remote-mode HTTP handlers via `readSidecar`/`writeSidecarForRow`,
// and the desktop FFI backend via `readSidecar`/`generateAndCacheSidecar`. The
// FFI path used to skip the cache entirely, so on desktop a frame whose sidecar
// was sitting on disk still cost a full-frame FITS decode on every navigation.
//
// Failed sidecar writes are logged at warning severity — not error, because
// the captured image is fully usable without a sidecar and the cold-read
// fallback handles missing ones. Every failure is logged; none is swallowed.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;

import '../database/daos/images_dao.dart';
import 'logging_service.dart';

/// Function signature for converting a FITS path to JPEG bytes. The
/// default production binding calls `bridge_api.apiGenerateFitsThumbnail`;
/// tests inject a deterministic stub so they don't need the Rust runtime.
typedef FitsThumbnailBytesGenerator =
    Future<Uint8List> Function({
      required String filePath,
      required int maxSize,
    });

/// Default sidecar max-edge in pixels. Every reader goes through this service,
/// so this is now the single place the thumbnail's encoded size is decided.
const int defaultSidecarMaxSize = 512;

/// Default production wrapper around the Rust FFI. Pulled out so test
/// suites can replace it without touching the bridge.
Future<Uint8List> defaultGenerateFitsThumbnail({
  required String filePath,
  required int maxSize,
}) => bridge_api.apiGenerateFitsThumbnail(filePath: filePath, maxSize: maxSize);

/// Computes the canonical sidecar path for a given FITS frame. The
/// `.thumb.jpg` suffix is appended to the full source path so two
/// frames with the same basename in different folders never collide.
String sidecarPathForFits(String fitsPath) => '$fitsPath.thumb.jpg';

/// Result of a sidecar write attempt. Returned synchronously from
/// [ThumbnailSidecarService.writeSidecar] when callers want to wait
/// (e.g. the regenerate endpoint and the backfill job); the
/// capture-time path uses `unawaited(...)` and ignores the result.
sealed class SidecarWriteResult {
  const SidecarWriteResult();
}

class SidecarWritten extends SidecarWriteResult {
  final File sidecarFile;
  final int byteCount;
  final DateTime mtime;
  const SidecarWritten({
    required this.sidecarFile,
    required this.byteCount,
    required this.mtime,
  });
}

class SidecarSkipped extends SidecarWriteResult {
  /// One of:
  ///   * `missing_source` — the FITS file no longer exists on disk.
  ///   * `empty_source_path` — the row has an empty `file_path`.
  final String reason;
  const SidecarSkipped(this.reason);
}

class SidecarFailed extends SidecarWriteResult {
  final Object error;
  final StackTrace stackTrace;
  const SidecarFailed(this.error, this.stackTrace);
}

/// Generates `.thumb.jpg` sidecars next to captured FITS frames.
class ThumbnailSidecarService {
  final FitsThumbnailBytesGenerator _generate;
  final LoggingService? _logger;
  final int _maxSize;

  /// Generations in flight, keyed by source FITS path, so simultaneous
  /// requests for one frame decode it once. See [generateAndCacheSidecar].
  final Map<String, Future<Uint8List>> _generations =
      <String, Future<Uint8List>>{};

  ThumbnailSidecarService({
    FitsThumbnailBytesGenerator? generator,
    LoggingService? logger,
    int maxSize = defaultSidecarMaxSize,
  }) : _generate = generator ?? defaultGenerateFitsThumbnail,
       _logger = logger,
       _maxSize = maxSize;

  /// Generate JPEG bytes for [fitsPath] and write them to
  /// `{fitsPath}.thumb.jpg`. Idempotent — overwrites any existing
  /// sidecar. Returns:
  ///
  ///   * [SidecarWritten] on success (sidecar bytes flushed to disk).
  ///   * [SidecarSkipped] when the source FITS is missing.
  ///   * [SidecarFailed] when the FFI call or disk write throws.
  ///
  /// Never throws — callers (especially `unawaited(...)` capture paths)
  /// must not be derailed by sidecar failures, and the structured logger
  /// records every non-success outcome.
  Future<SidecarWriteResult> writeSidecar(String fitsPath) async {
    if (fitsPath.isEmpty) {
      _logger?.warning(
        'ThumbnailSidecarService: refusing to write sidecar for empty path',
        source: 'ThumbnailSidecarService',
      );
      return const SidecarSkipped('empty_source_path');
    }

    final source = File(fitsPath);
    if (!await source.exists()) {
      _logger?.warning(
        'ThumbnailSidecarService: source FITS not on disk: $fitsPath '
        '— skipping sidecar generation',
        source: 'ThumbnailSidecarService',
      );
      return const SidecarSkipped('missing_source');
    }

    try {
      final bytes = await _generate(filePath: fitsPath, maxSize: _maxSize);
      return await _persistSidecar(fitsPath, bytes);
    } catch (e, st) {
      _logger?.warning(
        'ThumbnailSidecarService: failed to write sidecar for $fitsPath: $e',
        source: 'ThumbnailSidecarService',
      );
      return SidecarFailed(e, st);
    }
  }

  /// Generate the sidecar AND stamp the DB row's `thumbnail_path` column
  /// on success. Used by the capture pipeline (fire-and-forget) and by
  /// the backfill job (awaited).
  Future<SidecarWriteResult> writeSidecarForRow({
    required int imageId,
    required String fitsPath,
    required ImagesDao imagesDao,
  }) async {
    final result = await writeSidecar(fitsPath);
    if (result is SidecarWritten) {
      await _stampRow(imageId, result.sidecarFile.path, imagesDao);
    } else if (result is SidecarSkipped && result.reason == 'missing_source') {
      // Clear any stale stamp so the GET handler doesn't keep probing
      // a path that will never resolve.
      try {
        await imagesDao.setThumbnailPath(imageId, null);
      } catch (_) {
        // Best-effort cleanup — never let a stamp clear failure
        // propagate.
      }
    }
    return result;
  }

  /// Sidecar bytes for [fitsPath] when a usable `.thumb.jpg` is already on
  /// disk, else null.
  ///
  /// [stampedPath] is the `thumbnail_path` the DB row carries. It is tried
  /// first so a sidecar written somewhere other than the canonical location is
  /// still found; the canonical path beside the FITS is the fallback, which is
  /// also what an un-stamped row resolves to.
  ///
  /// A zero-length file counts as a miss. That is what a write cut short by a
  /// pulled SD card leaves behind, and serving it would turn the frame into a
  /// broken-image glyph for good instead of regenerating once. A captured FITS
  /// never changes after it lands, so a sidecar that does have bytes needs no
  /// freshness comparison against its source.
  Future<Uint8List?> readSidecar(String fitsPath, {String? stampedPath}) async {
    if (fitsPath.isEmpty) return null;
    final canonical = sidecarPathForFits(fitsPath);
    final candidates = <String>[
      if (stampedPath != null &&
          stampedPath.isNotEmpty &&
          stampedPath != canonical)
        stampedPath,
      canonical,
    ];

    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return bytes;
        _logger?.warning(
          'ThumbnailSidecarService: sidecar $path is empty — regenerating',
          source: 'ThumbnailSidecarService',
        );
      } catch (e) {
        _logger?.warning(
          'ThumbnailSidecarService: failed to read sidecar $path: $e',
          source: 'ThumbnailSidecarService',
        );
      }
    }
    return null;
  }

  /// Generate [fitsPath]'s thumbnail, hand the bytes straight back, and cache
  /// the sidecar afterwards so the next request is a plain file read.
  ///
  /// This is the self-heal for rows captured before sidecars existed and for
  /// any frame whose sidecar was deleted. The caller gets its bytes the moment
  /// the generator returns: the disk write and the DB stamp follow and are not
  /// awaited, because a read-only or full frame directory must not turn a
  /// perfectly viewable frame into a placeholder.
  ///
  /// Concurrent requests for the same [fitsPath] share one generation. Three
  /// surfaces (the cockpit strip, the run dashboard's history rail and the
  /// Tonight panel) ask for the newest frame at the same moment, and without
  /// this that is three full-frame FITS decodes for one answer.
  Future<Uint8List> generateAndCacheSidecar({
    required int imageId,
    required String fitsPath,
    required ImagesDao imagesDao,
  }) {
    final inFlight = _generations[fitsPath];
    if (inFlight != null) return inFlight;

    final generation = _generateAndCache(
      imageId: imageId,
      fitsPath: fitsPath,
      imagesDao: imagesDao,
    );
    _generations[fitsPath] = generation;
    return generation.whenComplete(() => _generations.remove(fitsPath));
  }

  Future<Uint8List> _generateAndCache({
    required int imageId,
    required String fitsPath,
    required ImagesDao imagesDao,
  }) async {
    final bytes = await _generate(filePath: fitsPath, maxSize: _maxSize);
    unawaited(
      _cacheGeneratedBytes(
        imageId: imageId,
        fitsPath: fitsPath,
        bytes: bytes,
        imagesDao: imagesDao,
      ),
    );
    return bytes;
  }

  Future<void> _cacheGeneratedBytes({
    required int imageId,
    required String fitsPath,
    required Uint8List bytes,
    required ImagesDao imagesDao,
  }) async {
    try {
      final written = await _persistSidecar(fitsPath, bytes);
      await _stampRow(imageId, written.sidecarFile.path, imagesDao);
    } catch (e) {
      _logger?.warning(
        'ThumbnailSidecarService: served image $imageId from a fresh decode '
        'but could not cache its sidecar: $e',
        source: 'ThumbnailSidecarService',
      );
    }
  }

  /// Writes [bytes] to the canonical sidecar path for [fitsPath]. Throws on a
  /// failed write; every caller decides how to report that.
  Future<SidecarWritten> _persistSidecar(
    String fitsPath,
    Uint8List bytes,
  ) async {
    final sidecar = File(sidecarPathForFits(fitsPath));
    // `flush: true` so we don't end up with a half-written sidecar if
    // the process is killed mid-write (an SD-card-pulled Pi mid-session
    // is the canonical failure mode).
    await sidecar.writeAsBytes(bytes, flush: true);
    return SidecarWritten(
      sidecarFile: sidecar,
      byteCount: bytes.length,
      mtime: await sidecar.lastModified(),
    );
  }

  Future<void> _stampRow(
    int imageId,
    String sidecarPath,
    ImagesDao imagesDao,
  ) async {
    try {
      await imagesDao.setThumbnailPath(imageId, sidecarPath);
    } catch (e) {
      // Stamping the DB row failed but the file IS on disk — log so
      // the operator knows the GET handler will need to self-heal
      // (it will, by reading the sidecar from the canonical path).
      _logger?.warning(
        'ThumbnailSidecarService: sidecar written but DB stamp failed '
        'for image $imageId: $e',
        source: 'ThumbnailSidecarService',
      );
    }
  }

  /// Best-effort fire-and-forget sidecar generation. Called from
  /// capture-pipeline insert paths via `unawaited(...)`. Errors are
  /// logged (inside [writeSidecarForRow]) but never propagate.
  void scheduleSidecarWrite({
    required int imageId,
    required String fitsPath,
    required ImagesDao imagesDao,
  }) {
    unawaited(
      writeSidecarForRow(
        imageId: imageId,
        fitsPath: fitsPath,
        imagesDao: imagesDao,
      ),
    );
  }
}
