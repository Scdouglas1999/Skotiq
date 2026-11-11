import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  test('the Y-scale selector names the unit the axis is drawn in', () {
    expect(yScaleLabel(GraphYScale.two, '"'), '±2"');
    expect(yScaleLabel(GraphYScale.two, ' px'), '±2 px');
    expect(yScaleLabel(GraphYScale.one, ' px'), '±1 px');
  });
}
