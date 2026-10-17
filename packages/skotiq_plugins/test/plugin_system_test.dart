import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';

/// Integration test demonstrating the complete plugin lifecycle
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Plugin System Integration', () {
    late PluginHost host;

    setUp(() {
      host = PluginHost();
    });

    tearDown(() async {
      await host.dispose();
    });

    test('Example plugin loads and operates correctly', () async {
      final plugin = ExamplePlugin();

      // Register plugin
      await host.registerPlugin(plugin);

      // Verify plugin is loaded and enabled
      expect(host.isLoaded(plugin.id), isTrue);
      expect(host.isEnabled(plugin.id), isTrue);
      expect(host.plugins.length, equals(1));

      // Verify plugin info
      final info = host.pluginInfo.first;
      expect(info.id, equals('com.skotiq.example'));
      expect(info.name, equals('Example Plugin'));
      expect(info.version, equals('1.0.0'));
      expect(info.enabled, isTrue);
      expect(info.error, isNull);

      // Disable plugin
      final disabled = await host.setPluginEnabled(plugin.id, false);
      expect(disabled, isTrue);
      expect(host.isEnabled(plugin.id), isFalse);

      // Re-enable plugin
      final enabled = await host.setPluginEnabled(plugin.id, true);
      expect(enabled, isTrue);
      expect(host.isEnabled(plugin.id), isTrue);

      // Unregister plugin
      await host.unregisterPlugin(plugin.id);
      expect(host.isLoaded(plugin.id), isFalse);
      expect(host.plugins.length, equals(0));
    });

    test('Multiple plugins can coexist', () async {
      final plugin1 = ExamplePlugin();
      final plugin2 = ExampleSequencePlugin();

      await host.registerPlugin(plugin1);
      await host.registerPlugin(plugin2);

      expect(host.plugins.length, equals(2));
      expect(host.isLoaded(plugin1.id), isTrue);
      expect(host.isLoaded(plugin2.id), isTrue);

      final sequencePlugins = host.getPlugins<SequencePlugin>();
      expect(sequencePlugins.length, equals(1));
      expect(sequencePlugins.first.id, equals(plugin2.id));
    });

    test('Plugin duplicate registration throws exception', () async {
      final plugin = ExamplePlugin();

      await host.registerPlugin(plugin);

      // Try to register again
      expect(
        () => host.registerPlugin(plugin),
        throwsA(isA<PluginException>()),
      );
    });

    test('Plugin context provides working services', () async {
      final plugin = ExamplePlugin();
      await host.registerPlugin(plugin);

      // Test counter increment (uses storage)
      expect(plugin.counter, equals(0));
      await plugin.incrementCounter();
      expect(plugin.counter, equals(1));
      await plugin.incrementCounter();
      expect(plugin.counter, equals(2));

      // Test reset
      await plugin.resetCounter();
      expect(plugin.counter, equals(0));
    });

    test('Disabled plugin does not appear in typed queries', () async {
      final plugin = ExampleSequencePlugin();
      await host.registerPlugin(plugin);

      // Plugin is enabled, should appear
      var sequencePlugins = host.getPlugins<SequencePlugin>();
      expect(sequencePlugins.length, equals(1));

      // Disable plugin
      await host.setPluginEnabled(plugin.id, false);

      // Plugin is disabled, should not appear
      sequencePlugins = host.getPlugins<SequencePlugin>();
      expect(sequencePlugins.length, equals(0));
    });

    test('Plugin can be retrieved by ID', () async {
      final plugin = ExamplePlugin();
      await host.registerPlugin(plugin);

      final retrieved = host.getPlugin(plugin.id);
      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals(plugin.id));
      expect(retrieved, same(plugin));
    });

    test('successful lifecycle retry clears the prior error', () async {
      final plugin = _FailsFirstDisablePlugin();
      await host.registerPlugin(plugin);

      await expectLater(
        host.setPluginEnabled(plugin.id, false),
        throwsA(isA<PluginException>()),
      );
      expect(host.pluginInfo.single.error, isNotNull);
      expect(host.isEnabled(plugin.id), isTrue);

      expect(await host.setPluginEnabled(plugin.id, false), isTrue);
      expect(host.isEnabled(plugin.id), isFalse);
      expect(host.pluginInfo.single.error, isNull);
    });

    test('Dispose cleans up all plugins', () async {
      await host.registerPlugin(ExamplePlugin());
      await host.registerPlugin(ExampleSequencePlugin());

      expect(host.plugins.length, equals(2));

      await host.dispose();

      expect(host.plugins.length, equals(0));
    });
  });

  group('Plugin Context Services', () {
    test('Logger works correctly', () {
      final logger = ConsolePluginLogger('test.plugin');

      // Should not throw
      expect(() => logger.debug('Debug message'), returnsNormally);
      expect(() => logger.info('Info message'), returnsNormally);
      expect(() => logger.warning('Warning message'), returnsNormally);
      expect(() => logger.error('Error message'), returnsNormally);
      expect(
        () => logger.error('Error with exception', Exception('test')),
        returnsNormally,
      );
    });

    test('Storage persists values', () async {
      final storage = InMemoryPluginStorage();

      // String storage
      await storage.setString('key1', 'value1');
      final str = await storage.getString('key1');
      expect(str, equals('value1'));

      // Integer storage
      await storage.setInt('key2', 42);
      final num = await storage.getInt('key2');
      expect(num, equals(42));

      // Boolean storage
      await storage.setBool('key3', true);
      final bool = await storage.getBool('key3');
      expect(bool, isTrue);

      // Get all
      final all = await storage.getAll();
      expect(all.length, equals(3));
      expect(all['key1'], equals('value1'));
      expect(all['key2'], equals(42));
      expect(all['key3'], isTrue);

      // Remove
      await storage.remove('key1');
      final removed = await storage.getString('key1');
      expect(removed, isNull);

      // Clear
      await storage.clear();
      final allAfterClear = await storage.getAll();
      expect(allAfterClear.length, equals(0));
    });

    test('File storage survives new instances', () async {
      final tempRoot = await Directory.systemTemp.createTemp(
        'skotiq_plugins_test_',
      );
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      Future<Directory> baseDir() async => tempRoot;

      final first = FilePluginStorage(
        'com.skotiq.persistence-test',
        baseDirectoryProvider: baseDir,
      );
      await first.setString('greeting', 'hello');
      await first.setInt('count', 7);
      await first.setBool('enabled', true);

      final second = FilePluginStorage(
        'com.skotiq.persistence-test',
        baseDirectoryProvider: baseDir,
      );
      expect(await second.getString('greeting'), equals('hello'));
      expect(await second.getInt('count'), equals(7));
      expect(await second.getBool('enabled'), isTrue);
    });

    test(
      'concurrent storage instances merge mutations without lost keys',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp(
          'skotiq_plugin_storage_concurrent_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        Future<Directory> baseDir() async => tempRoot;
        final first = FilePluginStorage(
          'com.skotiq.concurrent-test',
          baseDirectoryProvider: baseDir,
        );
        final second = FilePluginStorage(
          'com.skotiq.concurrent-test',
          baseDirectoryProvider: baseDir,
        );

        await Future.wait([
          first.setString('first', 'one'),
          second.setString('second', 'two'),
        ]);

        expect(await first.getAll(), {'first': 'one', 'second': 'two'});
        expect(await second.getAll(), {'first': 'one', 'second': 'two'});
      },
    );

    test('unsafe plugin ids are rejected before storage is created', () {
      expect(
        () => FilePluginStorage('../outside'),
        throwsA(isA<PluginException>()),
      );
      expect(
        () => FilePluginStorage('com.example/escape'),
        throwsA(isA<PluginException>()),
      );
    });

    test('Sandboxed plugin event bus blocks global subscriptions', () async {
      final factory = PluginContextFactory();
      final context = factory.createContext('com.skotiq.sandbox-test');
      addTearDown(factory.dispose);

      expect(() => context.eventBus.onAny(), throwsA(isA<PluginException>()));
    });

    test('Event bus delivers events', () async {
      final eventBus = StreamPluginEventBus();
      final receivedEvents = <Map<String, dynamic>>[];

      // Subscribe to specific event
      final subscription = eventBus.on('test.event').listen((data) {
        receivedEvents.add(data);
      });

      // Emit events
      eventBus.emit('test.event', {'count': 1});
      eventBus.emit('test.event', {'count': 2});
      eventBus.emit('other.event', {'ignored': true});

      // Wait for async delivery
      await Future.delayed(Duration.zero);

      expect(receivedEvents.length, equals(2));
      expect(receivedEvents[0]['count'], equals(1));
      expect(receivedEvents[1]['count'], equals(2));

      await subscription.cancel();
      eventBus.dispose();
    });

    test('Event bus onAny receives all events', () async {
      final eventBus = StreamPluginEventBus();
      final receivedEvents = <PluginEvent>[];

      // Subscribe to all events
      final subscription = eventBus.onAny().listen((event) {
        receivedEvents.add(event);
      });

      // Emit different events
      eventBus.emit('event.one', {'data': 'first'});
      eventBus.emit('event.two', {'data': 'second'});

      // Wait for async delivery
      await Future.delayed(Duration.zero);

      expect(receivedEvents.length, equals(2));
      expect(receivedEvents[0].name, equals('event.one'));
      expect(receivedEvents[1].name, equals('event.two'));

      await subscription.cancel();
      eventBus.dispose();
    });
  });

  group('Plugin Types', () {
    test('SequencePlugin declares node definitions', () {
      final plugin = ExampleSequencePlugin();
      expect(plugin.nodeDefinitions, isNotEmpty);
      expect(plugin.nodeDefinitions.length, equals(2));

      final waitNode = plugin.nodeDefinitions
          .where((n) => n.id == 'example.wait')
          .first;
      expect(waitNode.name, equals('Custom Wait'));
      expect(waitNode.category, equals('Example'));
    });
  });

  group('Plugin sandboxing', () {
    test(
      'minimum app version is enforced before lifecycle callbacks',
      () async {
        final blocked = _MinVersionPlugin('2.7.0');
        final oldHost = PluginHost(appVersion: '2.6.9');
        addTearDown(oldHost.dispose);

        await oldHost.registerPlugin(blocked);

        expect(blocked.loadCalls, 0);
        expect(oldHost.isLoaded(blocked.id), isTrue);
        expect(oldHost.isEnabled(blocked.id), isFalse);
        expect(oldHost.pluginInfo.single.canEnable, isFalse);
        await expectLater(
          oldHost.setPluginEnabled(blocked.id, true),
          throwsA(isA<PluginException>()),
        );

        final allowed = _MinVersionPlugin('2.7.0');
        final currentHost = PluginHost(appVersion: 'v2.7.0+6');
        addTearDown(currentHost.dispose);
        await currentHost.registerPlugin(allowed);
        expect(allowed.loadCalls, 1);
        expect(currentHost.isEnabled(allowed.id), isTrue);
      },
    );

    test('Plugin onLoad timeout is enforced', () async {
      final host = PluginHost(
        lifecycleTimeout: const Duration(milliseconds: 50),
      );
      addTearDown(host.dispose);

      expect(
        () => host.registerPlugin(_HangingPlugin()),
        throwsA(isA<PluginException>()),
      );
    });
  });
}

class _HangingPlugin implements SkotiqPlugin {
  @override
  String get id => 'com.skotiq.hanging';

  @override
  String get name => 'Hanging Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Deliberately hangs during onLoad';

  @override
  String get author => 'test';

  @override
  String? get minAppVersion => null;

  @override
  Future<void> onDisable() async {}

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onLoad(PluginContext context) async {
    await Future<void>.delayed(const Duration(seconds: 10));
  }

  @override
  Future<void> onUnload() async {}
}

class _FailsFirstDisablePlugin implements SkotiqPlugin {
  bool _hasFailed = false;

  @override
  String get id => 'com.skotiq.fails-first-disable';

  @override
  String get name => 'Fails First Disable';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Fails the first disable attempt';

  @override
  String get author => 'test';

  @override
  String? get minAppVersion => null;

  @override
  Future<void> onDisable() async {
    if (!_hasFailed) {
      _hasFailed = true;
      throw StateError('first disable failed');
    }
  }

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onUnload() async {}
}

class _MinVersionPlugin implements SkotiqPlugin {
  _MinVersionPlugin(this.requiredVersion);

  final String requiredVersion;
  int loadCalls = 0;

  @override
  String get id => 'com.skotiq.min-version-$requiredVersion';

  @override
  String get name => 'Minimum Version';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Version gate test';

  @override
  String get author => 'test';

  @override
  String? get minAppVersion => requiredVersion;

  @override
  Future<void> onLoad(PluginContext context) async {
    loadCalls++;
  }

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<void> onUnload() async {}
}
