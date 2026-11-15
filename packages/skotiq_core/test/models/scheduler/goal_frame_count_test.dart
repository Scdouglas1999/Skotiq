import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';

void main() {
  test('a goal counts every spelling of its filter and nothing else', () {
    const frames = {
      'Ha': 4,
      'Ha 7nm': 30,
      'Ha/OIII': 6,
      'L': 3,
      'L-eXtreme': 5,
      'lum': 2,
      '': 7,
    };
    expect(
      goalFrameCount('Ha', frames),
      34,
      reason: 'frames from before and after a rename to "Ha 7nm" both count',
    );
    expect(goalFrameCount('L', frames), 5);
    expect(goalFrameCount('Luminance', frames), 5);
    expect(goalFrameCount('OIII', frames), 0);
    expect(goalFrameCount('R', const {'UV/IR Cut': 9, 'IR Pass': 2}), 0);
  });

  test('the unfiltered goal counts the frames that name no filter', () {
    expect(goalFrameCount('', const {'': 4, '  ': 1, 'L': 9}), 5);
  });
}
