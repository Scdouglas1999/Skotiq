part of '../stack_and_share_service.dart';

/// Persists the display preview that makes a completed stack genuinely
/// reopenable after the in-memory integration buffer is released.
typedef StackResultPreviewPersister =
    Future<String> Function({
      required StackAndShareResult result,
      required Uint8List rgba,
    });

/// Thrown when a Stack-and-Share run is requested while the live-stacking
/// engine singleton is already busy (a live EAA session, a sequencer
/// `LiveStackingNode`, or another in-flight Stack-and-Share run).
///
/// The native stacker is a process-wide singleton: starting a Stack-and-Share
/// run would call `apiStackingStart`/`apiStackingStartFromData` and clobber the
/// reference frame and accumulated buffer of whatever is currently running.
/// Rather than corrupting an active session, [StackAndShareService.run] refuses
/// to start and surfaces this exception, so the UI can tell the operator to
/// stop live stacking first.
class LiveStackBusyException implements Exception {
  /// Human-readable explanation suitable for direct display.
  final String message;

  const LiveStackBusyException(this.message);

  @override
  String toString() => 'LiveStackBusyException: $message';
}

/// Thrown when the stacker refuses every follower frame, leaving only the
/// reference in the integration.
///
/// A per-frame rejection is survivable — the run counts it and carries on — but
/// a "stack" containing exactly one sub is not a stack, and persisting it would
/// report a master built from a single frame. This names the count and the
/// dominant reason so the operator can act on it (loosen the residual ceiling,
/// re-pick the reference, drop a bad night) rather than reading "failed".
class StackAndShareAllFramesRejectedException implements Exception {
  final int framesRejected;
  final int framesTotal;

  /// The most common refusal reason across the rejected frames.
  final String dominantReason;

  const StackAndShareAllFramesRejectedException({
    required this.framesRejected,
    required this.framesTotal,
    required this.dominantReason,
  });

  String get message =>
      'Every one of the $framesRejected follower frames was rejected, so only '
      'the reference remained of $framesTotal selected. Most common reason: '
      '$dominantReason.';

  @override
  String toString() => 'StackAndShareAllFramesRejectedException: $message';
}

/// Integrated raw u16 result of a completed Stack-and-Share run, retained so
/// downstream steps (FITS save, share-card render) can reuse it without
/// re-stacking.
class StackedRawResult {
  final int width;
  final int height;

  /// Channel layout of [data]: `1` for a single mono luminance plane
  /// (`width * height` samples), `3` for an OSC integration stored as
  /// interleaved RGB16 (`width * height * 3` samples). Defaults to `1` so
  /// existing mono consumers are unaffected.
  final int channels;

  /// Integrated samples. For a mono result this is one luminance plane; for a
  /// colour result it is interleaved RGB16 (R,G,B per pixel).
  final Uint16List data;

  const StackedRawResult({
    required this.width,
    required this.height,
    this.channels = 1,
    required this.data,
  });

  /// Whether this is a colour (3-channel interleaved RGB16) result.
  bool get isColor => channels == 3;
}

/// Auto-stretched RGBA display buffer of a completed Stack-and-Share run.
class StackedRgbaResult {
  final int width;
  final int height;
  final Uint8List rgba;

  const StackedRgbaResult({
    required this.width,
    required this.height,
    required this.rgba,
  });
}

/// Per-run, shared calibration inputs: the dark-match tolerances and the
/// already-loaded master flat / bias pixels (null when not configured).
class _CalibrationContext {
  final DarkLibraryMatchTolerances tolerances;
  final Uint16List? flatData;
  final Uint16List? biasData;

  const _CalibrationContext({
    required this.tolerances,
    required this.flatData,
    required this.biasData,
  });
}

/// A raw u16 frame with its dimensions.
class _RawFrame {
  final int width;
  final int height;
  final Uint16List data;

  const _RawFrame({
    required this.width,
    required this.height,
    required this.data,
  });

  /// Number of pixels (`width * height`), i.e. the calibration-frame length a
  /// matching dark / flat / bias must share.
  int get pixelCount => width * height;
}
