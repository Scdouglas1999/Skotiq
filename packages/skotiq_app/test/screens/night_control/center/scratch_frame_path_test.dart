import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';

void main() {
  test('a Windows liveview path is scratch on this process', () {
    expect(
      nightIsScratchFrame(
        r'C:\Users\scdou\AppData\Local\Temp\liveview_ASI1600.fits',
      ),
      isTrue,
    );
    expect(
      nightIsScratchFrame(r'C:\captures\M74_R_001.fits'),
      isFalse,
    );
    expect(
      nightIsScratchFrame('/tmp/liveview_x.fits'),
      isTrue,
    );
  });
}
