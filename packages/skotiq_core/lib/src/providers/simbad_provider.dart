import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../models/annotation_data.dart';
import '../services/sesame_name_resolver.dart';

class SimbadProvider {
  static const String _baseUrl =
      'http://simbad.u-strasbg.fr/simbad/sim-tap/sync';
  static const String _tapUrl =
      'https://simbad.cds.unistra.fr/simbad/sim-tap/sync';

  final http.Client? _client;
  final SesameNameResolver _sesame;

  SimbadProvider({http.Client? client, SesameNameResolver? sesame})
    : _client = client,
      _sesame = sesame ?? SesameNameResolver(client: client);

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

  /// Search SIMBAD for objects matching a typed name, best match first.
  ///
  /// The exact object the name identifies (resolved through Sesame, the same
  /// resolver SIMBAD's search box uses) always comes first. Objects with an
  /// identifier merely containing the text follow, so "M42" lists M 42 and
  /// only then things like "[SSP2021] M42".
  ///
  /// Throws [TargetNameLookupUnavailable] only when SIMBAD could not be
  /// reached at all, so the planner can say the lookup failed instead of
  /// claiming SIMBAD has no such object. An empty list is a real answer.
  Future<List<SimbadNameMatch>> searchByName(
    String query, {
    int limit = 25,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2) return const <SimbadNameMatch>[];

    final out = <SimbadNameMatch>[];
    TargetNameLookupUnavailable? exactFailure;
    try {
      final exact = await _sesame.resolve(trimmed);
      if (exact != null) {
        out.add(
          SimbadNameMatch(
            mainId: exact.mainId,
            raHours: exact.raHours,
            decDegrees: exact.decDegrees,
            objectType: exact.objectType,
            exact: true,
          ),
        );
      }
    } on TargetNameLookupUnavailable catch (e) {
      exactFailure = e;
      developer.log(
        '[SIMBAD] exact name lookup unavailable: $e',
        name: 'SimbadProvider',
        level: 900,
      );
    }

    final partial = await _searchIdentifiersContaining(trimmed, limit);
    if (partial == null) {
      if (exactFailure != null) throw exactFailure;
      return out;
    }
    final seen = {for (final m in out) _compact(m.mainId)};
    final queryKey = _compact(trimmed);
    partial.removeWhere((m) => !seen.add(_compact(m.mainId)));
    // Why: TAP returns rows in DB-internal order. An identifier that starts
    // with the query reads as a closer match than one that only contains it,
    // and shorter main ids are the canonical ones ("M 31" before "LEDA 2557").
    int rank(SimbadNameMatch m) {
      final identifier = m.matchedIdentifier;
      if (identifier == null) return 1;
      return _compact(identifier).startsWith(queryKey) ? 0 : 1;
    }

    partial.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return a.mainId.length.compareTo(b.mainId.length);
    });
    out.addAll(partial);
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// SIMBAD identifiers containing [text]. ADQL on SIMBAD has no LOWER,
  /// ILIKE or REPLACE, and identifiers are stored with column padding
  /// ("M  42", "NGC  891"), so the text is tried as typed and upper-cased.
  /// Returns null when SIMBAD could not be queried.
  Future<List<SimbadNameMatch>?> _searchIdentifiersContaining(
    String text,
    int limit,
  ) async {
    final escaped = text.replaceAll("'", "''");
    final patterns = <String>{'%$escaped%', '%${escaped.toUpperCase()}%'};
    final where = patterns.map((p) => "ident.id LIKE '$p'").join(' OR ');
    final adql =
        '''
      SELECT TOP $limit basic.main_id, basic.ra, basic.dec, basic.otype, ident.id
      FROM basic
      JOIN ident ON basic.oid = ident.oidref
      WHERE $where
    ''';

    final client = _client ?? http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(_tapUrl),
            body: {
              'request': 'doQuery',
              'lang': 'adql',
              'format': 'json',
              'query': adql,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        developer.log(
          '[SIMBAD] name search HTTP ${response.statusCode}',
          name: 'SimbadProvider',
          level: 900,
        );
        return null;
      }
      final json = jsonDecode(response.body);
      final data = json is Map ? json['data'] : null;
      if (data is! List) return null;

      final out = <SimbadNameMatch>[];
      for (final row in data) {
        if (row is! List || row.length < 4) continue;
        final mainId = row[0]?.toString().trim();
        if (mainId == null || mainId.isEmpty) continue;
        final raDeg = _parseDouble(row[1]);
        final decDeg = _parseDouble(row[2]);
        if (raDeg == null || decDeg == null) continue;
        out.add(
          SimbadNameMatch(
            mainId: SesameNameResolver.displayIdentifier(mainId),
            raHours: raDeg / 15.0,
            decDegrees: decDeg,
            objectType: row[3]?.toString(),
            matchedIdentifier: row.length > 4 ? row[4]?.toString() : null,
          ),
        );
      }
      return out;
    } catch (e) {
      developer.log(
        '[SIMBAD] name search error: $e',
        name: 'SimbadProvider',
        level: 900,
        error: e,
      );
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  static String _compact(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

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

  /// True for the object the typed name identifies exactly (Sesame), false
  /// for objects that only have an identifier containing the text.
  final bool exact;

  /// The SIMBAD identifier that contained the text, for partial matches.
  final String? matchedIdentifier;

  const SimbadNameMatch({
    required this.mainId,
    required this.raHours,
    required this.decDegrees,
    this.objectType,
    this.magnitudeV,
    this.exact = false,
    this.matchedIdentifier,
  });
}
