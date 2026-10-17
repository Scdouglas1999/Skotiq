part of '../integrations_settings.dart';

/// Top section: the honest "Discord fires on events" answer — a cross-link to
/// the notification router, which owns the event→transport routing.
class _NotificationCrossLinkSection extends StatelessWidget {
  const _NotificationCrossLinkSection({required this.isMobile});

  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: 'Notifications & events',
      isMobile: isMobile,
      children: [
        SettingRow(
          icon: LucideIcons.bellRing,
          title: 'Post to Discord / Pushover on observatory events',
          subtitle:
              'Route sequence-complete, safety, and guiding-lost alerts to '
              'Discord, Pushover, email…',
          isMobile: isMobile,
          isLast: true,
          stackOnMobile: true,
          trailing: SkotiqButton(
            label: 'Open Notification Routing',
            icon: LucideIcons.arrowUpRight,
            variant: ButtonVariant.secondary,
            size: isMobile ? ButtonSize.small : ButtonSize.medium,
            onPressed: () =>
                context.go('/settings?section=notification-routing'),
          ),
        ),
      ],
    );
  }
}

/// The bundled-plugin list section.
class _PluginsSection extends ConsumerWidget {
  const _PluginsSection({
    required this.isMobile,
    required this.plugins,
    required this.enabledSet,
    required this.lastFired,
    required this.testHttpClientFactory,
  });

  final bool isMobile;
  final List<PluginInfo> plugins;
  final AsyncValue<Set<String>> enabledSet;
  final PluginLastFired lastFired;
  final http.Client Function()? testHttpClientFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (plugins.isEmpty) {
      return EmptyState(
        icon: LucideIcons.puzzle,
        title: 'No plugins loaded',
        body: 'Bundled integrations register at startup. If this list is '
            'empty, the plugin host failed to initialize.',
        action: SkotiqButton(
          label: 'Retry',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => ref.invalidate(pluginRegistrationProvider),
        ),
      );
    }

    return SettingsSection(
      title: 'Plugins',
      isMobile: isMobile,
      children: [
        for (var i = 0; i < plugins.length; i++)
          _PluginRow(
            plugin: plugins[i],
            isMobile: isMobile,
            isLast: i == plugins.length - 1,
            enabledSet: enabledSet,
            lastFiredAt: lastFired[plugins[i].id],
            testHttpClientFactory: testHttpClientFactory,
          ),
      ],
    );
  }
}

/// Whether [pluginId] has a configuration dialog.
bool _pluginIsConfigurable(String pluginId) {
  return pluginId == kDiscordPluginId ||
      pluginId == kPushoverPluginId ||
      pluginId == kHomeAssistantPluginId;
}

class _PluginRow extends ConsumerWidget {
  const _PluginRow({
    required this.plugin,
    required this.isMobile,
    required this.isLast,
    required this.enabledSet,
    required this.lastFiredAt,
    required this.testHttpClientFactory,
  });

  final PluginInfo plugin;
  final bool isMobile;
  final bool isLast;
  final AsyncValue<Set<String>> enabledSet;
  final DateTime? lastFiredAt;
  final http.Client Function()? testHttpClientFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final hasError = plugin.error != null;

    // The enabled-set is the authoritative persisted truth. While it is
    // loading we fall back to the host's own snapshot so the switch is never
    // shown in a meaningless intermediate state.
    final enabled = hasError
        ? plugin.enabled
        : (enabledSet.valueOrNull?.contains(plugin.id) ?? plugin.enabled);

    return SettingRow(
      icon: hasError ? LucideIcons.alertTriangle : LucideIcons.puzzle,
      iconColor: hasError ? colors.error : null,
      title: plugin.name,
      isMobile: isMobile,
      isLast: isLast,
      stackOnMobile: true,
      // The plugin description is the row subtitle; the status pill (enabled /
      // error / last-fired), the optional Configure button, and the switch all
      // live in the trailing cluster.
      subtitle: plugin.description,
      trailing: _PluginRowTrailing(
        plugin: plugin,
        enabled: enabled,
        enablementLoading: enabledSet.isLoading,
        hasError: hasError,
        lastFiredAt: lastFiredAt,
        testHttpClientFactory: testHttpClientFactory,
      ),
    );
  }
}

/// The trailing cluster for a plugin row: a status pill (enabled/error/last
/// fired), an optional "Configure" button, and the enable/disable switch.
class _PluginRowTrailing extends ConsumerWidget {
  const _PluginRowTrailing({
    required this.plugin,
    required this.enabled,
    required this.enablementLoading,
    required this.hasError,
    required this.lastFiredAt,
    required this.testHttpClientFactory,
  });

  final PluginInfo plugin;
  final bool enabled;
  final bool enablementLoading;
  final bool hasError;
  final DateTime? lastFiredAt;
  final http.Client Function()? testHttpClientFactory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configurable = _pluginIsConfigurable(plugin.id);

    final pill = _PluginStatusPill(
      enabled: enabled,
      hasError: hasError,
      error: plugin.error,
      lastFiredAt: lastFiredAt,
    );

    final configureButton = configurable
        ? SkotiqButton(
            label: 'Configure',
            icon: LucideIcons.settings,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => _openConfigureDialog(context, ref),
          )
        : null;

    final toggle = _PluginEnableSwitch(
      pluginId: plugin.id,
      value: enabled,
      enabled: !enablementLoading && plugin.canEnable,
    );

    // Wrap (not Row) so the pill + Configure button + switch reflow onto a
    // second line on narrow widths instead of overflowing.
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        pill,
        if (configureButton != null) configureButton,
        toggle,
      ],
    );
  }

  Future<void> _openConfigureDialog(BuildContext context, WidgetRef ref) async {
    final host = ref.read(pluginHostProvider);
    final instance = host.getPlugin(plugin.id);
    final pluginContext = host.contextFor(plugin.id);
    if (instance == null || pluginContext == null) {
      await ErrorDialog.show(
        context,
        title: 'Plugin unavailable',
        message:
            'The "${plugin.name}" plugin is not currently loaded, so it cannot '
            'be configured.',
        technicalDetails:
            'No live instance/context for ${plugin.id} in the plugin host.',
      );
      return;
    }

    switch (plugin.id) {
      case kPushoverPluginId:
        await showDialog<void>(
          context: context,
          builder: (_) => _PushoverConfigDialog(
            plugin: instance as PushoverNotificationPlugin,
            storage: pluginContext.storage,
          ),
        );
      case kHomeAssistantPluginId:
        await showDialog<void>(
          context: context,
          builder: (_) => _HomeAssistantConfigDialog(
            plugin: instance as HomeAssistantPlugin,
            storage: pluginContext.storage,
          ),
        );
      case kDiscordPluginId:
        await showDialog<void>(
          context: context,
          builder: (_) => _DiscordConfigDialog(
            storage: pluginContext.storage,
            pluginContext: pluginContext,
            httpClientFactory: testHttpClientFactory,
          ),
        );
    }
  }
}

/// Status pill summarizing a plugin's state, in strict priority order:
/// error (red) > disabled (inactive) > last-fired (success) > enabled (active).
///
/// Disabled is checked BEFORE last-fired on purpose: a plugin the user has
/// turned off must read "Disabled" even if it fired earlier in the session.
/// Showing a green "Fired 3m ago" badge for an integration the user disabled
/// would misrepresent its state — the status pill is the at-a-glance truth of
/// the row, so it must never signal "actively working" for something that is
/// off. When a disabled plugin did fire earlier, the relative time is still
/// surfaced as secondary context.
class _PluginStatusPill extends StatelessWidget {
  const _PluginStatusPill({
    required this.enabled,
    required this.hasError,
    required this.error,
    required this.lastFiredAt,
  });

  final bool enabled;
  final bool hasError;
  final String? error;
  final DateTime? lastFiredAt;

  @override
  Widget build(BuildContext context) {
    if (hasError) {
      return const StatusPill(
        icon: LucideIcons.alertTriangle,
        label: '',
        value: 'Error',
        status: StatusPillStatus.error,
      );
    }

    if (!enabled) {
      // Off takes precedence over a stale "Fired" timestamp. If it did fire
      // before being disabled, keep the relative time as the pill value so the
      // operator still sees when it last did something, labelled "Disabled".
      return StatusPill(
        icon: LucideIcons.power,
        label: lastFiredAt != null ? 'Disabled' : '',
        value:
            lastFiredAt != null ? formatRelativeTime(lastFiredAt!) : 'Disabled',
        status: StatusPillStatus.inactive,
      );
    }

    if (lastFiredAt != null) {
      return StatusPill(
        icon: LucideIcons.activity,
        label: 'Fired',
        value: formatRelativeTime(lastFiredAt!),
        status: StatusPillStatus.success,
      );
    }

    return const StatusPill(
      icon: LucideIcons.check,
      label: '',
      value: 'Enabled',
      status: StatusPillStatus.active,
    );
  }
}

/// Formats a [timestamp] as a compact, human-relative string ("just now",
/// "3m ago", "2h ago", "5d ago"). Exposed for testability.
String formatRelativeTime(DateTime timestamp, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final delta = reference.difference(timestamp);

  if (delta.isNegative) {
    // Clock skew / future timestamp — clamp to "just now" rather than emitting
    // a nonsensical negative duration.
    return 'just now';
  }
  if (delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 1) return '1m ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}
