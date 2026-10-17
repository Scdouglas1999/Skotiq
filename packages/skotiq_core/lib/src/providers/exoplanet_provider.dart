import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../models/annotation_data.dart';

class ExoplanetProvider {
  static const String _baseUrl =
      'https://exoplanetarchive.ipac.caltech.edu/TAP/sync';

  Future<List<ExoplanetData>> queryByStarName(String starName) async {
    // Sanitize star name for ADQL
    final sanitizedName = starName.replaceAll("'", "''");

    final adql =
        '''
      SELECT pl_name, pl_bmassj, pl_radj, pl_orbper, pl_orbsmax, pl_orbeccen, 
             discoverymethod, disc_year, pl_eqt
      FROM ps
      WHERE hostname = '$sanitizedName' OR default_flag = 1
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
        // Note: Exoplanet Archive JSON format might differ, usually it's a list of maps or list of lists
        // Assuming standard TAP JSON output

        // Check if response is list (some TAP services return list of maps)
        if (json is List) {
          return json.map((row) => _parseExoplanet(row)).toList();
        }
      }
    } catch (e) {
      developer.log(
        '[EXOPLANET] Error: $e',
        name: 'ExoplanetProvider',
        level: 900,
        error: e,
      );
    }

    return [];
  }

  ExoplanetData _parseExoplanet(Map<String, dynamic> row) {
    return ExoplanetData(
      name: row['pl_name']?.toString() ?? 'Unknown',
      mass: _parseDouble(row['pl_bmassj']),
      radius: _parseDouble(row['pl_radj']),
      orbitalPeriod: _parseDouble(row['pl_orbper']),
      semiMajorAxis: _parseDouble(row['pl_orbsmax']),
      eccentricity: _parseDouble(row['pl_orbeccen']),
      discoveryMethod: row['discoverymethod']?.toString(),
      discoveryYear: int.tryParse(row['disc_year']?.toString() ?? ''),
      equilibriumTemp: _parseDouble(row['pl_eqt']),
    );
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
