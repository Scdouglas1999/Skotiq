import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

void main() {
  test('only the Weather Logger starts off by default', () {
    expect(
      [
        for (final d in kUserFacingExamplePlugins)
          if (!d.enabledByDefault) d.id,
      ],
      ['com.skotiq.weatherlogger'],
    );
    expect(pluginEnabledByDefault('com.skotiq.weatherlogger'), isFalse);
    expect(pluginEnabledByDefault('com.example.not_bundled'), isTrue);
  });
}
