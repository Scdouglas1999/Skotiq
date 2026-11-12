import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/startup_timeline.dart';

class _RecordingLogger extends LoggingService {
  final List<(String, Map<String, Object?>?)> infos = [];

  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) =>
      infos.add((message, fields));
}

void main() {
  test('the logged line carries every mark in order, in ms since main', () {
    final timeline = StartupTimeline();
    timeline.mark('main');
    timeline.mark('database');
    final logger = _RecordingLogger();

    timeline.log(logger, 'test', 'Start-up timeline');

    final (message, fields) = logger.infos.single;
    expect(message, 'Start-up timeline');
    expect(fields!.keys, ['mainAtEpochMs', 'main', 'database']);
    expect(fields['mainAtEpochMs'], timeline.mainAt.millisecondsSinceEpoch);
    expect(
      fields['database'] as int,
      greaterThanOrEqualTo(fields['main'] as int),
    );
  });
}
