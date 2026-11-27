import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('a light reads as its filter, a calibration frame as what it is', () {
    expect(FrameType.light.caption('Ha'), 'Ha');
    expect(FrameType.light.caption('  Ha '), 'Ha');
    expect(FrameType.snapshot.caption('G'), 'G');
    expect(FrameType.dark.caption('G'), 'Dark');
    expect(FrameType.bias.caption('G'), 'Bias');
    expect(FrameType.darkFlat.caption('G'), 'Dark flat');
    expect(FrameType.flat.caption('Ha'), 'Flat Ha');
    expect(FrameType.flat.caption(null), 'Flat');
  });

  test('a light with no filter has no caption, never an invented one', () {
    expect(FrameType.light.caption(null), isNull);
    expect(FrameType.light.caption('  '), isNull);
  });

  test('a stored record is read once through FrameType', () {
    expect(FrameType.captionOfRecord('dark', 'G'), 'Dark');
    expect(FrameType.captionOfRecord('DarkFlat', 'G'), 'Dark flat');
    expect(FrameType.captionOfRecord('flat', 'OIII'), 'Flat OIII');
    expect(FrameType.captionOfRecord('mystery', 'R'), 'R');
  });
}
