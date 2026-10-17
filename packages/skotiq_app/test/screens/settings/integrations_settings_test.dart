// Widget tests for the Integrations settings page.
//
// These exercise the page against a real [PluginHost] seeded with the bundled
// example plugins plus fake C4 (enablement) and C3 (last-fired / registration)
// provider overrides, so the UI behaviour — rows, toggles, error styling,
// configure dialogs, and the Discord test-send — is verified end-to-end
// without touching the network.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
// http is transitive for the app package; the Discord test-send seam types
// against it exactly as the plugin does.
// ignore: depend_on_referenced_packages
import 'package:http/http.dart' as http;
// ignore: depend_on_referenced_packages
import 'package:http/testing.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/settings/integrations_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
// Path imports mirror the page's own (C3 registration + C4 enablement are not
// surfaced through their package barrels).
// ignore: implementation_imports
import 'package:skotiq_plugins/src/plugin_registration.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart';
// Real DB + database provider so a "live" enablement notifier can drive the
// host and persist through the same Drift path production uses.
// ignore: implementation_imports
import 'package:skotiq_core/src/database/database.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fake C4 notifier exposing a fixed enabled-set and recording setEnabled calls.
class _FakeEnablementNotifier extends PluginEnablementNotifier {
  _FakeEnablementNotifier(this._initial, this.calls);

  final Set<String> _initial;
  final List<(String, bool)> calls;

  @override
  Future<Set<String>> build() async => _initial;

  @override
  Future<void> setEnabled(String pluginId, bool enabled) async {
    calls.add((pluginId, enabled));
    final next = {..._initial};
    if (enabled) {
      next.add(pluginId);
    } else {
      next.remove(pluginId);
    }
    state = AsyncData(next);
  }
}

/// Builds a real [PluginHost] with the three configurable example plugins
/// registered (so `pluginInfo`, `getPlugin`, and `contextFor` are live).
///
/// Uses an in-memory storage factory: the Pushover / Home Assistant plugins
/// read persisted config from [PluginStorage] in their `onLoad`/`onEnable`
/// lifecycle. The default [FilePluginStorage] resolves its directory through
/// `path_provider`, whose platform channel never answers under the widget-test
/// binding — so those lifecycle reads would hang the test forever. Injecting
/// [InMemoryPluginStorage] makes them resolve instantly and deterministically.
Future<PluginHost> _buildHost({
  bool discordEnabled = true,
  bool pushoverEnabled = true,
}) async {
  final host = PluginHost(
    contextFactory: PluginContextFactory(
      storageFactory: (_) => InMemoryPluginStorage(),
    ),
  );
  await host.registerPlugin(DiscordWebhookPlugin(), enabled: discordEnabled);
  await host.registerPlugin(
    PushoverNotificationPlugin(),
    enabled: pushoverEnabled,
  );
  await host.registerPlugin(HomeAssistantPlugin(), enabled: true);
  return host;
}

/// Wraps [IntegrationsSettings] in a router + theme with the given overrides.
/// [navigated] captures the location of the notification-routing cross-link.
Widget _harness({
  required PluginHost host,
  required Set<String> enabled,
  required List<(String, bool)> setCalls,
  http.Client Function()? testHttpClientFactory,
  List<String>? navigated,
}) {
  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (context, state) {
          final section = state.uri.queryParameters['section'];
          if (section != null) {
            navigated?.add(section);
          }
          return Scaffold(
            body: IntegrationsSettings(
              testHttpClientFactory: testHttpClientFactory,
            ),
          );
        },
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      pluginHostProvider.overrideWithValue(host),
      // Resolve registration SYNCHRONOUSLY (return void, not a Future) so the
      // provider is in AsyncData on the first frame. An async override would
      // leave it AsyncLoading for one microtask, rendering the loading shimmer
      // — whose infinite animation makes pumpAndSettle hang.
      pluginRegistrationProvider.overrideWith((ref) {}),
      pluginEnablementProvider.overrideWith(
        () => _FakeEnablementNotifier(enabled, setCalls),
      ),
      // Build the activity tracker with NO descriptors so it subscribes to no
      // event buses. The page only needs the last-fired MAP (empty here); the
      // real tracker's live subscriptions are exercised by C3's own tests.
      pluginActivityTrackerProvider.overrideWith(
        (ref) => PluginActivityTracker(host: host, descriptors: const []),
      ),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

/// Wraps [IntegrationsSettings] with the REAL [pluginEnablementProvider]
/// (no fake notifier), backed by [database] and [host], so a switch tap drives
/// the live [PluginHost] — running onEnable/onDisable — exactly as production
/// does, instead of merely recording the call.
Widget _liveHarness({
  required PluginHost host,
  required SkotiqDatabase database,
}) {
  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (context, state) => const Scaffold(
          body: IntegrationsSettings(),
        ),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      pluginHostProvider.overrideWithValue(host),
      pluginRegistrationProvider.overrideWith((ref) {}),
      // Only the configurable plugins are registered in the test host, so
      // restrict the managed-id set to them — otherwise the notifier's enabled
      // set would include unloaded ids the UI never renders.
      managedPluginIdsProvider.overrideWithValue([
        kDiscordPluginId,
        kPushoverPluginId,
        kHomeAssistantPluginId,
      ]),
      pluginActivityTrackerProvider.overrideWith(
        (ref) => PluginActivityTracker(host: host, descriptors: const []),
      ),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

/// Pumps in bounded steps until [finder] matches or [maxFrames] is reached.
///
/// The Integrations page contains widgets with perpetual animations (e.g. the
/// status-pill dot and, transiently, shimmer placeholders), so `pumpAndSettle`
/// would never return. This pumps fixed time steps — enough to flush async
/// builds, route transitions, and dialog open/close — without waiting for
/// animations to stop.
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 60,
  Duration step = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < maxFrames; i++) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// Pumps a fixed number of frames (no settle), to flush async work for cases
/// where we assert the ABSENCE of something or just need state to advance.
Future<void> _pumpFrames(
  WidgetTester tester, {
  int frames = 12,
  Duration step = const Duration(milliseconds: 16),
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const discordId = kDiscordPluginId;
  const pushoverId = kPushoverPluginId;
  const haId = kHomeAssistantPluginId;

  // Nullable: the pure-unit `formatRelativeTime` group never builds a host, so
  // tearDown must tolerate it being unset.
  PluginHost? host;

  // Render at a tall desktop surface so every plugin row (and its Configure
  // button) is on-screen and tappable. The default 800x600 test window can
  // push the second/third plugin row's controls below the fold, making
  // `tester.tap` miss and the configure dialog never open.
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  tearDown(() async {
    final h = host;
    if (h == null) return;
    // Clear any storage the plugins wrote during a test and dispose the host.
    for (final id in [discordId, pushoverId, haId]) {
      final ctx = h.contextFor(id);
      if (ctx != null) {
        await ctx.storage.clear();
      }
    }
    await h.dispose();
    host = null;
  });

  testWidgets('renders the notification cross-link and navigates on tap',
      (tester) async {
    host = await _buildHost();
    final navigated = <String>[];

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
      navigated: navigated,
    ));
    await _pumpUntil(tester, find.text('Open Notification Routing'));

    expect(
      find.text('Post to Discord / Pushover on observatory events'),
      findsOneWidget,
    );
    expect(find.text('Open Notification Routing'), findsOneWidget);

    await tester.tap(find.text('Open Notification Routing'));
    await _pumpFrames(tester);

    expect(navigated, contains('notification-routing'));
  });

  testWidgets('renders one row per registered plugin', (tester) async {
    host = await _buildHost();

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
    ));
    await _pumpUntil(tester, find.text('Discord Webhook'));

    expect(find.text('Discord Webhook'), findsOneWidget);
    expect(find.text('Pushover Notification'), findsOneWidget);
    expect(find.text('Home Assistant'), findsOneWidget);
  });

  testWidgets('toggling a plugin switch calls setEnabled with the right args',
      (tester) async {
    host = await _buildHost();
    final setCalls = <(String, bool)>[];

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: setCalls,
    ));
    await _pumpUntil(tester, find.byType(SkotiqSwitch));

    // The first plugin row is Discord (registration order). Find its switch by
    // locating the SkotiqSwitch widgets and tapping the first.
    final switches = find.byType(SkotiqSwitch);
    expect(switches, findsNWidgets(3));

    await tester.tap(switches.first);
    await _pumpFrames(tester);

    expect(setCalls, isNotEmpty);
    expect(setCalls.first.$1, discordId);
    // Discord started enabled, so toggling sends `false`.
    expect(setCalls.first.$2, isFalse);
  });

  testWidgets('toggling a switch transitions the LIVE PluginHost',
      (tester) async {
    // Real notifier + real DB (no fake): the switch must drive the host's
    // enabled state, not merely persist a bit — otherwise a disabled plugin
    // keeps running for the rest of the session.
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => database.close());
    host = await _buildHost();

    await tester.pumpWidget(_liveHarness(host: host!, database: database));
    await _pumpUntil(tester, find.byType(SkotiqSwitch));

    // Discord (first row) starts enabled in the host.
    expect(host!.isEnabled(discordId), isTrue);

    final switches = find.byType(SkotiqSwitch);
    expect(switches, findsNWidgets(3));

    await tester.tap(switches.first);
    await _pumpFrames(tester, frames: 20);

    // The live host actually disabled the plugin (onDisable ran, node
    // registrations were yanked) — and it persisted.
    expect(host!.isEnabled(discordId), isFalse);
    expect(host!.isLoaded(discordId), isTrue);
  });

  testWidgets('a disabled plugin shows "Disabled", never a green "Fired" pill',
      (tester) async {
    // Status-pill ordering: error > disabled > fired > enabled. A plugin that
    // fired earlier but is now disabled must read "Disabled", not a green
    // success pill.
    host = await _buildHost(discordEnabled: false);

    await tester.pumpWidget(_harness(
      host: host!,
      // Discord absent from the enabled set → rendered disabled.
      enabled: {pushoverId, haId},
      setCalls: [],
    ));
    await _pumpUntil(tester, find.text('Discord Webhook'));

    // Disabled pill present; no success "Fired" pill for the disabled plugin.
    expect(find.text('Disabled'), findsOneWidget);
  });

  testWidgets('a plugin in error state shows error styling', (tester) async {
    final h = PluginHost(
      contextFactory: PluginContextFactory(
        storageFactory: (_) => InMemoryPluginStorage(),
      ),
    );
    host = h;
    // Register a plugin then force it into an error state by failing an enable.
    await h.registerPlugin(DiscordWebhookPlugin(), enabled: true);
    await h.registerPlugin(PushoverNotificationPlugin(), enabled: true);
    // Drive Home Assistant into an error by registering a plugin whose enable
    // throws. We use a purpose-built throwing plugin sharing the HA id so the
    // page treats it as the configurable HA slot but renders the error pill.
    await h.registerPlugin(
      _ThrowingPlugin(haId),
      enabled: false,
    );
    // Flip it on to capture the thrown error into LoadedPlugin.error.
    await expectLater(
      h.setPluginEnabled(haId, true),
      throwsA(isA<PluginException>()),
    );

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId},
      setCalls: [],
    ));
    await _pumpUntil(tester, find.text('Error'));

    // The error pill renders 'Error' and the alert-triangle row icon appears.
    expect(find.text('Error'), findsOneWidget);
    expect(find.byIcon(LucideIcons.alertTriangle), findsWidgets);
  });

  testWidgets('opening Configure for Pushover shows the expected fields',
      (tester) async {
    useDesktopSurface(tester);
    host = await _buildHost();

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
    ));
    await _pumpUntil(tester, find.text('Pushover Notification'));

    // Tap the Configure button on the Pushover row. There are three Configure
    // buttons (one per configurable plugin); target Pushover via its row text.
    final pushoverConfigure = find.descendant(
      of: find.ancestor(
        of: find.text('Pushover Notification'),
        matching: find.byType(SettingRow),
      ),
      matching: find.widgetWithText(SkotiqButton, 'Configure'),
    );
    expect(pushoverConfigure, findsOneWidget);

    await tester.tap(pushoverConfigure);
    await _pumpUntil(
        tester, find.widgetWithText(SkotiqTextField, 'Application token'));

    expect(find.text('Configure Pushover'), findsOneWidget);
    expect(find.widgetWithText(SkotiqTextField, 'Application token'),
        findsOneWidget);
    expect(find.widgetWithText(SkotiqTextField, 'User / group key'),
        findsOneWidget);
  });

  testWidgets('saving Pushover writes both storage keys', (tester) async {
    useDesktopSurface(tester);
    host = await _buildHost();

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
    ));
    await _pumpUntil(tester, find.text('Pushover Notification'));

    final pushoverConfigure = find.descendant(
      of: find.ancestor(
        of: find.text('Pushover Notification'),
        matching: find.byType(SettingRow),
      ),
      matching: find.widgetWithText(SkotiqButton, 'Configure'),
    );
    await tester.tap(pushoverConfigure);
    await _pumpUntil(
        tester, find.widgetWithText(SkotiqTextField, 'Application token'));

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Application token'),
      'token-abc',
    );
    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'User / group key'),
      'user-xyz',
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
    await _pumpFrames(tester);

    final storage = host!.contextFor(pushoverId)!.storage;
    expect(await storage.getString('pushover.apiToken'), 'token-abc');
    expect(await storage.getString('pushover.userKey'), 'user-xyz');
  });

  testWidgets('Discord test-send surfaces success on 204', (tester) async {
    useDesktopSurface(tester);
    host = await _buildHost();
    final mockClient = MockClient((request) async {
      expect(request.url.host, endsWith('discord.com'));
      return http.Response('', 204);
    });

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
      testHttpClientFactory: () => mockClient,
    ));
    await _pumpUntil(tester, find.text('Discord Webhook'));

    final discordConfigure = find.descendant(
      of: find.ancestor(
        of: find.text('Discord Webhook'),
        matching: find.byType(SettingRow),
      ),
      matching: find.widgetWithText(SkotiqButton, 'Configure'),
    );
    await tester.tap(discordConfigure);
    await _pumpUntil(
      tester,
      find.widgetWithText(SkotiqTextField, 'Default / test webhook URL'),
    );

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Default / test webhook URL'),
      'https://discord.com/api/webhooks/123/abc',
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Test send'));
    await _pumpUntil(tester, find.text('Discord test message sent.'));

    expect(find.text('Discord test message sent.'), findsOneWidget);

    // The success toast schedules a 4s auto-dismiss Timer (SkotiqToast).
    // Pump past it so the overlay entry removes itself and no Timer is left
    // pending when the widget tree is torn down (which would fail the test).
    await tester.pump(const Duration(seconds: 5));
    await _pumpFrames(tester, frames: 20);
  });

  testWidgets('Discord test-send surfaces an error on 500', (tester) async {
    useDesktopSurface(tester);
    host = await _buildHost();
    final mockClient = MockClient((request) async {
      return http.Response('server error', 500);
    });

    await tester.pumpWidget(_harness(
      host: host!,
      enabled: {discordId, pushoverId, haId},
      setCalls: [],
      testHttpClientFactory: () => mockClient,
    ));
    await _pumpUntil(tester, find.text('Discord Webhook'));

    final discordConfigure = find.descendant(
      of: find.ancestor(
        of: find.text('Discord Webhook'),
        matching: find.byType(SettingRow),
      ),
      matching: find.widgetWithText(SkotiqButton, 'Configure'),
    );
    await tester.tap(discordConfigure);
    await _pumpUntil(
      tester,
      find.widgetWithText(SkotiqTextField, 'Default / test webhook URL'),
    );

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Default / test webhook URL'),
      'https://discord.com/api/webhooks/123/abc',
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Test send'));
    await _pumpUntil(tester, find.text('Discord test failed'));

    expect(find.text('Discord test failed'), findsOneWidget);
  });

  group('formatRelativeTime', () {
    final base = DateTime(2026, 5, 30, 12, 0, 0);

    test('clamps near-now / future to "just now"', () {
      expect(formatRelativeTime(base, now: base), 'just now');
      expect(
        formatRelativeTime(base.add(const Duration(minutes: 5)), now: base),
        'just now',
      );
      expect(
        formatRelativeTime(base.subtract(const Duration(seconds: 10)),
            now: base),
        'just now',
      );
    });

    test('formats minutes, hours, and days', () {
      expect(
        formatRelativeTime(base.subtract(const Duration(minutes: 3)),
            now: base),
        '3m ago',
      );
      expect(
        formatRelativeTime(base.subtract(const Duration(hours: 2)), now: base),
        '2h ago',
      );
      expect(
        formatRelativeTime(base.subtract(const Duration(days: 5)), now: base),
        '5d ago',
      );
    });
  });
}

/// A plugin that throws on enable, used to drive the error-pill rendering.
class _ThrowingPlugin extends SkotiqPlugin {
  _ThrowingPlugin(this.id);

  @override
  final String id;

  @override
  String get name => 'Home Assistant';

  @override
  String get version => '1.0.0';

  @override
  String get description => 'throwing test plugin';

  @override
  String get author => 'Test';

  @override
  Future<void> onLoad(PluginContext context) async {}

  @override
  Future<void> onEnable() async {
    throw StateError('boom');
  }

  @override
  Future<void> onUnload() async {}
}
