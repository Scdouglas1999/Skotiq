// Thumbnail sidecars, regeneration, backfill, and ranged image downloads.
part of '../session_handlers.dart';

extension SessionThumbnailHandlers on SessionHandlers {
  Future<Response> handleGetImageThumbnail(
    Request request,
    String imageId,
  ) async {
    final iid = _parsePathId(imageId, 'imageId');
    final database = container.read(databaseProvider);
    final dbImage = await database.imagesDao.getImageById(iid);
    if (dbImage == null) {
      return jsonNotFound({'error': 'Image not found: $iid'});
    }

    // Ensure the source FITS still exists before any FFI fallback. We do
    // this even when the sidecar is present so a deleted source FITS
    // surfaces as 404 consistently (the sidecar is auxiliary; if the
    // underlying FITS is gone the image entity is effectively
    // un-viewable for science purposes).
    final sourceFile = File(dbImage.filePath);
    if (!await sourceFile.exists()) {
      return jsonNotFound({
        'error': 'Image file not found: ${dbImage.filePath}',
      });
    }

    final sidecarPath = await database.imagesDao.getThumbnailPath(iid);
    final canonicalSidecarPath = sidecarPath != null && sidecarPath.isNotEmpty
        ? sidecarPath
        : '${dbImage.filePath}.thumb.jpg';
    final sidecarFile = File(canonicalSidecarPath);

    if (await sidecarFile.exists()) {
      return _serveSidecarFromDisk(
        request: request,
        imageId: iid,
        sidecarFile: sidecarFile,
        dbImage: dbImage,
      );
    }

    // Cold-read fallback: no sidecar on disk. Generate via the FFI path
    // then persist for next time. The DB-row's stamped `thumbnail_path`
    // is also updated (or cleared if generation failed).
    final sidecarService = container.read(thumbnailSidecarServiceProvider);
    final writeResult = await sidecarService.writeSidecarForRow(
      imageId: iid,
      fitsPath: dbImage.filePath,
      imagesDao: database.imagesDao,
    );

    switch (writeResult) {
      case SidecarWritten(:final sidecarFile):
        return _serveSidecarFromDisk(
          request: request,
          imageId: iid,
          sidecarFile: sidecarFile,
          dbImage: dbImage,
        );
      case SidecarSkipped(:final reason):
        // The service already logged this; surface to caller as 404.
        return jsonNotFound({
          'error': 'Thumbnail unavailable',
          'reason': reason,
        });
      case SidecarFailed(:final error):
        _logger.warning(
          'handleGetImageThumbnail: FFI thumbnail generation failed for '
          'image $iid (${dbImage.filePath}): $error',
          source: 'SessionHandlers',
        );
        return jsonInternalServerError({
          'error': 'Failed to generate thumbnail',
          'detail': error.toString(),
        });
    }
  }

  /// Serve a sidecar JPEG with strong ETag + caching headers. Honors
  /// `If-None-Match` for 304 responses.
  Future<Response> _serveSidecarFromDisk({
    required Request request,
    required int imageId,
    required File sidecarFile,
    required DbCapturedImage dbImage,
  }) async {
    final int sidecarLength;
    final DateTime sidecarMtime;
    try {
      sidecarLength = await sidecarFile.length();
      sidecarMtime = await sidecarFile.lastModified();
    } on FileSystemException catch (e) {
      _logger.warning(
        'Failed to stat sidecar for image $imageId at ${sidecarFile.path}: '
        '$e',
        source: 'SessionHandlers',
      );
      return jsonInternalServerError({
        'error': 'Failed to read sidecar metadata',
        // Sanitized: full cause is logged above; not leaked to the caller.
        'detail': 'See server logs for diagnostics.',
      });
    }

    // Strong validator. mtime in ms is the highest portable resolution we
    // get from Dart's File API. Once a sidecar is written its content is
    // effectively immutable (only regenerate-thumbnail rewrites it, which
    // bumps mtime), so the ETag uniquely identifies the bytes.
    final etag = '"$imageId-${sidecarMtime.millisecondsSinceEpoch}"';
    final ifNoneMatch = request.headers['if-none-match'];
    if (ifNoneMatch != null && ifNoneMatch == etag) {
      return Response.notModified(
        headers: {
          'etag': etag,
          'cache-control': 'private, max-age=86400, immutable',
        },
      );
    }

    final bytes = await sidecarFile.readAsBytes();
    final metaHeader = _buildImageMetaHeader(dbImage, bytes);
    return contentResponse(
      bytes,
      contentType: 'image/jpeg',
      contentLength: sidecarLength,
      headers: {
        'etag': etag,
        'cache-control': 'private, max-age=86400, immutable',
        'x-image-meta': metaHeader,
      },
    );
  }

  /// Build a base64-encoded JSON payload mirroring the live-view
  /// `x-image-meta` schema (`display_buffer_jpeg.dart`). Pulled from the
  /// DB row rather than re-stretching the FITS, because the gallery
  /// thumbnail consumer only needs the lightweight stats (HFR, star
  /// count, exposure) rather than the full histogram.
  String _buildImageMetaHeader(DbCapturedImage row, Uint8List bytes) {
    final meta = <String, Object?>{
      'imageId': row.id,
      'fileName': row.fileName,
      'frameType': row.frameType,
      'exposureTime': row.exposureDuration,
      'filter': row.filter,
      'hfr': row.hfr,
      'starCount': row.starCount,
      'isAccepted': row.isAccepted,
      'capturedAt': row.capturedAt.millisecondsSinceEpoch,
      'sidecarBytes': bytes.length,
    };
    return base64Encode(utf8.encode(jsonEncode(meta)));
  }

  /// Force regeneration of the sidecar from the current FITS bytes.
  /// Used by operators when an out-of-band FITS replacement has stale-d
  /// the cached sidecar (the only condition under which the otherwise-
  /// immutable cache becomes incorrect).
  Future<Response> handleRegenerateImageThumbnail(
    Request request,
    String imageId,
  ) async {
    _logInfo('[API] POST /api/images/$imageId/regenerate-thumbnail');
    final iid = _parsePathId(imageId, 'imageId');
    final database = container.read(databaseProvider);
    final dbImage = await database.imagesDao.getImageById(iid);
    if (dbImage == null) {
      return jsonNotFound({'error': 'Image not found: $iid'});
    }
    final source = File(dbImage.filePath);
    if (!await source.exists()) {
      return jsonNotFound({
        'error': 'Image file not found: ${dbImage.filePath}',
      });
    }

    final sidecarService = container.read(thumbnailSidecarServiceProvider);
    final result = await sidecarService.writeSidecarForRow(
      imageId: iid,
      fitsPath: dbImage.filePath,
      imagesDao: database.imagesDao,
    );

    switch (result) {
      case SidecarWritten(:final sidecarFile, :final byteCount, :final mtime):
        publishHostMutationFromContainer(
          container,
          entityType: HostMutationEntity.capturedImage,
          action: HostMutationAction.updated,
          entityId: iid.toString(),
        );
        return jsonOk({
          'status': 'regenerated',
          'sidecarPath': sidecarFile.path,
          'byteCount': byteCount,
          'mtime': mtime.toUtc().toIso8601String(),
        });
      case SidecarSkipped(:final reason):
        return jsonNotFound({
          'error': 'Could not regenerate thumbnail',
          'reason': reason,
        });
      case SidecarFailed(:final error):
        return jsonInternalServerError({
          'error': 'Failed to regenerate thumbnail',
          'detail': error.toString(),
        });
    }
  }

  /// Backfill thumbnail sidecars for legacy images.
  ///
  /// Returns `{jobId}` immediately. The background job walks every row in
  /// `captured_images` and (a) skips rows whose source FITS is missing
  /// (counted as `skipped`), (b) skips rows whose sidecar already exists
  /// on disk (counted as `already_present`), (c) regenerates the sidecar
  /// for everything else.
  ///
  /// Cancellable via `POST /api/jobs/{jobId}/cancel`. Emits `JobProgress`
  /// events with `{current, total, currentFile}` rate-limited to ~1Hz so
  /// the SSE stream doesn't drown a phone's UI.
  Future<Response> handleBackfillThumbnails(Request request) async {
    _logInfo('[API] POST /api/images/backfill-thumbnails');
    final mgr = jobManager;
    if (mgr == null) {
      // The job manager is constructed by the headless server and wired
      // into SessionHandlers when present. A missing manager means the
      // server was bootstrapped without job support — surface a 503 so
      // the operator/client knows to retry against a properly-configured
      // build rather than silently sidestepping cancellation/progress.
      return jsonServiceUnavailable({
        'error': 'Job manager not available',
        'detail': 'Backfill requires the headless job manager.',
      });
    }
    final job = mgr.start(
      operation: 'image.backfill-thumbnails',
      deviceId: null,
      work: (sink, cancellation) async {
        final database = container.read(databaseProvider);
        final sidecarService = container.read(thumbnailSidecarServiceProvider);
        final rows = await database.imagesDao.listImagesForThumbnailBackfill();

        final total = rows.length;
        sink.update(0.0, 'Scanning $total images');

        int processed = 0;
        int written = 0;
        int alreadyPresent = 0;
        int skippedMissingSource = 0;
        int failed = 0;
        DateTime lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

        for (final row in rows) {
          if (cancellation.isCancelled) {
            throw const JobCancelledException('backfill canceled');
          }
          processed++;

          // Decide whether the row already has a usable sidecar. We
          // honour any stamped path first; if missing we fall back to
          // the canonical `${filePath}.thumb.jpg` location.
          final stampedSidecar = row.thumbnailPath;
          final canonical = row.filePath.isEmpty
              ? null
              : '${row.filePath}.thumb.jpg';
          final candidatePath =
              (stampedSidecar != null && stampedSidecar.isNotEmpty)
              ? stampedSidecar
              : canonical;

          if (candidatePath != null && await File(candidatePath).exists()) {
            // Already-present sidecar — make sure the DB stamp matches
            // the on-disk location so subsequent GETs hit it directly.
            if (stampedSidecar != candidatePath) {
              await database.imagesDao.setThumbnailPath(row.id, candidatePath);
            }
            alreadyPresent++;
          } else if (row.filePath.isEmpty) {
            skippedMissingSource++;
          } else if (!await File(row.filePath).exists()) {
            skippedMissingSource++;
            // Stamp clear so the GET handler doesn't waste a FFI call
            // on a row whose source is gone.
            await database.imagesDao.setThumbnailPath(row.id, null);
          } else {
            final result = await sidecarService.writeSidecarForRow(
              imageId: row.id,
              fitsPath: row.filePath,
              imagesDao: database.imagesDao,
            );
            switch (result) {
              case SidecarWritten():
                written++;
              case SidecarSkipped():
                skippedMissingSource++;
              case SidecarFailed():
                failed++;
            }
          }

          // Rate-limit progress emission to ~1 Hz so a session with
          // tens of thousands of rows doesn't flood the SSE stream.
          // Always emit the first and the final tick regardless.
          final now = DateTime.now();
          final timeSinceLast = now.difference(lastEmit);
          if (processed == 1 ||
              processed == total ||
              timeSinceLast >= const Duration(milliseconds: 1000)) {
            sink.update(
              total == 0 ? 1.0 : processed / total,
              'Processed $processed of $total — ${row.filePath}',
            );
            lastEmit = now;
          }
        }

        return {
          'total': total,
          'written': written,
          'alreadyPresent': alreadyPresent,
          'skipped': skippedMissingSource,
          'failed': failed,
        };
      },
    );
    return jsonOk({
      'jobId': job.jobId,
      'status': job.state.wireName,
      'operation': job.operation,
    });
  }

  /// FITS download with HTTP Range support (RFC 7233).
  ///
  /// Mobile clients on flaky cellular need partial-content resumption — a
  /// 30 MB FITS that drops at byte 27 MB must resume, not restart. The `Range`
  /// request header is parsed and answered with:
  ///   * 200 OK + `accept-ranges: bytes` when no Range header is sent.
  ///   * 206 Partial Content + `content-range` for valid Range requests.
  ///   * 416 Requested Range Not Satisfiable for malformed/unsatisfiable
  ///     specs.
  /// An `etag` of `"<imageId>-<mtime-ms>"` lets the client validate the
  /// resource hasn't changed between resume attempts via `If-Range`.
  /// Multi-range (`bytes=0-499,1000-1499`) is explicitly rejected with
  /// 416 — out of scope.
  Future<Response> handleDownloadImage(Request request, String imageId) async {
    final iid = _parsePathId(imageId, 'imageId');

    // Look up the image from the database
    final database = container.read(databaseProvider);
    final imagesDao = database.imagesDao;
    final dbImage = await imagesDao.getImageById(iid);

    if (dbImage == null) {
      return jsonNotFound({"error": "Image not found: $iid"});
    }

    // Get the file path and check if it exists
    final file = File(dbImage.filePath);
    if (!await file.exists()) {
      return jsonNotFound({
        "error": "Image file not found: ${dbImage.filePath}",
      });
    }

    // Stat the file. A permission-denied here is a 403; a generic I/O error
    // is a 500. Surface both rather than letting the middleware collapse them
    // into one opaque 500 — the caller cannot act on a code that cannot
    // distinguish "fix the permissions" from "the disk is failing".
    final int fileLength;
    final DateTime mtime;
    try {
      fileLength = await file.length();
      mtime = await file.lastModified();
    } on PathAccessException catch (e) {
      _logger.warning(
        'Permission denied reading $imageId: $e',
        source: 'SessionHandlers',
      );
      return jsonForbidden({
        'error': 'Permission denied',
        'path': dbImage.filePath,
      });
    } on FileSystemException catch (e) {
      _logger.error('Failed to stat $imageId: $e', source: 'SessionHandlers');
      return jsonInternalServerError(const {
        'error': 'Failed to read file metadata',
        // Sanitized: full cause is logged above; not leaked to the caller.
        'detail': 'See server logs for diagnostics.',
      });
    }

    // Determine content type based on file extension
    final ext = dbImage.filePath.toLowerCase();
    String contentType;
    if (ext.endsWith('.fits') || ext.endsWith('.fit')) {
      contentType = 'application/fits';
    } else if (ext.endsWith('.xisf')) {
      contentType = 'application/x-xisf';
    } else if (ext.endsWith('.png')) {
      contentType = 'image/png';
    } else if (ext.endsWith('.jpg') || ext.endsWith('.jpeg')) {
      contentType = 'image/jpeg';
    } else if (ext.endsWith('.tif') || ext.endsWith('.tiff')) {
      contentType = 'image/tiff';
    } else {
      contentType = 'application/octet-stream';
    }

    // Build the etag from image id + on-disk mtime (in ms, the highest
    // resolution we can portably get from Dart's File API). This lets
    // a resuming client send `If-Range: "<etag>"` and we'll either
    // honour the range or fall back to a full body if the file changed.
    final etag = '"$iid-${mtime.millisecondsSinceEpoch}"';

    final rangeHeader = request.headers['range'];
    final ifRange = request.headers['if-range'];

    // If the caller passes If-Range but it doesn't match our current
    // etag, RFC 7233 §3.2 says we MUST ignore the Range header and
    // return the full body. Strong-validator semantics (etag must match
    // exactly, weak etags like `W/"..."` are deliberately not generated
    // here so we don't have to handle weak matching).
    final ifRangeMatches = ifRange == null || ifRange == etag;
    final shouldHonourRange = rangeHeader != null && ifRangeMatches;

    if (!shouldHonourRange) {
      // 200 full body. We always advertise accept-ranges so clients
      // know to use Range on the next attempt.
      return attachmentResponse(
        file.openRead(),
        fileName: dbImage.fileName,
        contentType: contentType,
        contentLength: fileLength,
        headers: {'accept-ranges': 'bytes', 'etag': etag},
      );
    }

    // Range header is present. Parse it; any failure is a 416.
    final int rangeStart;
    final int rangeEnd;
    try {
      final parsed = parseRangeHeader(rangeHeader, fileLength);
      rangeStart = parsed.start;
      rangeEnd = parsed.end;
    } on FormatException catch (e) {
      _logger.info(
        'Invalid range header "$rangeHeader" for image $iid: ${e.message}',
        source: 'SessionHandlers',
      );
      return rangeNotSatisfiableResponse(fileLength, reason: e.message);
    }

    // File.openRead's `end` parameter is exclusive; the Range header
    // bounds are inclusive — convert here.
    final body = file.openRead(rangeStart, rangeEnd + 1);
    return partialContentResponse(
      body,
      start: rangeStart,
      end: rangeEnd,
      totalLength: fileLength,
      contentType: contentType,
      fileName: dbImage.fileName,
      headers: {'etag': etag},
    );
  }
}
