// A flat step in a sequence loaded through POST /api/sequencer/load takes the
// host's "Exposure calibration attempts" setting unless it names its own.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/handlers/sequencer_handlers.dart';

void main() {
  String wire(Map<String, Object?> flat) => jsonEncode({
        'name': 'Flats',
        'root': {
          'id': 'root',
          'children': [
            {
              'id': 'flat-1',
              'node_type': {'FlatWizard': flat},
            },
          ],
        },
      });

  Map<String, dynamic> flatOf(String json) {
    final root = (jsonDecode(json) as Map)['root'] as Map;
    final child = (root['children'] as List).single as Map;
    return Map<String, dynamic>.from(
      (child['node_type'] as Map)['FlatWizard'] as Map,
    );
  }

  test('a flat step without a limit gets the setting', () {
    final out = withFlatCalibrationAttempts(wire({'target_adu': 30000}), 20);
    expect(flatOf(out)['max_iterations'], 20);
  });

  test('a flat step with its own limit keeps it', () {
    final input = wire({'target_adu': 30000, 'max_iterations': 7});
    expect(withFlatCalibrationAttempts(input, 20), input);
  });

  test('a sequence without flats passes through untouched', () {
    const input = '{"name":"Lights","root":{"id":"root","children":[]}}';
    expect(withFlatCalibrationAttempts(input, 20), input);
    expect(withFlatCalibrationAttempts('not json', 20), 'not json');
  });
}
