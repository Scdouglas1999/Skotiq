import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/calibration_master_builder.dart';

// One file-name style for every master, end-of-night's: what the master does
// not know is left out, the read mode is named, and the stamp has seconds so
// two masters built in one minute differ.
void main() {
  final at = DateTime(2026, 10, 25, 9, 0, 7);

  String name(
    String kind, {
    double exposure = 90,
    int? gain = 76,
    int? offset = 15,
    double? temp = -10.2,
    String? filter,
    String? readMode,
  }) => calibrationMasterFileName(
    kind: kind,
    builtAt: at,
    exposureSeconds: exposure,
    gain: gain,
    offset: offset,
    binX: 1,
    temperatureC: temp,
    filter: filter,
    readMode: readMode,
  );

  test('a master names what it knows and stamps seconds', () {
    expect(
      name('dark'),
      'MasterDark_90s_g76_o15_m10C_bin1_20261025-090007.fits',
    );
    expect(
      name('bias', gain: null, offset: null, temp: null),
      'MasterBias_notemp_bin1_20261025-090007.fits',
    );
    expect(
      name('flat', filter: 'Ha 7nm', temp: 0.4),
      'MasterFlat_Ha_7nm_g76_o15_p0C_bin1_20261025-090007.fits',
    );
    expect(
      name('flat'),
      'MasterFlat_NoFilter_g76_o15_m10C_bin1_20261025-090007.fits',
    );
    expect(
      name('dark', exposure: 0.5),
      'MasterDark_0p5s_g76_o15_m10C_bin1_20261025-090007.fits',
    );
    expect(
      name('bias', gain: null, offset: null, readMode: 'High Gain 16BIT'),
      'MasterBias_m10C_bin1_HighGain16BIT_20261025-090007.fits',
    );
  });
}
