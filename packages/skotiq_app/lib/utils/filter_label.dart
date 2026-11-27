/// Filter labels and frame captions that do not invent a filter.
///
/// A one-shot-color camera, a DSLR, or a mono rig without a wheel takes frames
/// with no filter. They are marked [kNoFilterLabel], never captioned "L"
/// (Luminance). Use [filterLabel] for a filter alone and [frameCaption] for a
/// frame.
library;

import 'package:skotiq_core/models.dart' show FrameType;

/// Marker shown when a frame carries no filter.
///
/// An em dash rather than a word: these captions sit in cells ~40px wide
/// alongside exposure and time, where 'Unfiltered' would ellipsize into
/// something less readable than a plain "nothing here". Surfaces with room for
/// prose should keep saying 'Unfiltered' / 'No filter'.
const String kNoFilterLabel = '—';

/// The filter's name, or [kNoFilterLabel] when the frame has none.
///
/// Treats an empty/whitespace name as absent: the capture path stores `''`
/// rather than NULL in some paths, and `'' ` would render as a blank gap that
/// looks like a layout bug.
String filterLabel(String? filter) {
  final trimmed = filter?.trim();
  if (trimmed == null || trimmed.isEmpty) return kNoFilterLabel;
  return trimmed;
}

/// A frame's compact caption ([FrameType.caption]), with [kNoFilterLabel]
/// for a light with no filter. [frameType] is the stored spelling (`light`,
/// `dark`, `flat`, `bias`, `darkflat`, `snapshot`).
String frameCaption({required String? filter, required String frameType}) =>
    FrameType.captionOfRecord(frameType, filter) ?? kNoFilterLabel;
