import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/calibration_master_builder.dart';

void main() {
  final at = DateTime(2026, 10, 25, 9, 0, 7);

  String name(
    String kind,
    CalibrationMasterNameStyle style, {
    double exposure = 90,
    int? gain = 76,
    int? offset = 15,
    double? temp = -10.2,
    String? filter,
    String? readMode,
  }) => calibrationMasterFileName(
    kind: kind,
    style: style,
    builtAt: at,
    exposureSeconds: exposure,
    gain: gain,
    offset: offset,
    binX: 1,
    temperatureC: temp,
    filter: filter,
    readMode: readMode,
  );

  test('the backlog marks what it does not know and stamps seconds', () {
    const style = CalibrationMasterNameStyle.backlog;
    expect(
      name('dark', style),
      'MasterDark_90s_g76_o15_m10C_bin1_20261025-090007.fits',
    );
    expect(
      name('bias', style, gain: null, offset: null, temp: null),
      'MasterBias_gx_ox_notemp_bin1_20261025-090007.fits',
    );
    expect(
      name('flat', style, filter: 'Ha 7nm', temp: 0.4),
      'MasterFlat_Ha_7nm_g76_o15_p0C_bin1_20261025-090007.fits',
    );
    expect(
      name('flat', style),
      'MasterFlat_NoFilter_g76_o15_m10C_bin1_20261025-090007.fits',
    );
    expect(
      name('dark', style, exposure: 0.5),
      'MasterDark_0p5s_g76_o15_m10C_bin1_20261025-090007.fits',
    );
  });

  test('end-of-night leaves out what it does not know and adds the mode', () {
    const style = CalibrationMasterNameStyle.endOfNight;
    expect(
      name('dark', style, exposure: 3),
      'MasterDark_3s_g76_o15_m10C_bin1_20261025-0900.fits',
    );
    expect(
      name(
        'bias',
        style,
        gain: null,
        offset: null,
        readMode: 'High Gain 16BIT',
      ),
      'MasterBias_m10C_bin1_HighGain16BIT_20261025-0900.fits',
    );
  });
}
