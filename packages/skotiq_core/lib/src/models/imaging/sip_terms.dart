// The SIP distortion of a solve, and its form in the
// `captured_images.solved_sip` column: a JSON object
// `{aOrder,bOrder,a,b,apOrder,bpOrder,ap,bp}` where `a`/`b`/`ap`/`bp` are the
// row-major coefficient lists; no distortion is stored as null.

import 'dart:convert';

/// The SIP distortion of a solve: forward (`A`/`B`) and inverse (`AP`/`BP`)
/// orders with their row-major coefficients, term `(i, j)` at
/// `i * (order + 1) + j`. Zero orders and no coefficients are a plain TAN
/// solve.
typedef SipTerms = ({
  int aOrder,
  int bOrder,
  List<double> aCoeffs,
  List<double> bCoeffs,
  int apOrder,
  int bpOrder,
  List<double> apCoeffs,
  List<double> bpCoeffs,
});

/// A solve without distortion terms.
const SipTerms noSipTerms = (
  aOrder: 0,
  bOrder: 0,
  aCoeffs: <double>[],
  bCoeffs: <double>[],
  apOrder: 0,
  bpOrder: 0,
  apCoeffs: <double>[],
  bpCoeffs: <double>[],
);

/// Encode [sip] to the `solved_sip` JSON string, or null when it has no
/// forward distortion (`aOrder`/`bOrder` <= 0 or empty coefficients).
String? encodeSolvedSip(SipTerms sip) {
  if (sip.aOrder <= 0 ||
      sip.bOrder <= 0 ||
      sip.aCoeffs.isEmpty ||
      sip.bCoeffs.isEmpty) {
    return null;
  }
  return jsonEncode({
    'aOrder': sip.aOrder,
    'bOrder': sip.bOrder,
    'a': sip.aCoeffs,
    'b': sip.bCoeffs,
    'apOrder': sip.apOrder,
    'bpOrder': sip.bpOrder,
    'ap': sip.apCoeffs,
    'bp': sip.bpCoeffs,
  });
}

/// Parse a `solved_sip` JSON string back into [SipTerms], or null when the
/// input is null/empty/malformed (treated as no distortion).
SipTerms? decodeSolvedSip(String? json) {
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
