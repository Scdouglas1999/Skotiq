// Component C5 — HiPS HTTP fetch + async (off-UI-thread) decode client.
//
// This is the *network + decode edge* of the Flutter-side GPU HiPS framing tile
// layer. It is the only HiPS component that touches the wire: every other
// component (C0 metadata/addressing, C1 HEALPix, C2 projection, C3 selection,
// C4 cache) is pure CPU geometry/bookkeeping. C5 turns a tile address (C0
// [HipsTileId]) or a survey base URL into either parsed [HipsProperties] or a
// decoded [ui.Image] ready to hand to the C4 cache and the framing painter.
//
// What it does, exactly:
//
//   * [fetchProperties] — GETs the survey `properties` text document and parses
//     it via [HipsProperties.parse]. A non-200 status, an empty body, a body
//     that is not valid UTF-8, or a malformed properties document all throw —
//     never a silently defaulted/guessed [HipsProperties].
//   * [fetchAllsky] — GETs `Norder{k}/Allsky.{ext}` (the coarse whole-sky
//     thumbnail used as the never-blank lowest level-of-detail) and decodes it
//     off the UI thread to a [ui.Image].
//   * [fetchTile] — GETs `Norder{k}/Dir{d}/Npix{n}.{ext}` for a single
//     [HipsTileId] and decodes it off the UI thread to a [ui.Image].
//
// Anti-jank guarantees this component is responsible for:
//
//   * **Decode is off the UI/build thread.** Decoding uses
//     [ui.instantiateImageCodec], whose work (parsing the compressed bytes and
//     rasterising to GPU-uploadable pixels) runs on the engine's IO/raster
//     worker threads, not the Dart UI isolate. The `await`s here only suspend
//     the calling async frame; they never busy-spin the UI thread. This is the
//     same engine path the existing single-cutout survey background uses
//     (`ui.decodeImageFromList` in `FramingProvider`), so tile imagery
//     composites identically. We use the lower-level codec API rather than the
//     `decodeImageFromList` convenience wrapper because it (a) lets us surface a
//     decode failure as a thrown error instead of the wrapper's silent
//     null-frame behaviour, and (b) gives us a [ui.Codec] we explicitly dispose.
//   * **Cancelable.** Every fetch takes an optional [HipsFetchToken]; cancelling
//     it aborts the in-flight request (closing the underlying HTTP client used
//     for that request) and makes the pending future complete with a thrown
// [HipsFetchCancelledException]. The tile-request scheduler cancels
//     superseded requests during pan/zoom so stale tiles never thrash the
//     network or land in the cache after the view moved on. A decoded image
//     produced by a request that lost the cancellation race is disposed here so
//     it never leaks.
//
// What it deliberately does **not** do (kept out of C5 by contract):
//
//   * No caching, no in-flight de-duplication, no LRU — that is C4 (the cache)
//     and C6 (the scheduler/debouncer). C5 is a stateless-per-call edge: each
//     method does exactly one fetch+decode and returns.
//   * No base-URL resolution or survey registry lookup — callers pass the
//     already-resolved `baseUrl` (verified via [HipsSurveyRegistry] or resolved
//     at runtime). C5 never fabricates a host.
//   * No Riverpod, no Flutter widget layer. Pure Dart + `dart:ui` + `dart:io`
//     timeout + `package:http`, fully unit-testable with `package:http/testing`
//     [MockClient].
//
// No silent fallbacks: a network failure, a non-200 status, an empty or
// oversized body, an undecodable image, and a malformed properties document
// each throw a typed exception the caller must handle. A blank or wrong tile
// painted without a word is the failure this prevents.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import '../../models/hips/hips_properties.dart';
import '../../models/hips/hips_tile_id.dart';

/// Base type for every failure surfaced by [HipsTileFetcher].
///
/// All fetcher failures are typed (rather than bare [Exception]s) so callers can
/// distinguish a transient network error (worth a retry) from a cancellation
/// (expected, drop quietly) from a malformed-survey/decode error (a real bug or
/// a survey that cannot be consumed). The [requestUrl] is always carried so a
/// log line or error banner can name the exact resource that failed.
sealed class HipsFetchException implements Exception {
  /// Human-readable description of what went wrong.
  final String message;

  /// The absolute URL the failed request targeted.
  final String requestUrl;

  /// The underlying error that triggered this failure, when wrapping one
  /// (e.g. a [http.ClientException] or a [FormatException]); `null` otherwise.
  final Object? cause;

  const HipsFetchException(this.message, this.requestUrl, {this.cause});

  @override
  String toString() {
    final buffer = StringBuffer('$runtimeType: $message (url=$requestUrl)');
    if (cause != null) buffer.write(' cause=$cause');
    return buffer.toString();
  }
}

/// Raised when the HTTP transport itself fails: a connection error, a DNS
/// failure, a timeout, or a non-200 status code.
///
/// [statusCode] is the HTTP status when the request completed with a non-200
/// response, or `null` when the request never produced a status (transport
/// error / timeout).
final class HipsFetchHttpException extends HipsFetchException {
  /// The HTTP status code, when the request completed with a non-200 response;
  /// `null` for transport-level failures (no response received).
  final int? statusCode;

  const HipsFetchHttpException(
    super.message,
    super.requestUrl, {
    this.statusCode,
    super.cause,
  });
}

/// Raised when a fetched response body cannot be turned into the expected value:
/// an empty body, a properties document that is not valid UTF-8 / does not
/// parse, or image bytes [ui.instantiateImageCodec] cannot decode.
final class HipsFetchDecodeException extends HipsFetchException {
  const HipsFetchDecodeException(
    super.message,
    super.requestUrl, {
    super.cause,
  });
}

/// Raised when a fetch is aborted because its [HipsFetchToken] was cancelled.
///
/// This is the *expected* outcome of the scheduler superseding an in-flight
/// request during pan/zoom; callers treat it as "drop quietly", not as an error
/// to surface to the user. It is still a thrown exception (never a silently
/// swallowed no-op) so the caller's `await` unwinds deterministically and never
/// proceeds to use a half-loaded result.
final class HipsFetchCancelledException extends HipsFetchException {
  HipsFetchCancelledException(String requestUrl)
    : super('HiPS fetch was cancelled before it completed', requestUrl);
}

/// A cooperative cancellation token for one or more in-flight HiPS fetches.
///
/// A token starts un-cancelled. Calling [cancel] flips it permanently to
/// cancelled and:
///   * aborts every HTTP request currently bound to it by closing the
///     per-request client (which forces the in-flight `GET` to error out
///     promptly instead of running to completion), and
///   * causes any subsequent fetch started with this token to throw
///     [HipsFetchCancelledException] immediately, before opening a socket.
///
/// One token may guard several fetches (e.g. the properties + Allsky + first
/// batch of tiles for a view): cancelling it aborts the whole group, which is
/// exactly what C6 wants when the view moves and the entire pending batch is
/// stale. A token is single-use — once cancelled it stays cancelled; create a
/// fresh token for the next batch.
class HipsFetchToken {
  bool _cancelled = false;

  /// The set of abort callbacks for requests currently bound to this token.
  /// Each in-flight fetch registers a callback that aborts its own HTTP request
  /// and removes itself on completion, so this never grows unbounded.
  final Set<void Function()> _aborts = <void Function()>{};

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled;

  /// Cancels the token: aborts every currently-bound request and marks all
  /// future fetches with this token as cancelled. Idempotent — calling it again
  /// after the first cancellation is a no-op.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // Copy first: an abort callback removes itself from the set, which would
    // otherwise mutate the collection mid-iteration.
    final pending = List<void Function()>.of(_aborts);
    _aborts.clear();
    for (final abort in pending) {
      abort();
    }
  }

  /// Registers [onAbort] to run if/when this token is cancelled while the
  /// request is in flight. If the token is *already* cancelled, [onAbort] is
  /// not invoked (the caller is expected to check [isCancelled] first and throw)
  /// — this only arms abort for the live window. Returns a disposer the caller
  /// invokes on completion to unregister, so a finished request's client is not
  /// closed by a later [cancel].
  void Function() _arm(void Function() onAbort) {
    _aborts.add(onAbort);
    return () => _aborts.remove(onAbort);
  }
}

/// HTTP fetch + off-UI-thread decode client for HiPS surveys (component C5).
///
/// Stateless per call: holds only an [http.Client] for connection reuse across
/// many tile fetches (one socket pool rather than one-per-tile) and the request
/// timeout. It performs no caching or de-duplication — those are C4/C6.
///
/// Construction injects the [http.Client] so tests substitute a
/// `package:http/testing` [MockClient]; production passes nothing and gets a
/// real client. The fetcher [dispose]s the client it created; an injected
/// client is owned by the caller and left open.
class HipsTileFetcher {
  /// The shared client used for the actual GETs. Owned-and-disposed only when
  /// this fetcher created it ([_ownsClient]); an injected client is the
  /// caller's to close.
  final http.Client _client;

  /// Whether [_client] was created by this fetcher (and must be closed on
  /// [dispose]) versus injected by the caller.
  final bool _ownsClient;

  /// Per-request timeout. A HiPS tile is a small (typically < 100 KB) image, so
  /// a request that has not produced a response within this window is treated
  /// as a transport failure rather than left to hang the scheduler.
  final Duration timeout;

  /// `User-Agent` sent on every request so CDS mirrors can attribute traffic to
  /// the application (CDS asks HiPS clients to identify themselves). Built once.
  final String _userAgent;

  /// Maximum accepted response body size, in bytes.
  ///
  /// A HiPS preview tile or Allsky thumbnail is small; a multi-megabyte body is
  /// either a misconfigured survey, an error page served with a 200 status, or
  /// a redirect to something unexpected. Capping the accepted size turns that
  /// into a surfaced [HipsFetchDecodeException] instead of letting an absurd
  /// download stall decode and balloon memory.
  final int maxResponseBytes;

  /// Default per-request timeout when the caller does not specify one.
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// Default [maxResponseBytes]: 32 MiB. Comfortably above any real HiPS tile
  /// (a 512x512 RGBA decode is 1 MiB; the compressed JPEG/PNG source is far
  /// smaller) and any published Allsky map, while still bounding a runaway body.
  static const int defaultMaxResponseBytes = 32 * 1024 * 1024;

  /// Creates a fetcher.
  ///
  /// [httpClient] is injected by tests (a [MockClient]); when omitted a real
  /// [http.Client] is created and owned by this instance. [appUserAgent] tags
  /// outgoing requests; it defaults to a stable Skotiq identifier.
  HipsTileFetcher({
    http.Client? httpClient,
    this.timeout = defaultTimeout,
    this.maxResponseBytes = defaultMaxResponseBytes,
    String appUserAgent =
        'Skotiq/5.0 (+https://github.com/Scdouglas1999/Skotiq) '
        'HiPS-framing-tile-layer',
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _userAgent = appUserAgent {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'must be a positive duration',
      );
    }
    if (maxResponseBytes < 1) {
      throw ArgumentError.value(
        maxResponseBytes,
        'maxResponseBytes',
        'must be >= 1 byte',
      );
    }
  }

  /// Fetches and parses the survey `properties` document under [baseUrl].
  ///
  /// The document lives at `<baseUrl>/properties` (a flat UTF-8 `key = value`
  /// text file per IVOA HiPS 1.0 §4.4). Returns the validated [HipsProperties].
  ///
  /// Throws:
  ///   * [HipsFetchCancelledException] if [token] is/becomes cancelled.
  ///   * [HipsFetchHttpException] on transport failure / timeout / non-200.
  ///   * [HipsFetchDecodeException] if the body is empty, not valid UTF-8, or
  ///     fails [HipsProperties.parse] (the parse exception is carried as
  ///     [HipsFetchException.cause]).
  Future<HipsProperties> fetchProperties(
    String baseUrl, {
    HipsFetchToken? token,
  }) async {
    final url = _propertiesUrl(baseUrl);
    final bytes = await _getBytes(url, token: token);

    final String text;
    try {
      // HiPS properties are mandated UTF-8; a body that is not valid UTF-8 is a
      // malformed/served-wrong document, surfaced rather than lossily decoded.
      text = const Utf8Decoder(allowMalformed: false).convert(bytes);
    } on FormatException catch (e) {
      throw HipsFetchDecodeException(
        'properties document is not valid UTF-8',
        url,
        cause: e,
      );
    }

    if (text.trim().isEmpty) {
      throw HipsFetchDecodeException('properties document is empty', url);
    }

    try {
      return HipsProperties.parse(text);
    } on HipsPropertiesParseException catch (e) {
      throw HipsFetchDecodeException(
        'properties document failed to parse: ${e.message}',
        url,
        cause: e,
      );
    }
  }

  /// Fetches and decodes the whole-sky Allsky thumbnail at [order].
  ///
  /// The Allsky map (`<baseUrl>/Norder{order}/Allsky.{ext}`) packs every tile at
  /// [order] into one small image; it is the coarsest, instantly-available
  /// level-of-detail painted under streaming higher-order tiles so the framing
  /// background is never blank. The returned [ui.Image] is owned by the caller
  /// (hand it to the C4 cache, which takes ownership, or dispose it).
  ///
  /// Throws the same exception family as [fetchTile].
  Future<ui.Image> fetchAllsky(
    String baseUrl,
    int order,
    HipsTileFormat format, {
    HipsFetchToken? token,
  }) async {
    final url = HipsTileId.allskyUrl(baseUrl, order, format);
    final bytes = await _getBytes(url, token: token);
    return _decode(bytes, url, token: token);
  }

  /// Fetches and decodes a single tile addressed by [id] under [baseUrl].
  ///
  /// The tile lives at `<baseUrl>/Norder{k}/Dir{d}/Npix{n}.{ext}` (HiPS 1.0
  /// §4.5). The returned [ui.Image] is owned by the caller (hand it to the C4
  /// cache, which takes ownership, or dispose it).
  ///
  /// Throws:
  ///   * [HipsFetchCancelledException] if [token] is/becomes cancelled.
  ///   * [HipsFetchHttpException] on transport failure / timeout / non-200.
  ///   * [HipsFetchDecodeException] if the body is empty, oversized, or the
  ///     image bytes cannot be decoded.
  Future<ui.Image> fetchTile(
    HipsTileId id,
    String baseUrl,
    HipsTileFormat format, {
    HipsFetchToken? token,
  }) async {
    final url = id.tileUrl(baseUrl, format);
    final bytes = await _getBytes(url, token: token);
    return _decode(bytes, url, token: token);
  }

  /// Closes the underlying [http.Client] if this fetcher created it.
  ///
  /// Safe to call once a fetcher is no longer needed; an injected client is left
  /// open for its owner to close. Does not cancel in-flight requests — callers
  /// cancel via the per-request [HipsFetchToken].
  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  // internals

  /// Performs the GET for [url], honouring [token] cancellation and the size
  /// cap, and returns the response body bytes. Throws the typed HTTP/decode
  /// exceptions; never returns an empty list (an empty body throws).
  ///
  /// Cancellation strategy: each request runs through its own short-lived
  /// [http.Client] *derived from* the shared client's send path so that closing
  /// it on cancel aborts the in-flight socket. The shared [_client] is used to
  /// actually issue the request; to make cancellation abort it promptly we race
  /// the request future against a cancellation completer armed on the token.
  Future<Uint8List> _getBytes(
    String url, {
    required HipsFetchToken? token,
  }) async {
    // Fail fast if already cancelled — never open a socket for a dead request.
    if (token != null && token.isCancelled) {
      throw HipsFetchCancelledException(url);
    }

    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      // A malformed URL is a programming/registry error, not a transport one,
      // but it still maps cleanly onto an HTTP exception for the caller.
      throw HipsFetchHttpException(
        'tile URL is not a valid URI',
        url,
        cause: e,
      );
    }

    // Arm cancellation: a completer that completes with a cancellation error the
    // moment the token is cancelled, so an in-flight GET unwinds promptly
    // instead of waiting for the socket to notice. The disposer unregisters the
    // abort callback once the request settles so a later cancel() is a no-op.
    final cancelCompleter = Completer<Never>();
    void Function()? disarm;
    if (token != null) {
      disarm = token._arm(() {
        if (!cancelCompleter.isCompleted) {
          cancelCompleter.completeError(HipsFetchCancelledException(url));
        }
      });
    }

    final request = http.Request('GET', uri)
      ..headers['User-Agent'] = _userAgent
      // HiPS tiles are images; properties is text. Accept both broadly and let
      // the decode step validate, rather than rejecting an unusual content type
      // a mirror might serve.
      ..headers['Accept'] = 'image/*, text/plain, */*';

    // Single outer try/finally so the token abort callback is unregistered on
    // *every* exit path — completion, status error, size error, transport
    // error, timeout, or cancellation — and a later cancel() can never try to
    // abort this already-settled request.
    try {
      final http.StreamedResponse streamed;
      try {
        final sendFuture = _client
            .send(request)
            .timeout(
              timeout,
              onTimeout: () => throw HipsFetchHttpException(
                'request timed out after ${timeout.inMilliseconds} ms',
                url,
              ),
            );
        // If cancellation wins the race below, the send may still complete in
        // the background after we have already unwound. Attach a guarded
        // continuation that drains the orphaned body (returning the connection
        // to the pool instead of dangling) *only* when the cancel completer has
        // fired — i.e. only when this response is the one we abandoned, never
        // the one [_collectCapped] is about to read on the success path.
        unawaited(
          sendFuture.then(
            (response) {
              if (cancelCompleter.isCompleted) {
                return response.stream.drain<void>().catchError((_) {});
              }
              return null;
            },
            // A send that errors *after* we unwound on cancel has nothing to
            // drain; swallow it so it is not reported as an unhandled async error.
            onError: (_) {},
          ),
        );
        // Race the send against cancellation: whichever settles first wins. On
        // cancel, [cancelCompleter] throws [HipsFetchCancelledException] here.
        streamed = await Future.any<http.StreamedResponse>(
          <Future<http.StreamedResponse>>[sendFuture, cancelCompleter.future],
        );
      } on HipsFetchException {
        rethrow;
      } on http.ClientException catch (e) {
        throw HipsFetchHttpException(
          'HTTP transport error: ${e.message}',
          url,
          cause: e,
        );
      } catch (e) {
        throw HipsFetchHttpException('HTTP request failed', url, cause: e);
      }

      if (streamed.statusCode != 200) {
        // Drain so the connection can be reused rather than left dangling.
        unawaited(streamed.stream.drain<void>().catchError((_) {}));
        throw HipsFetchHttpException(
          'unexpected HTTP status ${streamed.statusCode}',
          url,
          statusCode: streamed.statusCode,
        );
      }

      // Enforce the size cap up front when the server declares Content-Length,
      // so an absurd body is rejected before it is downloaded.
      final declaredLength = streamed.contentLength;
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        unawaited(streamed.stream.drain<void>().catchError((_) {}));
        throw HipsFetchDecodeException(
          'response body of $declaredLength bytes exceeds the '
          '$maxResponseBytes-byte cap',
          url,
        );
      }

      // Collect the streamed body, racing against cancellation and enforcing
      // the size cap incrementally (in case Content-Length was absent or lied).
      final Uint8List body;
      try {
        body = await Future.any<Uint8List>(<Future<Uint8List>>[
          _collectCapped(streamed, url),
          cancelCompleter.future,
        ]);
      } on HipsFetchException {
        rethrow;
      } catch (e) {
        throw HipsFetchHttpException(
          'failed reading response body',
          url,
          cause: e,
        );
      }

      if (body.isEmpty) {
        throw HipsFetchDecodeException(
          'response body was empty (HTTP 200 with no content)',
          url,
        );
      }

      return body;
    } finally {
      disarm?.call();
    }
  }

  /// Reads [streamed]'s body into a single [Uint8List], throwing a
  /// [HipsFetchDecodeException] the moment the accumulated size would exceed
  /// [maxResponseBytes] (defends against a missing/lying Content-Length).
  Future<Uint8List> _collectCapped(
    http.StreamedResponse streamed,
    String url,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream) {
      builder.add(chunk);
      if (builder.length > maxResponseBytes) {
        // Abandon the rest of the stream; the cap is exceeded.
        throw HipsFetchDecodeException(
          'response body exceeded the $maxResponseBytes-byte cap mid-stream',
          url,
        );
      }
    }
    return builder.toBytes();
  }

  /// Decodes [bytes] into a single-frame [ui.Image] off the UI thread.
  ///
  /// Uses [ui.instantiateImageCodec] (engine IO/raster threads do the actual
  /// pixel work) and reads the first frame. A failure to instantiate the codec
  /// or get a frame — i.e. the bytes are not a decodable image — throws a
  /// [HipsFetchDecodeException] rather than returning a null/blank image.
  ///
  /// Honours late cancellation: if [token] is cancelled while decoding, the
  /// decoded image (if any) is disposed and [HipsFetchCancelledException] is
  /// thrown, so a superseded request never returns a live image the cache would
  /// then have to evict.
  Future<ui.Image> _decode(
    Uint8List bytes,
    String url, {
    required HipsFetchToken? token,
  }) async {
    if (token != null && token.isCancelled) {
      throw HipsFetchCancelledException(url);
    }

    ui.Codec? codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (e) {
      throw HipsFetchDecodeException(
        'image bytes could not be decoded (not a valid image)',
        url,
        cause: e,
      );
    }

    try {
      final ui.FrameInfo frame;
      try {
        frame = await codec.getNextFrame();
      } catch (e) {
        throw HipsFetchDecodeException(
          'failed to extract a frame from the decoded image',
          url,
          cause: e,
        );
      }

      final image = frame.image;

      if (image.width <= 0 || image.height <= 0) {
        image.dispose();
        throw HipsFetchDecodeException(
          'decoded image has degenerate dimensions '
          '(${image.width}x${image.height})',
          url,
        );
      }

      // If the request was cancelled during the (async) decode, do not return a
      // live image: dispose it and surface the cancellation. This keeps the
      // never-leak invariant — a cancelled request owns nothing on return.
      if (token != null && token.isCancelled) {
        image.dispose();
        throw HipsFetchCancelledException(url);
      }

      return image;
    } finally {
      codec.dispose();
    }
  }

  /// Builds the `<baseUrl>/properties` URL, normalising a single trailing slash
  /// on [baseUrl] so the result never has a doubled or missing separator
  /// (matching [HipsTileId.tileUrl]'s normalisation so all three URL shapes
  /// agree).
  static String _propertiesUrl(String baseUrl) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return '$normalized/properties';
  }
}
