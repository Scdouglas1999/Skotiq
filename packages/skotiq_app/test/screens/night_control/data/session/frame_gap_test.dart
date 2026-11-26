// The HFR · stars line breaks across hours without frames instead of drawing
// a straight line over them; an autofocus run or a flip does not break it.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';

void main() {
  final start = DateTime.utc(2026, 11, 26, 20);
  List<DateTime> every(Duration step, int count, {DateTime? from}) => [
        for (var i = 0; i < count; i++) (from ?? start).add(step * i),
      ];

  test('two-minute frames break after twenty minutes', () {
    expect(
      nightFrameGap(every(const Duration(minutes: 2), 10)),
      const Duration(minutes: 20),
    );
  });

  test('ten-minute frames break after four of their own intervals', () {
    expect(
      nightFrameGap(every(const Duration(minutes: 10), 10)),
      const Duration(minutes: 40),
    );
  });

  test('a long gap does not raise the threshold past it', () {
    final times = [
      ...every(const Duration(minutes: 1), 20),
      ...every(
        const Duration(minutes: 1),
        20,
        from: start.add(const Duration(hours: 10)),
      ),
    ];
    expect(nightFrameGap(times), const Duration(minutes: 20));
  });
}
