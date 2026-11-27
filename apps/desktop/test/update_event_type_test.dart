// The updater cannot import core, so both name the found-update event; the
// updater emits it and core's notification router pushes it to phones.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart' show kUpdateAvailableEventType;
import 'package:skotiq_updater/skotiq_updater.dart' show UpdateAvailableEvent;

void main() {
  test('the updater and the notification router name the same event', () {
    const event = UpdateAvailableEvent(
      currentVersion: '9.4.0',
      latestVersion: '9.4.1',
    );
    expect(event.type, kUpdateAvailableEventType);
  });
}
