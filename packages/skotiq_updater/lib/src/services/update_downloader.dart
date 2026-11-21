import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;

typedef DownloadProgressCallback =
    void Function(int downloadedBytes, int totalBytes, double progress);

class CancelToken {
  bool _isCancelled = false;
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelled.complete();
  }
}

/// How long the transfer may make no forward progress before it is treated
/// as dead. This is a *stall* deadline, not a total-transfer deadline: it is
/// re-armed on every chunk, so a slow-but-moving download is never killed.
const Duration defaultDownloadStallTimeout = Duration(seconds: 60);

/// Service for downloading update packages with progress tracking
class UpdateDownloader {
  final http.Client _client;
  final Duration _stallTimeout;
  CancelToken? _currentCancelToken;

  UpdateDownloader({
    http.Client? client,
    Duration stallTimeout = defaultDownloadStallTimeout,
  }) : _client = client ?? http.Client(),
       _stallTimeout = stallTimeout;

  /// Create a new cancel token for the next download
  CancelToken createCancelToken() {
    _currentCancelToken = CancelToken();
    return _currentCancelToken!;
  }

  /// Cancel the current download if one is in progress
  void cancelCurrentDownload() {
    _currentCancelToken?.cancel();
  }

  /// Download a file from URL to destination with progress tracking
  ///
  /// Supports resume via Range header if server supports it.
  /// Pass a [cancelToken] to allow cancellation of the download.
  Future<File> download(
    String url,
    String destinationPath, {
    DownloadProgressCallback? onProgress,
    int? expectedSize,
    CancelToken? cancelToken,
  }) async {
    final destination = File(destinationPath);
    final parent = destination.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    // Check for partial download (for resume support)
    int existingBytes = 0;
    if (await destination.exists()) {
      existingBytes = await destination.length();
    }

    // Make request with Range header if resuming
    final request = http.Request('GET', Uri.parse(url));
    if (existingBytes > 0) {
      request.headers['Range'] = 'bytes=$existingBytes-';
    }

    final streamedResponse = await _client
        .send(request)
        .timeout(
          _stallTimeout,
          onTimeout: () => throw DownloadException(
            'Update server did not respond within '
            '${_stallTimeout.inSeconds}s while opening the package download.',
          ),
        );

    // If resuming from a partial file that is no longer valid on the server
    // (e.g. server replaced the artifact with a smaller file, or the partial
    // already reached/passed EOF), HTTP 416 would wedge every future retry.
    // Delete the stale partial and restart once from byte 0.
    if (streamedResponse.statusCode == 416 && existingBytes > 0) {
      await streamedResponse.stream.drain<void>().catchError((Object _) {});
      if (await destination.exists()) {
        await destination.delete();
      }
      return download(
        url,
        destinationPath,
        expectedSize: expectedSize,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    // Check if server supports range requests
    final isPartialContent = streamedResponse.statusCode == 206;
    final isFullContent = streamedResponse.statusCode == 200;

    if (!isPartialContent && !isFullContent) {
      throw DownloadException(
        'Server returned ${streamedResponse.statusCode}',
        streamedResponse.statusCode,
      );
    }

    // If full content, we need to start fresh
    if (isFullContent && existingBytes > 0) {
      existingBytes = 0;
      await destination.delete();
    }

    int totalBytes;
    if (isPartialContent) {
      // Parse Content-Range header: bytes <start>-<end>/<total>
      final contentRange = streamedResponse.headers['content-range'];
      if (contentRange != null) {
        final match = RegExp(
          r'bytes (\d+)-(\d+)/(\d+|\*)',
        ).firstMatch(contentRange);
        if (match == null) {
          throw DownloadException(
            'Malformed Content-Range header on 206 response: $contentRange',
            206,
          );
        }
        final rangeStart = int.parse(match.group(1)!);
        if (rangeStart != existingBytes) {
          // A partial whose offset the server will not resume from fails the
          // same way on every retry if it is left on disk. Drop it and start
          // once from byte 0, matching the HTTP 416 path above. A mismatch
          // on a fresh request (no local bytes) is the server's error.
          if (existingBytes > 0) {
            await streamedResponse.stream.drain<void>().catchError(
              (Object _) {},
            );
            if (await destination.exists()) {
              await destination.delete();
            }
            return download(
              url,
              destinationPath,
              expectedSize: expectedSize,
              onProgress: onProgress,
              cancelToken: cancelToken,
            );
          }
          throw DownloadException(
            'Server Content-Range start ($rangeStart) does not match local '
            'resume offset ($existingBytes)',
            206,
          );
        }
        final totalGroup = match.group(3)!;
        totalBytes = totalGroup == '*'
            ? (expectedSize ?? 0)
            : int.parse(totalGroup);
      } else {
        final contentLength = streamedResponse.contentLength;
        totalBytes =
            expectedSize ??
            (contentLength != null ? existingBytes + contentLength : 0);
      }
    } else {
      totalBytes = streamedResponse.contentLength ?? expectedSize ?? 0;
    }

    // Open file for writing (append if resuming)
    final sink = destination.openWrite(
      mode: isPartialContent ? FileMode.append : FileMode.write,
    );

    int downloadedBytes = existingBytes;

    final chunks = StreamIterator<List<int>>(streamedResponse.stream);
    Future<bool> nextChunk() {
      final token = cancelToken;
      if (token == null) return chunks.moveNext();
      if (token.isCancelled) {
        return Future<bool>.error(DownloadCancelledException());
      }
      return Future.any<bool>([
        chunks.moveNext(),
        token.whenCancelled.then<bool>(
          (_) => throw DownloadCancelledException(),
        ),
      ]);
    }

    // Re-armed per chunk, so this bounds the gap between bytes rather than the
    // transfer. The partial file is deliberately left on disk: a stalled
    // transfer is resumable via the Range header on the next attempt.
    Future<bool> moveNextOrCancel() => nextChunk().timeout(
      _stallTimeout,
      onTimeout: () => throw DownloadException(
        'Update download stalled: no data received for '
        '${_stallTimeout.inSeconds}s.',
      ),
    );

    var cancelled = false;
    try {
      while (await moveNextOrCancel()) {
        final chunk = chunks.current;
        sink.add(chunk);
        downloadedBytes += chunk.length;

        if (onProgress != null && totalBytes > 0) {
          final progress = downloadedBytes / totalBytes;
          onProgress(downloadedBytes, totalBytes, progress.clamp(0.0, 1.0));
        }
      }
    } on DownloadCancelledException {
      cancelled = true;
      rethrow;
    } finally {
      // A hostile or broken server can leave StreamIterator.cancel() waiting
      // for the stalled read it is meant to cancel. Request cancellation, but
      // do not let that server-controlled future delay local cleanup or the
      // caller's cancellation result.
      unawaited(chunks.cancel());
      await sink.close();
      // Close the file before deleting it; Windows will reject deletion of an
      // archive while the IOSink still owns the handle.
      if (cancelled && await destination.exists()) {
        await destination.delete();
      }
    }

    return destination;
  }

  /// Check if a URL supports range requests (for resume)
  Future<bool> supportsResume(String url) async {
    try {
      final response = await _client.head(Uri.parse(url));
      return response.headers['accept-ranges'] == 'bytes';
    } catch (e) {
      return false;
    }
  }

  /// Get the content length of a URL without downloading
  Future<int?> getContentLength(String url) async {
    try {
      final response = await _client.head(Uri.parse(url));
      final length = response.headers['content-length'];
      return length != null ? int.tryParse(length) : null;
    } catch (e) {
      return null;
    }
  }

  /// Cancel any ongoing downloads (dispose the client)
  void dispose() {
    _client.close();
  }
}

class DownloadException implements Exception {
  final String message;
  final int? statusCode;

  DownloadException(this.message, [this.statusCode]);

  @override
  String toString() => 'DownloadException: $message (status: $statusCode)';
}

class DownloadCancelledException implements Exception {
  @override
  String toString() => 'Download was canceled';
}
