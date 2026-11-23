import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart' as logging;
import 'package:skotiq_core/utils.dart';

import '../harness/captured_log.dart';

/// The leaf packages cannot import [Log]; they log through `package:logging`,
/// and the app log must receive those records once, at the same level.
void main() {
  test('a leaf record reaches the app log once, with its source', () async {
    final service = await captureAppLog();

    logging.Logger('skotiq.UpdateService').warning('Manifest fetch failed');

    final entries = logFrom(service, 'UpdateService');
    expect(entries, hasLength(1));
    expect(entries.single.level, LogLevel.warning);
    expect(entries.single.message, 'Manifest fetch failed');
  });

  test('attaching a second service does not forward a record twice', () async {
    await captureAppLog();
    final second = await captureAppLog();

    logging.Logger('skotiq.LanPushReceiver').info('Listening on 8765');

    expect(logFrom(second, 'LanPushReceiver'), hasLength(1));
  });

  test('levels keep their dart:developer meaning', () async {
    final service = await captureAppLog();
    final leaf = logging.Logger('skotiq.EnhancedDiscovery');

    leaf.fine('fine');
    leaf.info('info');
    leaf.warning('warning');
    leaf.severe('severe');
    leaf.shout('shout');

    expect(logFrom(service, 'EnhancedDiscovery').map((e) => e.level).toList(), [
      LogLevel.debug,
      LogLevel.info,
      LogLevel.warning,
      LogLevel.error,
      LogLevel.critical,
    ]);
  });

  test('the error and stack of a leaf record are kept', () async {
    final service = await captureAppLog();

    logging.Logger(
      'skotiq.UpdateService',
    ).severe('Download failed', StateError('link dropped'), StackTrace.current);

    final entry = logFrom(service, 'UpdateService').single;
    expect(entry.message, 'Download failed: Bad state: link dropped');
    expect(
      entry.fields['stackTrace'],
      contains('leaf_logger_forwarding_test.dart'),
    );
  });

  test('records from other package:logging users stay out', () async {
    final service = await captureAppLog();

    logging.Logger('GoRouter').info('going to /settings');

    expect(
      service.getRecentLogs().where((e) => e.message.contains('/settings')),
      isEmpty,
    );
  });
}
