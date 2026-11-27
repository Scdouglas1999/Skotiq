import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_app/startup/plugin_enablement_wiring.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

class _StoragePlugin extends SkotiqPlugin {
  @override
  String get id => 'com.skotiq.test.storage-location';
  @override
  String get name => 'Storage location';
  @override
  String get version => '1.0.0';
  @override
  String get description => 'Writes one value.';
  @override
  String get author => 'test';
  @override
  Future<void> onLoad(PluginContext context) async {}
  @override
  Future<void> onUnload() async {}
}

void main() {
  late Directory dataRoot;

  setUp(() {
    dataRoot = Directory.systemTemp.createTempSync('plugin_storage_root_');
    debugResetSkotiqProcessEnvironment();
    captureSkotiqProcessEnvironment({skotiqDataDirEnv: dataRoot.path});
  });

  tearDown(() {
    debugResetSkotiqProcessEnvironment();
    if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
  });

  test('a relocated instance keeps plugin storage under its own data root',
      () async {
    final container = ProviderContainer(
      overrides: [pluginHostAppVersionOverride('9.4.0')],
    );
    addTearDown(container.dispose);
    final host = container.read(pluginHostProvider);
    final plugin = _StoragePlugin();
    await host.registerPlugin(plugin);

    await host.contextFor(plugin.id)!.storage.setString('token', 'abc');

    final file = File(
      p.join(dataRoot.path, 'skotiq_plugins', 'storage', '${plugin.id}.json'),
    );
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), contains('abc'));
  });
}
