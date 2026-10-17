/// Filter labels that do not invent a filter.
///
/// Frame chips and thumbnail captions across the app were written as
/// `'${image.filter ?? 'L'}'`, which labels every unfiltered frame "L" —
/// Luminance. A one-shot-colour camera, a DSLR, or any mono rig imaging without
/// a wheel produces frames with no filter at all, so the whole night reads as
/// Luminance data that was never shot through a Luminance filter. Spotted on the
/// Dashboard's Recent Frames strip while driving a sequence with no filter
/// wheel: three unfiltered subs, all captioned "L".
///
/// The same codebase already had honest spellings in other places (`'—'` on the
/// sequencer's frame-detail chips, `'Unfiltered'` in project tracking,
/// `'No filter'` in the photometric wizard), so the fabricated 'L' was also an
/// inconsistency. Use [filterLabel] for compact captions and chips.
library;

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
