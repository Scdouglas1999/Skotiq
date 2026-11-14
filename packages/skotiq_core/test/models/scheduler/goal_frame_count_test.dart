import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';

void main() {
  test('a goal counts the spellings the filter-name rule matches', () {
    const frames = {'Ha 7nm': 30, 'L': 3, 'L-eXtreme': 5, 'lum': 2, '': 7};
    expect(goalFrameCount('Ha', frames), 30);
    expect(goalFrameCount('L', frames), 3);
    expect(
      goalFrameCount('Luminance', frames),
      5,
      reason: 'no exact spelling: "L" and "lum" share the canonical name',
    );
    expect(goalFrameCount('OIII', frames), 0);
  });

  test('the unfiltered goal counts the frames that name no filter', () {
    expect(goalFrameCount('', const {'': 4, '  ': 1, 'L': 9}), 5);
  });
}
