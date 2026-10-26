import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/current_frame_analysis_provider.dart';
import 'package:skotiq_core/src/providers/runtime_mirror/channels/frame_solve_channel.dart';

// A linked client draws the host's frame solve over its copy of the frame; it
// needs the CD matrix and SIP block, because the scalar rotation cannot say
// whether the frame is mirrored.
void main() {
  test('the host sends the solve with its CD matrix and SIP block', () {
    final encoded = const FrameSolveChannel().encode((
      path: '/lights/NGC0891_L_0001.fits',
      solve: FrameSolveVm(
        frameCapturedAt: DateTime.utc(2026, 10, 21, 3),
        status: FrameSolveStatus.solved,
        raDegrees: 35.633,
        decDegrees: 42.349,
        rotationDeg: -21.37,
        pixelScaleArcsec: 0.788,
        cd: (
          cd1_1: 2.0379e-4,
          cd1_2: 7.981e-5,
          cd2_1: -7.976e-5,
          cd2_2: 2.0386e-4,
        ),
        sip: '{"aOrder":3}',
      ),
    ))!;
    expect(encoded['cd'], [2.0379e-4, 7.981e-5, -7.976e-5, 2.0386e-4]);
    expect(encoded['sip'], '{"aOrder":3}');
  });
}
