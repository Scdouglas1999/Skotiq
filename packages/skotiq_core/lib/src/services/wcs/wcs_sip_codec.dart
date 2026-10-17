// Serialization for the SIP distortion block persisted in the v51
// `captured_images.solved_sip` column. The blob is a JSON object
// `{aOrder,bOrder,a,b,apOrder,bpOrder,ap,bp}` where `a`/`b`/`ap`/`bp` are
// the row-major coefficient lists; null/empty SIP serializes to null so the
// projection falls back to the isotropic (or CD-only) path.

import 'dart:convert';

/// Decoded SIP block — orders plus the four coefficient lists. All four
/// lists are non-growable copies safe to hand straight to `SolvedWcs`.
typedef DecodedSip = ({
  int aOrder,
  int bOrder,
  List<double> aCoeffs,
  List<double> bCoeffs,
  int apOrder,
  int bpOrder,
  List<double> apCoeffs,
  List<double> bpCoeffs,
});

/// Encode the SIP block to the `solved_sip` JSON string, or null when there
/// is no forward distortion (`aOrder`/`bOrder` <= 0 or empty coefficients).
String? encodeSolvedSip({
  required int aOrder,
  required int bOrder,
  required List<double> aCoeffs,
  required List<double> bCoeffs,
  required int apOrder,
  required int bpOrder,
  required List<double> apCoeffs,
  required List<double> bpCoeffs,
}) {
  if (aOrder <= 0 || bOrder <= 0 || aCoeffs.isEmpty || bCoeffs.isEmpty) {
    return null;
  }
  return jsonEncode({
    'aOrder': aOrder,
    'bOrder': bOrder,
    'a': aCoeffs,
    'b': bCoeffs,
    'apOrder': apOrder,
    'bpOrder': bpOrder,
    'ap': apCoeffs,
    'bp': bpCoeffs,
  });
}

/// Parse a `solved_sip` JSON string back into a [DecodedSip], or null when
/// the input is null/empty/malformed (treated as no distortion).
DecodedSip? decodeSolvedSip(String? json) {
  if (json == null || json.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final map = decoded;
  List<double> coeffs(String key) =>
      (map[key] as List?)
          ?.map((v) => (v as num).toDouble())
          .toList(growable: false) ??
      const [];
  return (
    aOrder: (map['aOrder'] as num?)?.toInt() ?? 0,
    bOrder: (map['bOrder'] as num?)?.toInt() ?? 0,
    aCoeffs: coeffs('a'),
    bCoeffs: coeffs('b'),
    apOrder: (map['apOrder'] as num?)?.toInt() ?? 0,
    bpOrder: (map['bpOrder'] as num?)?.toInt() ?? 0,
    apCoeffs: coeffs('ap'),
    bpCoeffs: coeffs('bp'),
  );
}
