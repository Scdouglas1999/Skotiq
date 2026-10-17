import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../models/annotation_data.dart';

class SimbadProvider {
  static const String _baseUrl =
      'http://simbad.u-strasbg.fr/simbad/sim-tap/sync';

  Future<ObjectData?> queryByCoordinates(
    double ra,
    double dec, {
    double radiusArcmin = 1.0,
  }) async {
    // ADQL Query
    final adql =
        '''
      SELECT TOP 1
      basic.main_id, basic.ra, basic.dec, basic.coo_err_maj, basic.coo_err_min, 
      basic.coo_err_angle, basic.otype, basic.sp_type,
      flux.V, flux.B, flux.R,
      dist.plx_value, dist.plx_err
      FROM basic
      LEFT JOIN flux ON basic.oid = flux.oidref
      LEFT JOIN dist ON basic.oid = dist.oidref
      WHERE 1=CONTAINS(POINT('ICRS', basic.ra, basic.dec), CIRCLE('ICRS', $ra, $dec, ${radiusArcmin / 60.0}))
    ''';

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        body: {
          'request': 'doQuery',
          'lang': 'adql',
          'format': 'json',
          'query': adql,
        },
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final data = json['data'];

        if (data != null && (data as List).isNotEmpty) {
          final row = data[0];
          // Parse row data (simplified mapping)
          // Note: SIMBAD JSON format is [[val1, val2, ...], ...]

          return ObjectData(
            description: 'Identified via SIMBAD',
            objectClass: row[6]?.toString(), // otype
            spectralType: _parseSpectralType(row[7]?.toString()),
            parallax: _parseDouble(row[11]),
            distance: _calculateDistance(_parseDouble(row[11])),
            simbadId: row[0]?.toString(),
            dataSource: 'SIMBAD',
            lastUpdated: DateTime.now(),
          );
        }
      }
    } catch (e) {
      developer.log(
        '[SIMBAD] Error: $e',
        name: 'SimbadProvider',
        level: 900,
        error: e,
      );
    }

    return null;
  }

  /// Resolve a name fragment to a list of SIMBAD objects.
  ///
  /// Hits the public TAP service with a LIKE query against the `ident` table
  /// so any name SIMBAD knows about (M, NGC, IC, HD, HIP, common names, etc.)
  /// can resolve. Returns up to [limit] best matches ordered by main_id length
  /// (shorter == more canonical).
  ///
  /// Returns an empty list on network failure rather than throwing — the
  /// caller (planner search) wants a partial result if SIMBAD is down, not
  /// to crash the search UI. Errors are still logged via developer.log.
  Future<List<SimbadNameMatch>> searchByName(
    String query, {
    int limit = 25,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const <SimbadNameMatch>[];

    // SIMBAD's ident.id stores names with normalized whitespace ("M  31",
    // "NGC 7635"). To match user typing "m31" / "ngc7635" we wildcard on
    // BOTH sides AND also try a no-space variant. ADQL doesn't have a
    // REGEXP_REPLACE that's portable across TAP impls, so we OR two LIKE
    // patterns instead.
    final escaped = trimmed.replaceAll("'", "''");
    final patternA = '%$escaped%';
    final patternB = '%${escaped.replaceAll(RegExp(r'\s+'), '')}%';

    final adql =
        '''
      SELECT TOP $limit basic.main_id, basic.ra, basic.dec, basic.otype, flux.V
      FROM basic
      LEFT JOIN flux ON basic.oid = flux.oidref AND flux.filter = 'V'
      JOIN ident ON basic.oid = ident.oidref
      WHERE ident.id LIKE '$patternA' OR REPLACE(ident.id, ' ', '') LIKE '$patternB'
    ''';

    try {
      final response = await http.post(
        Uri.parse(_baseUrl),
        body: {
          'request': 'doQuery',
          'lang': 'adql',
          'format': 'json',
          'query': adql,
        },
      );
      if (response.statusCode != 200) {
        developer.log(
          '[SIMBAD] name search HTTP ${response.statusCode}',
          name: 'SimbadProvider',
          level: 900,
        );
        return const <SimbadNameMatch>[];
      }
      final json = jsonDecode(response.body);
      final data = json['data'];
      if (data is! List) return const <SimbadNameMatch>[];

      final out = <SimbadNameMatch>[];
      final seenIds = <String>{};
      for (final row in data) {
        if (row is! List || row.length < 4) continue;
        final mainId = row[0]?.toString().trim();
        if (mainId == null || mainId.isEmpty) continue;
        if (!seenIds.add(mainId)) continue;
        final raDeg = _parseDouble(row[1]);
        final decDeg = _parseDouble(row[2]);
        if (raDeg == null || decDeg == null) continue;
        out.add(
          SimbadNameMatch(
            mainId: mainId,
            raHours: raDeg / 15.0,
            decDegrees: decDeg,
            objectType: row[3]?.toString(),
            magnitudeV: row.length > 4 ? _parseDouble(row[4]) : null,
          ),
        );
      }
      // Why: SIMBAD returns matches in DB-internal order; ranking by main_id
      // length puts canonical identifiers ("M 31") before catalog crossrefs
      // ("LEDA 2557").
      out.sort((a, b) => a.mainId.length.compareTo(b.mainId.length));
      return out;
    } catch (e) {
      developer.log(
        '[SIMBAD] name search error: $e',
        name: 'SimbadProvider',
        level: 900,
        error: e,
      );
      return const <SimbadNameMatch>[];
    }
  }

  SpectralClass? _parseSpectralType(String? spType) {
    if (spType == null || spType.isEmpty) return null;
    final firstChar = spType[0].toUpperCase();
    switch (firstChar) {
      case 'O':
        return SpectralClass.o;
      case 'B':
        return SpectralClass.b;
      case 'A':
        return SpectralClass.a;
      case 'F':
        return SpectralClass.f;
      case 'G':
        return SpectralClass.g;
      case 'K':
        return SpectralClass.k;
      case 'M':
        return SpectralClass.m;
      default:
        return SpectralClass.unknown;
    }
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  double? _calculateDistance(double? parallax) {
    if (parallax == null || parallax <= 0) return null;
    return 1000.0 / parallax; // parsecs
  }
}

/// Single SIMBAD name-resolution result for the planner search fallback.
class SimbadNameMatch {
  final String mainId;
  final double raHours;
  final double decDegrees;
  final String? objectType;
  final double? magnitudeV;

  const SimbadNameMatch({
    required this.mainId,
    required this.raHours,
    required this.decDegrees,
    this.objectType,
    this.magnitudeV,
  });
}
