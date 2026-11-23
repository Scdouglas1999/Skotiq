part of '../device_handlers.dart';

/// Parse the wire `frameType` string into a [FrameType].
///
/// An unrecognised string is a bad request, never [FrameType.light]: coercing
/// it would let a typo in a calibration script mislabel darks and flats as
/// lights in both the image record and the FITS `IMAGETYP` keyword, with
/// nothing said to the operator.
FrameType _parseFrameType(String type) =>
    FrameType.fromRecord(type) ??
    (throw BadRequestError(
      field: 'frameType',
      expected: 'one of: ${FrameType.values.map((t) => t.record).join(', ')}',
      message: 'Unknown frame type "$type"',
    ));

/// Sentinel used to flag the cancellation branch of a `Future.any` race
/// against a long-running backend call. We can't pass `null` because the
/// race's result type is non-nullable; a sentinel keeps the type system
/// happy without requiring a wrapper class on every result type.
class _CancelledMarker {
  const _CancelledMarker._();
  static const _CancelledMarker instance = _CancelledMarker._();
}
