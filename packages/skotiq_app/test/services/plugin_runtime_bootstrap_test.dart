import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/plugin_node_palette_wiring.dart';
import 'package:skotiq_app/services/plugin_runtime_bootstrap.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup bootstrap registers bundled nodes without opening settings',
      () async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        pluginNodePaletteBlueprintsOverride()
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(pluginHostProvider).pluginInfo, isEmpty);

    await initializeBundledPluginRuntime(container);
    await Future<void>.delayed(Duration.zero);

    final pluginIds = container
        .read(pluginHostProvider)
        .pluginInfo
        .map((plugin) => plugin.id)
        .toSet();
    expect(pluginIds, {
      'com.skotiq.examples.discord_webhook',
      'com.skotiq.examples.pushover',
      'com.skotiq.examples.home_assistant',
      'com.skotiq.weatherlogger',
    });

    final nodeKeys = container
        .read(pluginNodeBlueprintsProvider)
        .map((node) => node.registrationKey)
        .toSet();
    expect(nodeKeys, isNotEmpty);
    expect(
      nodeKeys,
      contains(
        'com.skotiq.examples.home_assistant::home_assistant.toggle',
      ),
    );
  });
}
