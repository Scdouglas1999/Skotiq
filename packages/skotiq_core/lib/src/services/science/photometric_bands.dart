/// Which catalog band a filter's zero point and magnitudes refer to.
///
/// Zero points, transparency, differential photometry and AAVSO export all
/// key on this, so a frame in one filter is never compared with, or labeled
/// as, another band.
library;

/// A catalog photometric band the science pipeline can calibrate against.
enum PhotometricBand {
  /// Johnson B (APASS `Bmag`).
  johnsonB('B'),

  /// Johnson V (APASS `Vmag`).
  johnsonV('V'),

  /// Sloan r' (APASS `r'mag`).
  sloanR('r');

  const PhotometricBand(this.code);

  /// Short code stored in the database and in the MAGZPBND FITS keyword.
  final String code;

  static PhotometricBand? fromCode(String? code) {
    for (final band in values) {
      if (band.code == code) return band;
    }
    return null;
  }
}

/// How one filter is calibrated.
class FilterBandMapping {
  const FilterBandMapping({
    required this.filterKey,
    required this.band,
    required this.isStandard,
    required this.colorTermBv,
    required this.aavsoFilterCode,
    required this.label,
  });

  /// Normalized filter name ('L', 'R', 'G', 'B', 'V', 'Ha', ... or '' for
  /// no filter).
  final String filterKey;

  /// The catalog band the zero point is fitted against.
  final PhotometricBand band;

  /// False when the filter has no catalog band of its own: its zero point is
  /// a V-equivalent good for tracking the sky, not a standard magnitude.
  final bool isStandard;

  /// Declared color term: the reference magnitude of a catalog star is
  /// `band + colorTermBv * (B - V)`. Zero for every mapping here, so the
  /// zero point refers to the band itself and the per-star scatter includes
  /// the color spread of the field.
  final double colorTermBv;

  /// AAVSO filter code, or null when AAVSO has none for this filter.
  final String? aavsoFilterCode;

  /// Plain description for UI text and the FITS comment.
  final String label;
}

/// Normalize a FITS FILTER value or a filter wheel slot name.
String normalizeFilterKey(String? filter) {
  final raw = (filter ?? '').trim();
  if (raw.isEmpty) return '';
  final lower = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  const aliases = {
    'l': 'L',
    'lum': 'L',
    'luminance': 'L',
    'clear': 'L',
    'clr': 'L',
    'none': '',
    'r': 'R',
    'red': 'R',
    'rc': 'R',
    'g': 'G',
    'green': 'G',
    'b': 'B',
    'blue': 'B',
    'v': 'V',
    'johnsonv': 'V',
    'johnsonb': 'B',
    'ha': 'Ha',
    'halpha': 'Ha',
    'oiii': 'OIII',
    'o3': 'OIII',
    'sii': 'SII',
    's2': 'SII',
  };
  return aliases[lower] ?? raw;
}

/// The calibration mapping for [filter].
///
/// B → Johnson B, G and V → Johnson V, R → Sloan r'. L, clear, no filter,
/// narrowband and unknown filters get a V zero point marked non-standard.
FilterBandMapping filterBandFor(String? filter) {
  final key = normalizeFilterKey(filter);
  switch (key) {
    case 'B':
      return const FilterBandMapping(
        filterKey: 'B',
        band: PhotometricBand.johnsonB,
        isStandard: true,
        colorTermBv: 0,
        aavsoFilterCode: 'TB',
        label: 'Johnson B',
      );
    case 'G':
      return const FilterBandMapping(
        filterKey: 'G',
        band: PhotometricBand.johnsonV,
        isStandard: true,
        colorTermBv: 0,
        aavsoFilterCode: 'TG',
        label: 'Johnson V',
      );
    case 'V':
      return const FilterBandMapping(
        filterKey: 'V',
        band: PhotometricBand.johnsonV,
        isStandard: true,
        colorTermBv: 0,
        aavsoFilterCode: 'V',
        label: 'Johnson V',
      );
    case 'R':
      return const FilterBandMapping(
        filterKey: 'R',
        band: PhotometricBand.sloanR,
        isStandard: true,
        colorTermBv: 0,
        aavsoFilterCode: 'TR',
        label: "Sloan r'",
      );
    case 'L':
    case '':
      return FilterBandMapping(
        filterKey: key,
        band: PhotometricBand.johnsonV,
        isStandard: false,
        colorTermBv: 0,
        aavsoFilterCode: 'CV',
        label: 'V-equivalent (clear, not a standard band)',
      );
    default:
      return FilterBandMapping(
        filterKey: key,
        band: PhotometricBand.johnsonV,
        isStandard: false,
        colorTermBv: 0,
        aavsoFilterCode: null,
        label: 'V-equivalent (no catalog band for $key)',
      );
  }
}
