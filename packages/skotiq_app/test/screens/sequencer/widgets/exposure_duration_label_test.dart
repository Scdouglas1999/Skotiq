import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary.dart';

void main() {
  test('a lunar burst reads in milliseconds, not "0s"', () {
    expect(exposureDurationLabel(0.005), '5 ms');
    expect(exposureDurationLabel(0.05), '50 ms');
  });

  test('a tenth of a second and up reads in seconds', () {
    expect(exposureDurationLabel(0.1), '0.1s');
    expect(exposureDurationLabel(2.5), '2.5s');
    expect(exposureDurationLabel(300), '300s');
  });
}
