import 'dart:convert';
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import '../models/annotation_data.dart';

class GaiaProvider {
  static const String _baseUrl = 'https://gea.esac.esa.int/tap-server/tap/sync';

  Future<ObjectData?> queryByCoordinates(
    double ra,
    double dec, {
    double radiusArcsec = 5.0,
  }) async {
    final adql =
        '''
      SELECT TOP 1
      source_id, ra, dec, parallax, pmra, pmdec, 
      phot_g_mean_mag, teff_gspphot, mass_flame, radius_flame, dist_gspphot
      FROM gaiadr3.gaia_source
      WHERE 1=CONTAINS(POINT('ICRS', ra, dec), CIRCLE('ICRS', $ra, $dec, ${radiusArcsec / 3600.0}))
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
          // Gaia JSON is usually list of lists

          return ObjectData(
            description: 'Gaia DR3 Source',
            parallax: _parseDouble(row[3]),
            distance: _parseDouble(row[10]), // dist_gspphot
            temperature: _parseDouble(row[7]), // teff
            mass: _parseDouble(row[8]), // mass
            radius: _parseDouble(row[9]), // radius
            dataSource: 'Gaia DR3',
            lastUpdated: DateTime.now(),
          );
        }
      }
    } catch (e) {
      developer.log(
        '[GAIA] Error: $e',
        name: 'GaiaProvider',
        level: 900,
        error: e,
      );
    }

    return null;
  }

  double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
