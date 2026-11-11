part of '../device_handlers.dart';

/// Parse the wire `frameType` string into a [FrameType].
///
/// An unrecognised string is a bad request, never [FrameType.light]: coercing
/// it would let a typo in a calibration script mislabel darks and flats as
/// lights in both the image record and the FITS `IMAGETYP` keyword, with
/// nothing said to the operator. Every declared enum value — [FrameType.snapshot]
/// included — is mapped here so the rejection arm only catches real typos.
FrameType _parseFrameType(String type) {
  switch (type.toLowerCase()) {
    case 'light':
      return FrameType.light;
    case 'dark':
      return FrameType.dark;
    case 'flat':
      return FrameType.flat;
    case 'bias':
      return FrameType.bias;
    case 'darkflat':
    case 'dark_flat':
      return FrameType.darkFlat;
    case 'snapshot':
      return FrameType.snapshot;
    default:
      throw BadRequestError(
        field: 'frameType',
        expected: 'one of: light, dark, flat, bias, darkFlat, snapshot',
        message:
            'Unknown frame type "$type"; expected one of '
            'light, dark, flat, bias, darkFlat, snapshot',
      );
  }
}

/// Internal sentinel raised by `_dispatchConnect` when the requested
/// device id does not match anything `DeviceService.discoverDevices`
/// returned. The connect handler translates this into a structured
/// `device_not_found` HTTP 404 with the original service message.
class _DeviceNotFoundFailure implements Exception {
  final String message;
  _DeviceNotFoundFailure(this.message);
  @override
  String toString() => message;
}

/// Sentinel used to flag the cancellation branch of a `Future.any` race
/// against a long-running backend call. We can't pass `null` because the
/// race's result type is non-nullable; a sentinel keeps the type system
/// happy without requiring a wrapper class on every result type.
class _CancelledMarker {
  const _CancelledMarker._();
  static const _CancelledMarker instance = _CancelledMarker._();
}
