import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

// The strategy ids are stored in app settings: they never change.
void main() {
  test('stored strategy ids', () {
    expect(
      {for (final s in SmartNightStrategy.values) s.name: s.id},
      {
        'autoLrgb': 'auto_lrgb',
        'narrowbandHoo': 'narrowband_hoo',
        'narrowbandSho': 'narrowband_sho',
        'oscOneShot': 'osc_one_shot',
        'narrowbandHa': 'narrowband_ha',
        'haLrgb': 'ha_lrgb',
        'rgb': 'rgb',
        'luminance': 'luminance',
        'narrowbandOiii': 'narrowband_oiii',
        'narrowbandSii': 'narrowband_sii',
      },
    );
    for (final s in SmartNightStrategy.values) {
      expect(SmartNightStrategy.fromId(s.id), s);
    }
    expect(SmartNightStrategy.fromId('mono_lrgb'), SmartNightStrategy.autoLrgb);
    expect(SmartNightStrategy.fromId('auto'), isNull);
    expect(SmartNightStrategy.fromId('nonsense'), isNull);
  });
}
