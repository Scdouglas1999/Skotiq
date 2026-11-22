// The stored key and text of every setting the guiding, focuser and remote
// access editors write. Installed hosts hold these rows, so an editor that
// moves onto shared code must keep writing them exactly so.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/settings.dart';

void main() {
  late SkotiqDatabase db;

  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<String?> stored<T>(Setting<T> setting, T value) async {
    await db.settingsDao.write(setting, value);
    return db.settingsDao.getSetting(setting.key);
  }

  test('guiding: dither size, RA only and settle rows', () async {
    for (final scale in ['Small', 'Medium', 'Large']) {
      expect(await stored(AppSettingDefs.ditherScale, scale), scale);
    }
    expect(AppSettingDefs.ditherScale.key, 'dither_scale');
    expect(await stored(AppSettingDefs.ditherRaOnly, true), 'true');
    expect(AppSettingDefs.ditherRaOnly.key, 'dither_ra_only');
    expect(await stored(AppSettingDefs.settleThreshold, 1.5), '1.5');
    expect(AppSettingDefs.settleThreshold.key, 'settle_threshold');
    expect(await stored(AppSettingDefs.settleTime, 12), '12');
    expect(AppSettingDefs.settleTime.key, 'settle_time');
    expect(await stored(AppSettingDefs.settleTimeout, 90), '90');
    expect(AppSettingDefs.settleTimeout.key, 'settle_timeout');
  });

  test('focuser: temperature compensation and backlash rows', () async {
    expect(await stored(AppSettingDefs.tempCompensation, true), 'true');
    expect(AppSettingDefs.tempCompensation.key, 'temp_compensation');
    expect(await stored(AppSettingDefs.tempCoefficient, -7.5), '-7.5');
    expect(AppSettingDefs.tempCoefficient.key, 'temp_coefficient');
    expect(await stored(AppSettingDefs.afBacklashIn, 400), '400');
    expect(AppSettingDefs.afBacklashIn.key, 'af_backlash_in');
    expect(await stored(AppSettingDefs.tempCompensationMinSteps, 9), '9');
    expect(
      AppSettingDefs.tempCompensationMinSteps.key,
      'temp_compensation_min_steps',
    );
  });

  test('remote access: the web server port row keeps any port', () async {
    expect(AppSettingDefs.webServerPort.key, 'web_server_port');
    expect(await stored(AppSettingDefs.webServerPort, 9090), '9090');
    expect(await stored(AppSettingDefs.webServerPort, 80), '80');
    expect(await stored(AppSettingDefs.webServerPort, 65535), '65535');
  });
}
