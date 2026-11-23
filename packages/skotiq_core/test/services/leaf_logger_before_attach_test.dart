import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart' as logging;
import 'package:skotiq_core/utils.dart';

import '../harness/captured_log.dart';

/// Every `main` calls [Log.listen] before its first start-up step. The mobile
/// app opens its catalogs before any logging service exists, and a catalog
/// that cannot be read says so through a leaf logger: that record must still
/// reach `dart:developer` (logcat), and once a service attaches, later
/// records go to the app log instead.
///
/// The forwarder is a process-wide subscription, so this file holds only the
/// before-attach case.
void main() {
  test('a leaf record logged before any service attaches is kept', () async {
    final unattached = <(LogLevel, String, String)>[];
    Log.unattachedSinkForTest =
        (level, message, {required source, error, stackTrace}) =>
            unattached.add((level, source, message));
    addTearDown(() => Log.unattachedSinkForTest = null);

    Log.listen();
    logging.Logger('skotiq.CatalogManager').severe('Nebula table unreadable');

    expect(unattached, [
      (LogLevel.error, 'CatalogManager', 'Nebula table unreadable'),
    ]);

    final service = await captureAppLog();
    logging.Logger('skotiq.CatalogManager').info('Catalogs ready');

    expect(logFrom(service, 'CatalogManager').map((e) => e.message), [
      'Catalogs ready',
    ]);
    expect(unattached, hasLength(1));
  });
}
