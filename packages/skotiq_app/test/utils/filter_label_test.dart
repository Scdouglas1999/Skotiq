import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/filter_label.dart';

/// Frame captions used to fabricate 'L' (Luminance) for frames that carried no
/// filter at all, so an OSC/DSLR night — or any mono rig imaging without a
/// wheel — read as Luminance data that was never shot through a Luminance
/// filter.
void main() {
  test('a real filter name is shown verbatim', () {
    expect(filterLabel('Ha'), 'Ha');
    expect(filterLabel('OIII'), 'OIII');
  });

  test('an absent filter is marked, never invented as L', () {
    expect(filterLabel(null), kNoFilterLabel);
    expect(filterLabel(null), isNot('L'));
  });

  test('an empty or whitespace filter reads as absent, not as a blank gap', () {
    expect(filterLabel(''), kNoFilterLabel);
    expect(filterLabel('   '), kNoFilterLabel);
  });

  test('surrounding whitespace is trimmed off a real name', () {
    expect(filterLabel('  SII '), 'SII');
  });

  group('frameCaption', () {
    test('a light is captioned by its filter', () {
      expect(frameCaption(filter: 'Ha', frameType: 'light'), 'Ha');
      expect(frameCaption(filter: null, frameType: 'light'), kNoFilterLabel);
    });

    test('a calibration frame is captioned by what it is', () {
      expect(frameCaption(filter: 'L', frameType: 'dark'), 'Dark');
      expect(frameCaption(filter: 'L', frameType: 'bias'), 'Bias');
      expect(frameCaption(filter: 'L', frameType: 'darkflat'), 'Dark flat');
      expect(frameCaption(filter: 'Ha', frameType: 'flat'), 'Flat Ha');
      expect(frameCaption(filter: null, frameType: 'flat'), 'Flat');
    });
  });
}
