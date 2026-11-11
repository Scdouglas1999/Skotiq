import 'dart:typed_data';

import 'package:skotiq_core/skotiq_core.dart';

/// Live stacking on a linked imaging host, and the stacks it has saved.
abstract interface class HostLiveStack {
  /// Start (or arm) live stacking on the host. With [referencePath] (a host
  /// path) the stack starts immediately from that frame; without it the host
  /// arms and the next captured frame becomes the reference.
  ///
  /// Both branches return a complete stats object — an armed host reports a
  /// zero-valued (but fully populated) [LiveStackingStats] because nothing has
  /// stacked yet. A missing/malformed `stats` object is a protocol failure and
  /// throws rather than being manufactured as zero.
  Future<LiveStackingStats> stackingStart({
    String? referencePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  });

  /// Stop the stacker and disarm host auto-feed.
  Future<void> stackingStop();

  /// Clear the accumulation (host stays armed).
  Future<void> stackingReset();

  /// Add a host-side frame to the running stack and return the refreshed
  /// result (dimensions + stats + stacked pixels).
  Future<LiveStackingResult> stackingAddFrame(String imagePath);

  /// Current accumulation stats only (cheap; no pixels). Requires a complete
  /// stats object; a partial/malformed 200 throws rather than reporting zeros.
  Future<LiveStackingStats> stackingGetStats();

  /// Fetch the current stacked result: dimensions + stats (JSON) plus the raw
  /// little-endian u16 pixel buffer (binary).
  ///
  /// Every field is required and validated: `width`/`height` must be positive
  /// integers, `channels` must be 1 or 3, `stats` must be complete, and the
  /// downloaded preview must be exactly `width * height * channels` u16 samples.
  /// A truncated, oversized, odd-length, or dimension-mismatched buffer throws
  /// rather than being displayed as a valid stack.
  Future<LiveStackingResult> stackingGetResult();

  /// Fetch recent durable Stack-and-Share results, newest first.
  Future<List<RemoteStackedResult>> stackingGetSavedResults({int limit = 20});

  /// Fetch one durable Stack-and-Share result without exposing host paths.
  Future<RemoteStackedResult> stackingGetSavedResult(int resultId);

  /// Download the encoded durable preview for [resultId]. Decoding and exact
  /// dimension validation happen in the provider shared by local and remote
  /// result review.
  Future<Uint8List> stackingGetSavedResultPreview(int resultId);
}
