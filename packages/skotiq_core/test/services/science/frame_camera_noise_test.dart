import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/services/frame_header.dart';
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
    // Frame headers by path, as the native reader gives them.
    final headers = <String, FrameHeader>{};
    String frame(int? gain) {
      final path = '/frames/frame-$gain.fits';
      headers[path] = FrameHeader({
        'MAXADU': 65520,
        'INSTRUME': 'ZWO ASI1600MM-Cool',
        'GAIN': ?gain,
      });
      return path;
    }

    Future<({double? gain, double? readNoise})> noiseOf(
      String path, {
      int? capturedGain,
    }) => frameCameraNoise(
      settings,
      path,
      capturedGain: capturedGain,
      readHeader: (path) async => headers[path]!,
    );

    final old = frame(76);
    final unity = frame(139);
    final noise = await noiseOf(old);
    expect(noise.gain, closeTo(0.12962, 0.00001));
    expect(noise.readNoise, closeTo(2.06765, 0.00001));
    expect((await noiseOf(unity)).gain, 0.0625);
    expect(await noiseOf(old), noise);
    final unknown = frame(null);
    expect((await noiseOf(unknown)).gain, isNull);
    expect(await noiseOf(unknown, capturedGain: 76), noise);
    await settings.setSetting(ScienceCameraAutoConfig.autoManagedKey, 'false');
    expect((await noiseOf(old)).gain, 0.0625);
  });
}
