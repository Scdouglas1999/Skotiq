import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart';
import 'package:skotiq_desktop/headless_api/handlers/plugin_handlers.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _TestPlugin extends SkotiqPlugin {
  int enableCalls = 0;
  int disableCalls = 0;

  @override
  String get id => 'com.skotiq.test.runtime';

  @override
  String get name => 'Runtime Plugin';

  @override
  String get version => '1.2.3';

  @override
  String get author => 'Skotiq';

  @override
  String get description => 'Compiled into the test host';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onEnable() async => enableCalls++;

  @override
  Future<void> onDisable() async => disableCalls++;

  @override
  Future<void> onUnload() async {}
}

class _FakeEnablementNotifier extends PluginEnablementNotifier {
  _FakeEnablementNotifier(this.initial);

  final Set<String> initial;

  @override
  Future<Set<String>> build() async => {...initial};

  @override
  Future<void> setEnabled(String pluginId, bool enabled) async {
    final host = ref.read(pluginHostProvider);
    await host.setPluginEnabled(pluginId, enabled);
    final next = {...?state.valueOrNull};
    if (enabled) {
      next.add(pluginId);
    } else {
      next.remove(pluginId);
    }
    state = AsyncData(next);
  }
}

List<int> _archive(Map<String, dynamic> manifest) =>
    utf8.encode(jsonEncode(manifest));

Future<Map<String, dynamic>> _body(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginHandlers', () {
    late ProviderContainer container;
    late Directory tempDir;
    late PluginHost host;
    late _TestPlugin plugin;
    late PluginHandlers handlers;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sk_plugin_handlers_');
      host = PluginHost();
      plugin = _TestPlugin();
      await host.registerPlugin(plugin);
      container = ProviderContainer(
        overrides: [
          pluginHostProvider.overrideWithValue(host),
          pluginEnablementProvider.overrideWith(
            () => _FakeEnablementNotifier({plugin.id}),
          ),
          pluginManagementServiceProvider.overrideWith((ref) {
            return PluginManagementService(
              logger: ref.read(loggingServiceProvider),
              directoryOverride: () async => tempDir,
            );
          }),
        ],
      );
      handlers = PluginHandlers(container);
    });

    tearDown(() async {
      container.dispose();
      await host.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('list reports the live bundled runtime and capabilities', () async {
      final response = await translateHandlerErrors(
        handlers.handleListPlugins(
          Request('GET', Uri.parse('http://localhost/api/plugins')),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      final body = await _body(response);
      expect(body['total'], 1);
      expect(body['capabilities'], {
        'runtimeUpload': false,
        'enableBundled': true,
        'removeArchivedUploads': true,
      });
      final item = (body['items'] as List).single as Map;
      expect(item['id'], plugin.id);
      expect(item['enabled'], isTrue);
      expect(item['source'], 'bundled');
      expect(item['runtimeLoaded'], isTrue);
      expect(item['canEnable'], isTrue);
    });

    test('disable and enable transition the actual PluginHost', () async {
      final disable = await handlers.handleDisablePlugin(
        Request('POST', Uri.parse('http://localhost/api/plugins/disable')),
        plugin.id,
      );
      expect(disable.statusCode, HttpStatus.ok);
      expect(host.isEnabled(plugin.id), isFalse);
      expect(plugin.disableCalls, 1);
      expect((await _body(disable))['status'], 'disabled');

      final enable = await handlers.handleEnablePlugin(
        Request('POST', Uri.parse('http://localhost/api/plugins/enable')),
        plugin.id,
      );
      expect(enable.statusCode, HttpStatus.ok);
      expect(host.isEnabled(plugin.id), isTrue);
      // One call during initial registration and one during re-enable.
      expect(plugin.enableCalls, 2);
      final enabledBody = await _body(enable);
      expect(enabledBody['status'], 'enabled');
      expect((enabledBody['manifest'] as Map)['runtimeLoaded'], isTrue);
    });

    test('upload fails honestly and stores no inert archive', () async {
      final response = await handlers.handleUploadPlugin(
        Request(
          'POST',
          Uri.parse(
            'http://localhost/api/plugins/upload?filename=sample.skplugin',
          ),
          body: _archive({
            'id': 'com.skotiq.sample',
            'name': 'Sample',
            'version': '1.0.0',
          }),
        ),
      );

      expect(response.statusCode, HttpStatus.notImplemented);
      final body = await _body(response);
      expect(body['error'], 'runtime_plugin_install_unavailable');
      expect(
        await container.read(pluginManagementServiceProvider).listPlugins(),
        isEmpty,
      );
    });

    test('legacy archives are visible but cannot be enabled', () async {
      await container
          .read(pluginManagementServiceProvider)
          .installFromBytes(
            _archive({
              'id': 'com.skotiq.legacy',
              'name': 'Legacy Upload',
              'version': '0.9.0',
            }),
            filename: 'legacy.skplugin',
          );

      final list = await handlers.handleListPlugins(
        Request('GET', Uri.parse('http://localhost/api/plugins')),
      );
      final listBody = await _body(list);
      final legacy = (listBody['items'] as List).cast<Map>().singleWhere(
        (item) => item['id'] == 'com.skotiq.legacy',
      );
      expect(legacy['enabled'], isFalse);
      expect(legacy['runtimeLoaded'], isFalse);
      expect(legacy['canEnable'], isFalse);
      expect(legacy['loadError'], contains('cannot load'));

      final enable = await handlers.handleEnablePlugin(
        Request('POST', Uri.parse('http://localhost/api/plugins/legacy')),
        'com.skotiq.legacy',
      );
      expect(enable.statusCode, HttpStatus.conflict);
      expect((await _body(enable))['error'], 'archived_plugin_not_runnable');
    });

    test('delete removes legacy archives but not bundled plugins', () async {
      await container
          .read(pluginManagementServiceProvider)
          .installFromBytes(
            _archive({
              'id': 'com.skotiq.legacy',
              'name': 'Legacy Upload',
              'version': '0.9.0',
            }),
            filename: 'legacy.skplugin',
          );

      final removed = await handlers.handleUninstallPlugin(
        Request('DELETE', Uri.parse('http://localhost/api/plugins/legacy')),
        'com.skotiq.legacy',
      );
      expect(removed.statusCode, HttpStatus.ok);
      expect((await _body(removed))['status'], 'archive_removed');
      expect(
        await container.read(pluginManagementServiceProvider).listPlugins(),
        isEmpty,
      );

      final bundled = await handlers.handleUninstallPlugin(
        Request('DELETE', Uri.parse('http://localhost/api/plugins/runtime')),
        plugin.id,
      );
      expect(bundled.statusCode, HttpStatus.conflict);
      expect(
        (await _body(bundled))['error'],
        'bundled_plugin_cannot_be_uninstalled',
      );
      expect(host.isLoaded(plugin.id), isTrue);
    });

    test('unknown plugin operations return 404', () async {
      final enable = await handlers.handleEnablePlugin(
        Request('POST', Uri.parse('http://localhost/api/plugins/missing')),
        'missing',
      );
      expect(enable.statusCode, HttpStatus.notFound);

      final remove = await handlers.handleUninstallPlugin(
        Request('DELETE', Uri.parse('http://localhost/api/plugins/missing')),
        'missing',
      );
      expect(remove.statusCode, HttpStatus.notFound);
    });
  });
}
