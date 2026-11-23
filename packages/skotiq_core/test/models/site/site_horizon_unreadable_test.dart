import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/site/site_horizon_profile.dart';
import 'package:skotiq_core/src/utils/logging_service.dart';

void main() {
  test('an unreadable stored horizon is reported once, and read for what it '
      'holds', () {
    final logging = LoggingService();
    Log.attach(logging);
    addTearDown(() => Log.detach(logging));

    const stored = '{"N": 12, "E": 20, "samples": [[0, 5], [90'; // cut short
    final first = SiteHorizonProfile.fromJson(stored);
    SiteHorizonProfile.fromJson(stored);

    expect(first.altitudeAt('N'), 12);
    expect(first.altitudeAt('E'), 20);
    final reports = logging
        .getRecentLogs(minLevel: LogLevel.warning)
        .where((e) => e.message.contains('site horizon'))
        .toList();
    expect(reports, hasLength(1));
    expect(reports.single.message, contains('compass values'));
  });
}
