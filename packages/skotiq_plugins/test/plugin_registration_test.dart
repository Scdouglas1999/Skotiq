import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
import 'package:skotiq_plugins/src/plugin_registration.dart';

/// A minimal [SequencePlugin] that captures its context and can emit an
/// arbitrary event through the host event bus on demand, so tests can drive
/// [PluginActivityTracker] without standing up a real HTTP integration.
class _FakeSequencePlugin extends SequencePlugin {
  _FakeSequencePlugin({required this.id, this.onEnableCalls});

  @override
  final String id;

  /// Counter incremented each time [onEnable] runs, so tests can assert a
  /// disabled plugin never enables.
  final List<String>? onEnableCalls;

  PluginContext? _context;

  @override
  String get name => 'Fake Sequence Plugin';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'Test-only sequence plugin';

  @override
  String get author => 'Test';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
  }

  @override
  Future<void> onEnable() async {
    onEnableCalls?.add(id);
  }

  @override
  Future<void> onUnload() async {
    _context = null;
  }

  @override
  List<SequenceNodeDefinition> get nodeDefinitions => const [];

  /// Emit [event] through the plugin's own (sandboxed) event bus — the same
  /// path the real Discord/Pushover plugins use on a successful send.
  void fire(String event) {
    final context = _context;
    if (context == null) {
      throw StateError('Plugin not loaded; cannot fire $event');
    }
    context.eventBus.emit(event, const {'ok': true});
  }
}

/// Enablement store driven by an explicit disabled-set, for asserting that
/// registration honours per-plugin enable/disable.
class _FakeEnablementStore implements PluginEnablementStore {
  _FakeEnablementStore({this.disabled = const {}});

  final Set<String> disabled;

  @override
  Future<bool> isEnabled(String pluginId) async => !disabled.contains(pluginId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginActivityTracker', () {
    late PluginHost host;

    setUp(() {
      host = PluginHost();
    });

    tearDown(() async {
      await host.dispose();
    });

    test('records last-fired when the plugin emits its sent-event', () async {
      const pluginId = 'com.test.fake_sent';
      const sentEvent = 'plugin.fake.sent';
      final plugin = _FakeSequencePlugin(id: pluginId);
      await host.registerPlugin(plugin);

      var fakeNow = DateTime.utc(2026, 1, 1, 0, 0, 0);
      final tracker = PluginActivityTracker(
        host: host,
        descriptors: const [
          ExamplePluginDescriptor(
            id: pluginId,
            // create is unused by the tracker; provide a stub anyway.
            create: _unusedCreate,
            firedEvent: sentEvent,
          ),
        ],
        now: () => fakeNow,
      );
      addTearDown(tracker.dispose);

      // Nothing fired yet.
      expect(tracker.snapshot, isEmpty);

      // Drive the event bus and wait for the broadcast subscription to deliver.
      final changed = tracker.changes.first;
      plugin.fire(sentEvent);
      await changed;

      expect(tracker.snapshot[pluginId], equals(fakeNow));

      // A second fire updates the timestamp.
      fakeNow = DateTime.utc(2026, 1, 1, 0, 5, 0);
      final changedAgain = tracker.changes.first;
      plugin.fire(sentEvent);
      await changedAgain;

      expect(tracker.snapshot[pluginId], equals(fakeNow));
    });

    test('throws when a tracked plugin has no registered context', () {
      expect(
        () => PluginActivityTracker(
          host: host,
          descriptors: const [
            ExamplePluginDescriptor(
              id: 'com.test.never_registered',
              create: _unusedCreate,
              firedEvent: 'plugin.fake.sent',
            ),
          ],
        ),
        throwsA(isA<PluginException>()),
      );
    });

    test('ignores plugins with no fired-event', () async {
      const pluginId = 'com.test.no_event';
      final plugin = _FakeSequencePlugin(id: pluginId);
      await host.registerPlugin(plugin);

      final tracker = PluginActivityTracker(
        host: host,
        descriptors: const [
          ExamplePluginDescriptor(
            id: pluginId,
            create: _unusedCreate,
            firedEvent: null,
          ),
        ],
      );
      addTearDown(tracker.dispose);

      expect(tracker.snapshot, isEmpty);
    });

    test(
      'stops recording after dispose (no update from late events)',
      () async {
        const pluginId = 'com.test.dispose';
        const sentEvent = 'plugin.fake.sent';
        final plugin = _FakeSequencePlugin(id: pluginId);
        await host.registerPlugin(plugin);

        final tracker = PluginActivityTracker(
          host: host,
          descriptors: const [
            ExamplePluginDescriptor(
              id: pluginId,
              create: _unusedCreate,
              firedEvent: sentEvent,
            ),
          ],
        );

        await tracker.dispose();

        // Firing after dispose must not mutate the (now-final) snapshot.
        plugin.fire(sentEvent);
        // Give any in-flight microtasks a chance to run.
        await Future<void>.delayed(Duration.zero);
        expect(tracker.snapshot, isEmpty);
      },
    );
  });

  group('pluginLastFiredProvider', () {
    test('updates from the event bus through the notifier', () async {
      final host = PluginHost();
      const pluginId = 'com.skotiq.examples.discord_webhook';
      const sentEvent = 'plugin.discord.sent';

      // Register a fake under the real Discord id so the default descriptor
      // (Discord -> plugin.discord.sent) routes the event to the notifier.
      final plugin = _FakeSequencePlugin(id: pluginId);
      await host.registerPlugin(plugin);

      final container = ProviderContainer(
        overrides: [
          pluginHostProvider.overrideWithValue(host),
          // Registration provider would try to register the *real* Discord
          // plugin (already present under this id) — isLoaded short-circuits
          // it, so registration resolves cleanly without double-registering.
        ],
      );
      addTearDown(container.dispose);
      addTearDown(host.dispose);

      // Drive registration to completion (idempotent: the id is already
      // loaded, so it is skipped rather than re-registered).
      await container.read(pluginRegistrationProvider.future);

      // Materialize the notifier.
      expect(container.read(pluginLastFiredProvider), isEmpty);

      final sub = container.listen(pluginLastFiredProvider, (_, __) {});
      addTearDown(sub.close);

      plugin.fire(sentEvent);
      // The event bus and the notifier each hop through a broadcast stream.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(pluginLastFiredProvider).containsKey(pluginId),
        isTrue,
      );
    });
  });

  group('pluginRegistrationProvider', () {
    test('registers exactly the four example plugins', () async {
      final host = PluginHost();
      final container = ProviderContainer(
        overrides: [pluginHostProvider.overrideWithValue(host)],
      );
      addTearDown(container.dispose);
      addTearDown(host.dispose);

      await container.read(pluginRegistrationProvider.future);

      final ids = host.pluginInfo.map((p) => p.id).toSet();
      expect(ids, {
        'com.skotiq.examples.discord_webhook',
        'com.skotiq.examples.pushover',
        'com.skotiq.examples.home_assistant',
        'com.skotiq.weatherlogger',
      });
      expect(host.pluginInfo.length, 4);
    });

    test(
      'honours an injected disabled-set (registers disabled, no onEnable)',
      () async {
        final host = PluginHost();
        final container = ProviderContainer(
          overrides: [
            pluginHostProvider.overrideWithValue(host),
            pluginEnablementStoreProvider.overrideWithValue(
              _FakeEnablementStore(disabled: {'com.skotiq.examples.pushover'}),
            ),
          ],
        );
        addTearDown(container.dispose);
        addTearDown(host.dispose);

        await container.read(pluginRegistrationProvider.future);

        // Disabled plugin is loaded but not enabled.
        expect(host.isLoaded('com.skotiq.examples.pushover'), isTrue);
        expect(host.isEnabled('com.skotiq.examples.pushover'), isFalse);

        // Others remain enabled.
        expect(host.isEnabled('com.skotiq.examples.discord_webhook'), isTrue);
        expect(host.isEnabled('com.skotiq.examples.home_assistant'), isTrue);
        expect(host.isEnabled('com.skotiq.weatherlogger'), isTrue);
      },
    );

    test('disabled plugin does not run onEnable', () async {
      // Use a fresh host with a fake plugin substituted via custom descriptor
      // wiring is not possible through the provider (it uses the canonical
      // list), so we verify onEnable suppression directly on the host, which
      // is the mechanism the registration provider relies upon.
      final host = PluginHost();
      addTearDown(() async => host.dispose());

      final onEnableCalls = <String>[];
      final plugin = _FakeSequencePlugin(
        id: 'com.test.disabled_onenable',
        onEnableCalls: onEnableCalls,
      );

      await host.registerPlugin(plugin, enabled: false);

      expect(host.isLoaded(plugin.id), isTrue);
      expect(host.isEnabled(plugin.id), isFalse);
      expect(onEnableCalls, isEmpty);
    });

    test(
      'is idempotent — safe to re-read without double-registering',
      () async {
        final host = PluginHost();
        final container = ProviderContainer(
          overrides: [pluginHostProvider.overrideWithValue(host)],
        );
        addTearDown(container.dispose);
        addTearDown(host.dispose);

        await container.read(pluginRegistrationProvider.future);
        // Invalidate and re-read: the already-registered ids are skipped, so
        // this must not throw the "already registered" PluginException.
        container.invalidate(pluginRegistrationProvider);
        await container.read(pluginRegistrationProvider.future);

        expect(host.pluginInfo.length, 4);
      },
    );

    test(
      'retry rebuilds a failed registration and attempts later plugins',
      () async {
        final host = PluginHost();
        addTearDown(host.dispose);
        var firstAttempts = 0;
        final descriptors = [
          ExamplePluginDescriptor(
            id: 'com.test.retry',
            create: () => _RegistrationPlugin(
              id: 'com.test.retry',
              onLoad: () async {
                firstAttempts++;
                if (firstAttempts == 1) throw StateError('first load failed');
              },
            ),
            firedEvent: null,
          ),
          ExamplePluginDescriptor(
            id: 'com.test.after-failure',
            create: () => _RegistrationPlugin(id: 'com.test.after-failure'),
            firedEvent: null,
          ),
        ];

        await expectLater(
          registerPluginDescriptors(
            host: host,
            store: const AllEnabledPluginEnablementStore(),
            descriptors: descriptors,
          ),
          throwsA(isA<PluginException>()),
        );
        expect(host.registrationFailed('com.test.retry'), isTrue);
        expect(
          host.isEnabled('com.test.after-failure'),
          isTrue,
          reason: 'one failure must not suppress later plugins',
        );

        await registerPluginDescriptors(
          host: host,
          store: const AllEnabledPluginEnablementStore(),
          descriptors: descriptors,
        );

        expect(firstAttempts, 2);
        expect(host.registrationFailed('com.test.retry'), isFalse);
        expect(host.isEnabled('com.test.retry'), isTrue);
        expect(host.pluginError('com.test.retry'), isNull);
      },
    );

    test('default enablement store enables every plugin', () async {
      const store = AllEnabledPluginEnablementStore();
      for (final descriptor in kUserFacingExamplePlugins) {
        expect(await store.isEnabled(descriptor.id), isTrue);
      }
    });
  });
}

class _RegistrationPlugin implements SkotiqPlugin {
  _RegistrationPlugin({required this.id, Future<void> Function()? onLoad})
    : _onLoad = onLoad;

  @override
  final String id;
  final Future<void> Function()? _onLoad;

  @override
  String get name => id;
  @override
  String get version => '1.0.0';
  @override
  String get description => 'registration test';
  @override
  String get author => 'test';
  @override
  String? get minAppVersion => null;

  @override
  Future<void> onLoad(PluginContext context) async {
    await _onLoad?.call();
  }

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<void> onUnload() async {}
}

/// Stub factory for descriptors used only by the tracker (which never calls
/// `create`). Throwing here would catch any accidental use.
SkotiqPlugin _unusedCreate() =>
    throw StateError('create() should not be called in tracker-only tests');
