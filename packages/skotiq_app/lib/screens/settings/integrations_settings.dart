// Integrations settings page.
//
// Replaces the orphaned `plugins_screen.dart` with a design-system-compliant
// page that surfaces the four bundled integrations (Discord, Pushover, Home
// Assistant, Weather Logger) and cross-links to the notification router (the
// honest answer to "Discord fires on observatory events" — that path lives in
// Settings > Notification Routing).
//
// Wiring (built on the registration/enablement providers, never reaching into
// plugin internals):
//   * `pluginRegistrationProvider` — ensures the bundled plugins are
//     registered into the host before we render. Read (not just watched) so a
//     registration failure surfaces as an error state rather than an empty page.
//   * `pluginHostProvider.pluginInfo` — the per-plugin name/description/enabled/
//     error snapshot rendered as rows.
//   * `pluginEnablementProvider` — the persisted enabled-set; toggling a
//     row calls `setEnabled(id, value)`, which drives the live host
//     (`PluginHost.setPluginEnabled`, running onEnable/onDisable and
//     registering/unregistering the plugin's sequence nodes) BEFORE persisting
//     the choice, so the running session and the saved state never diverge —
//     not this session, and not after a restart (the settings-backed
//     enablement store the entry point installs replays the same choice into
//     the registration pipeline at next launch).
//   * `pluginLastFiredProvider` — "last fired <relative time>" per plugin.
//
// Per-plugin configuration is written through the plugin's own public API
// (`configureCredentials` / `configureConnection`) or, for Discord (whose
// real credential is a per-NODE webhook URL), through the live plugin
// `PluginContext.storage` so the value is available as a default + test target.
// Every failure surfaces via [ErrorDialog]; nothing is swallowed.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// http is a transitive dependency (via skotiq_plugins / skotiq_core).
// It is used only for the Discord test-send client-factory type, mirroring the
// plugin's own `http.Client Function()` seam.
// ignore: depend_on_referenced_packages
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_plugins/skotiq_plugins.dart';
// C3's registration provider is the single seam that loads the bundled
// plugins into the host. It is intentionally not surfaced through the package
// barrel (it is internal wiring), so — exactly like C4's enablement provider —
// we import it by path. The implementation_imports lint is suppressed because
// there is no barrel alternative for this app-layer wiring.
// ignore: implementation_imports
import 'package:skotiq_plugins/src/plugin_registration.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// C4 (plugin enablement persistence) lives in skotiq_core but is not
// surfaced through that package's barrel, so — like C4 itself imports C3 by
// path — we import the provider by path. The implementation_imports lint is
// suppressed deliberately; there is no barrel alternative.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/plugin_enablement_provider.dart'
    show pluginEnablementProvider;
import 'package:skotiq_core/skotiq_core.dart'
    show HostDataDispatch, backendProvider;

import 'settings_sections.dart';
import 'widgets/settings_widgets.dart';
import '../../router/app_routes.dart';

part 'integrations_settings/plugin_rows.dart';
part 'integrations_settings/plugin_enable_switch.dart';
part 'integrations_settings/pushover_config_dialog.dart';
part 'integrations_settings/home_assistant_config_dialog.dart';
part 'integrations_settings/discord_config_dialog.dart';

/// Plugin-storage key holding the Discord plugin's default / test webhook URL.
///
/// The Discord plugin's real credential is per-NODE (each sequence node carries
/// its own webhook). This single key is a convenience: a default URL the
/// "Test send" button targets and that node editors can pre-fill. It lives in
/// the plugin's own [PluginContext.storage] so it travels with the plugin's
/// other settings.
const String kDiscordDefaultWebhookStorageKey = 'discord.defaultWebhookUrl';

/// Stable plugin ids for the three configurable bundled integrations.
const String kDiscordPluginId = 'com.skotiq.examples.discord_webhook';
const String kPushoverPluginId = 'com.skotiq.examples.pushover';
const String kHomeAssistantPluginId = 'com.skotiq.examples.home_assistant';

/// Integrations / Plugins settings page.
///
/// Renders the notification-routing cross-link and the bundled-plugin list.
/// Construct the standard way; tests inject [testHttpClientFactory] so the
/// Discord "Test send" exercises the real node execute path against a mocked
/// HTTP client without hitting the network.
class IntegrationsSettings extends ConsumerWidget {
  const IntegrationsSettings({
    super.key,
    this.testHttpClientFactory,
  });

  /// Optional HTTP client factory used only by the Discord "Test send" path.
  /// Null in production (a real [http.Client] is used). Tests pass a factory
  /// returning a mock client so the test-send asserts success/failure handling
  /// without network access.
  final http.Client Function()? testHttpClientFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Plugin code and credentials live on the process that executes the
    // sequence. A thin client must not register/configure a second local host
    // and imply those changes affect the remote rig.
    if (ref.watch(backendProvider).remoteHost != null) {
      return const SettingsPage(
        title: 'Integrations',
        description:
            'Plugin integrations execute on the connected imaging host.',
        children: [
          SettingsSection(
            title: 'Imaging host',
            children: [
              SettingRow(
                icon: LucideIcons.server,
                title: 'Managed on the imaging host',
                subtitle: 'Open Skotiq on the rig to enable plugins and enter '
                    'their credentials. Local changes on this client would '
                    'not affect remote sequence execution.',
                trailing: Icon(LucideIcons.lock, size: 16),
                isLast: true,
                stackWhenNarrow: true,
              ),
            ],
          ),
        ],
      );
    }

    // Ensure the bundled plugins are registered before we read host state.
    // A registration failure must NOT silently render an empty list — surface
    // it as an error state.
    final registration = ref.watch(pluginRegistrationProvider);

    return registration.when(
      loading: () => const SettingsLoadingState(
        message: 'Loading integrations…',
      ),
      error: (error, _) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(pluginRegistrationProvider),
      ),
      data: (_) => _IntegrationsBody(
        testHttpClientFactory: testHttpClientFactory,
      ),
    );
  }
}

class _IntegrationsBody extends ConsumerWidget {
  const _IntegrationsBody({
    required this.testHttpClientFactory,
  });

  final http.Client Function()? testHttpClientFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pluginHost = ref.watch(pluginHostProvider);
    final plugins = pluginHost.pluginInfo;
    final enabledSet = ref.watch(pluginEnablementProvider);
    final lastFired = ref.watch(pluginLastFiredProvider);

    return SettingsPage(
      title: 'Integrations',
      description:
          'Connect Skotiq to outside services. Route observatory events to '
          'chat and push, and manage the bundled plugins that add sequence '
          'nodes for Discord, Pushover, and Home Assistant.',
      children: [
        const _NotificationCrossLinkSection(),
        _PluginsSection(
          plugins: plugins,
          enabledSet: enabledSet,
          lastFired: lastFired,
          testHttpClientFactory: testHttpClientFactory,
        ),
      ],
    );
  }
}
