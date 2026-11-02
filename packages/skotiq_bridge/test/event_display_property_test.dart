import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/src/event_display.dart';

void main() {
  test('autofocus progress reads as its point and HFR, without the crops', () {
    final value =
        '{"focus_range":{"max":25650,"min":25250},"hfr":4.5561,'
        '"point":5,"total_points":9,"star_count":499,'
        '"star_crops":[{"height":80,"pixels_base64":"${'A' * 5000}"}]}';
    expect(
      propertyChangeText('AutofocusProgress', value),
      'Autofocus point 5 of 9 · HFR 4.56',
    );
  });

  test('a long value is named, a short one printed', () {
    expect(propertyChangeText('Temperature', '-10.0'), 'Temperature=-10.0');
    expect(propertyChangeText('Blob', 'x' * 200), 'Blob changed');
  });
}
