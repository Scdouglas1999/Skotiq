import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/frame_camera_noise.dart';

void main() {
  test('saved gain wins over stale settings and a later camera gain', () async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsDao(db);
    await settings.setSettings({
      ScienceCameraAutoConfig.gainKey: '0.0625',
      ScienceCameraAutoConfig.readNoiseKey: '1.70',
    });
    final dir = await Directory.systemTemp.createTemp('science-frame-gain-');
    addTearDown(() => dir.delete(recursive: true));
    Future<String> frame(int? gain) async {
      final path = '${dir.path}/frame-$gain.fits';
      final cards = [
        'SIMPLE  = T',
        'BITPIX  = 16',
        'MAXADU  = 65520',
        "INSTRUME= 'ZWO ASI1600MM-Cool'",
        if (gain != null) 'GAIN    = $gain',
        'END',
      ];
      await File(
        path,
      ).writeAsString(cards.map((c) => c.padRight(80)).join().padRight(2880));
      return path;
    }

    final old = await frame(76);
    final unity = await frame(139);
    final noise = await frameCameraNoise(settings, old);
    expect(noise.gain, closeTo(0.12962, 0.00001));
    expect(noise.readNoise, closeTo(2.06765, 0.00001));
    expect((await frameCameraNoise(settings, unity)).gain, 0.0625);
    expect(await frameCameraNoise(settings, old), noise);
    final unknown = await frame(null);
    expect((await frameCameraNoise(settings, unknown)).gain, isNull);
    expect(await frameCameraNoise(settings, unknown, capturedGain: 76), noise);
    await settings.setSetting(ScienceCameraAutoConfig.autoManagedKey, 'false');
    expect((await frameCameraNoise(settings, old)).gain, 0.0625);
  });
}
