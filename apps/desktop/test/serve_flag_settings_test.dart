// `--serve` wrote web_server_enabled=true to the settings store, so every
// later plain launch exposed the LAN server (qa-pair QP-01). It now turns the
// server on for the run only.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/desktop_app_bootstrap.dart';

void main() {
  test('--serve turns the server on for the run', () {
    const stored = AppSettingsState(webServerEnabled: false);
    final applied = effectiveRemoteAccessSettings(stored, forceServe: true);
    expect(applied.webServerEnabled, isTrue);
    expect(stored.webServerEnabled, isFalse);
  });

  test('a plain launch applies the stored setting', () {
    const stored = AppSettingsState(webServerEnabled: false);
    expect(
      effectiveRemoteAccessSettings(stored, forceServe: false).webServerEnabled,
      isFalse,
    );
  });
}
