import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/servers/saved_servers_screen.dart';
import 'services/saved_servers_service.dart';
import 'services/android_system_ui.dart';
import 'services/foreground_service.dart';
import 'services/live_activity_lifecycle_provider.dart';
import 'services/manual_server_endpoint.dart';
import 'services/mobile_pairing_service.dart';
import 'services/watch_complication_lifecycle_provider.dart';
import 'services/mobile_preferences.dart';
import 'services/mobile_sequence_hooks.dart';
import 'services/battery_service.dart';
import 'services/network_service.dart';
import 'services/notification_service.dart';
import 'services/push_registration_service.dart';
import 'services/voice_control_lifecycle_provider.dart';
import 'services/voice_control_service.dart';
import 'utils/error_snackbar.dart';
import 'widgets/checkpoint_resume_dialog.dart';
import 'widgets/tailscale_setup_sheet.dart';

part 'main_parts/mobile_connection_state.dart';
part 'main_parts/mobile_discovery_ops.dart';
part 'main_parts/mobile_reconnect_ops.dart';

/// Product version of the running build, straight from the package manifest
/// (`pubspec.yaml` `version:`, which `version.yaml` stamps at release time).
///
/// Mirrors `loadDesktopAppVersion()`. The build number is parsed leniently: an
/// unparseable value yields 0 — an honest "unknown" — rather than inventing a
/// number, and the user-visible version string is always the real one.
@visibleForTesting
Future<AppVersionInfo> loadMobileAppVersion() async {
  final packageInfo = await PackageInfo.fromPlatform();
  return AppVersionInfo(
    version: packageInfo.version,
    buildNumber: int.tryParse(packageInfo.buildNumber) ?? 0,
  );
}

/// Delay before the Nth automatic re-attach attempt after the connection
/// monitor has declared a session lost (attempt is 0-based).
///
/// Ramps 5 s → 10 s → 20 s → 30 s and then holds at 30 s forever. Retrying
/// without end is the point: without it, losing WiFi for longer than the grace
/// period is terminal — the app drops to the connection screen and stays
/// there, so restoring the network minutes later still leaves "Please
/// reconnect" on screen even though a cold start reconnects instantly from the
/// same saved server. A 30 s idle poll costs far less than a user who wakes to
/// an app that quit watching their run hours ago.
@visibleForTesting
Duration lostSessionRetryDelay(int attempt) {
  const schedule = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];
  if (attempt < 0) return schedule.first;
  return attempt < schedule.length ? schedule[attempt] : schedule.last;
}

void main() async {
  developer.log('Starting Skotiq...', name: 'Main', level: 800);
  WidgetsFlutterBinding.ensureInitialized();

  // Respect the user's immersive-mode preference. Edge-to-edge keeps the
  // system clock and battery indicator visible by default; users who want
  // full-screen can opt in.
  if (Platform.isAndroid) {
    final prefs = await SharedPreferences.getInstance();
    final immersiveSticky = MobilePreferences(prefs).androidImmersiveSticky;
    await applyAndroidSystemUiPreference(immersiveSticky);
  }

  // Initialize CatalogManager
  try {
    final appDir = await resolveSkotiqDocumentsDirectory();
    await CatalogManager.instance.initialize(appDir.path);
  } catch (e) {
    developer.log(
      'Failed to initialize CatalogManager: $e',
      name: 'Main',
      level: 1000,
    );
  }

  // Initialize NetworkService for connectivity monitoring
  try {
    await NetworkService().initialize();
    developer.log('NetworkService initialized', name: 'Main');
  } catch (e) {
    developer.log(
      'Failed to initialize NetworkService: $e',
      name: 'Main',
      level: 1000,
    );
  }

  // start the battery sampler so the dashboard
  // indicator and any throttling consumer (live-preview poller,
  // catalog sync, etc.) see a populated PhoneBatteryState on first
  // build. Failures are non-fatal: the indicator gracefully renders
  // SizedBox.shrink() while the level remains -1.
  try {
    await BatteryService().start();
    developer.log('BatteryService started', name: 'Main');
  } catch (e, st) {
    developer.log(
      'Failed to start BatteryService: $e',
      name: 'Main',
      level: 1000,
      error: e,
      stackTrace: st,
    );
  }

  // request Android POST_NOTIFICATIONS at startup
  // *before* runApp() so the system prompt is shown on first launch (and
  // not buried behind a connection screen). Without this, Android 13+
  // silently drops every notification we try to fire. Also wires up the
  // foreground-task plugin so the OS sees a granted notification permission
  // before the first sequence tries to start a foreground service.
  //
  // The notification service singleton is idempotent — subsequent calls
  // from MobileSequenceHooks.initialize() are no-ops via the _initialized
  // flag. We deliberately initialize both services here:
  //
  //   1. MobileNotificationService — handles flutter_local_notifications
  //      runtime permission request (POST_NOTIFICATIONS).
  //   2. ImagingForegroundService — handles flutter_foreground_task's own
  //      permission checks, which it uses before startService() will run.
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await MobileNotificationService().initialize();
      developer.log('MobileNotificationService initialized', name: 'Main');
    } catch (e, st) {
      developer.log(
        'Failed to initialize MobileNotificationService: $e',
        name: 'Main',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }

    if (Platform.isAndroid) {
      try {
        await ImagingForegroundService().initialize();
        // Ask the foreground-task plugin to confirm the notification
        // permission too — its own check sits between us and startService.
        // We deliberately ignore the result here: the local-notifications
        // plugin call above is the authoritative one for our banner state,
        // and re-prompting from this call (after the user has already
        // answered the first prompt) is a no-op on every supported API
        // level.
        await ImagingForegroundService().requestNotificationPermission();
        developer.log('ImagingForegroundService initialized', name: 'Main');
      } catch (e, st) {
        developer.log(
          'Failed to initialize ImagingForegroundService: $e',
          name: 'Main',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  // Add error handling
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    developer.log(
      'Flutter Error: ${details.exception}',
      name: 'Main',
      level: 1000,
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  // Real product version, read from the built package the same way the desktop
  // entry point does — never a literal. Per appVersionProvider's contract a
  // wrong version here drives the OTA update comparison and the plugin host,
  // and misroutes every bug report filed from the About screen.
  final appVersion = await loadMobileAppVersion();

  runApp(
    ProviderScope(
      overrides: [
        // appVersionProvider throws by default to surface misconfiguration;
        // canonical override lives in the entry point. Single source of truth
        // is version.yaml, which the build stamps into the package manifest.
        appVersionProvider.overrideWithValue(appVersion),
        pluginHostAppVersionOverride(appVersion.version),
        // wire the plugin-node dispatcher so plugin
        // sequence nodes route through the real PluginNodeExecutor.
        pluginNodeDispatcherOverride(),
        // surface plugin-contributed sequence nodes in the
        // sequencer palette.
        pluginNodePaletteBlueprintsOverride(),
        // C4 — honour the user's persisted plugin enable/disable choices
        // at registration time so a plugin disabled on the Integrations
        // page stays disabled across launches instead of silently being
        // re-enabled by the default all-enabled store.
        pluginEnablementStoreOverride(),
      ],
      child: const SkotiqMobileApp(),
    ),
  );
}

/// identity payload passed to [BackendNotifier.connect] so the
/// [NetworkBackend] can populate its `collaboration.join` frame after the
/// WS handshake succeeds. The values are derived from:
///   * `viewerId` — `computeServerFingerprint(authToken)` so the digest
///     matches what the server computes from the authenticated bearer.
///     When auth is disabled we fall back to the stable per-device id
///     persisted by [MobilePairingService] so the slot still has an id.
///   * `deviceName` — the stable per-device id (used as a machine-
///     readable secondary key in the slot list).
///   * `displayName` — user-visible label. Default is `"PLATFORM · SHORTID"`;
///     a future preference can override it.
class _CollaborationIdentityBundle {
  final String viewerId;
  final String deviceName;
  final String displayName;

  const _CollaborationIdentityBundle({
    required this.viewerId,
    required this.deviceName,
    required this.displayName,
  });
}

/// Compute the collaboration identity used for `collaboration.join`.
///
/// Why this lives outside the widget class: it's a pure function (one
/// SharedPreferences read + one async device-id load) and putting it at
/// top level lets the tests exercise it without booting the widget tree.
Future<_CollaborationIdentityBundle> _buildCollaborationIdentity(
  String? authToken,
) async {
  // Stable per-install device id — populated lazily by MobilePairingService
  // and persisted in SharedPreferences. This is the same identifier used
  // by the pairing flow, so the slot label stays consistent across the
  // pairing handshake and the WS collaboration channel.
  final deviceId = await MobilePairingService.deviceId();
  // Short tail (the suffix bytes are random; the prefix is the constant
  // `mobile:` discriminator) keeps the display readable in the host's
  // viewer slot list without exposing the full id.
  final shortId = deviceId.length > 14
      ? deviceId.substring(deviceId.length - 6)
      : deviceId;
  final platformLabel = Platform.isIOS
      ? 'iPhone'
      : Platform.isAndroid
      ? 'Android'
      : Platform.operatingSystem;
  // The viewerId MUST match the server's `computeServerFingerprint(token)`
  // when auth is enabled — otherwise the server's override branch
  // would log every join as an impersonation attempt. When auth is off
  // (no token), use the stable device id so the slot still has a unique
  // identifier — the server's override will not fire in that case.
  final viewerId = (authToken != null && authToken.trim().isNotEmpty)
      ? computeServerFingerprint(authToken)
      : deviceId;
  final displayName = '$platformLabel · $shortId';
  return _CollaborationIdentityBundle(
    viewerId: viewerId,
    deviceName: deviceId,
    displayName: displayName,
  );
}

class SkotiqMobileApp extends ConsumerStatefulWidget {
  const SkotiqMobileApp({super.key});

  @override
  ConsumerState<SkotiqMobileApp> createState() => _SkotiqMobileAppState();
}

class _SkotiqMobileAppState extends ConsumerState<SkotiqMobileApp>
    with
        WidgetsBindingObserver,
        _MobileConnectionState,
        _MobileDiscoveryOps,
        _MobileReconnectOps {
  StreamSubscription<VoiceControlAction>? _voiceActionSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Register the relay-reconnect bridge so the dashboard-launched
    // SavedServersScreen can dial a saved relay row through the tunnel this
    // (always-mounted) shell owns. Done post-frame because mutating a
    // provider during initState/build is disallowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(relayReconnectProvider.notifier).state = _reconnectSavedRelay;
    });
    // Automatically discover and connect on startup
    _autoConnect();

    // "Hey Siri, show the last Skotiq image": the voice lifecycle
    // controller receives this action but owns no router, so the shell
    // navigates from here. Reading the provider also keeps the inbound
    // method-channel handler alive.
    _voiceActionSub = ref
        .read(voiceControlServiceProvider)
        .actionStream
        .listen(_handleVoiceAction);
  }

  void _handleVoiceAction(VoiceControlAction action) {
    if (action != VoiceControlAction.openLastImage) return;
    final router = ref.read(appRouterProvider);
    if (ref.read(lastImageStatsProvider) == null) {
      final navContext = router.routerDelegate.navigatorKey.currentContext;
      if (navContext != null && navContext.mounted) {
        ScaffoldMessenger.maybeOf(navContext)?.showSnackBar(
          const SnackBar(content: Text('No captured image yet this session.')),
        );
      }
      return;
    }
    router.go('/imaging');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _setNetworkHeartbeatPaused(false);
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _setNetworkHeartbeatPaused(true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopConnectionMonitor();
    _voiceActionSub?.cancel();
    _pushRegistration?.dispose();
    _ipController.dispose();
    _accessTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    try {
      // Handle disconnection from Settings — if the backend becomes
      // DisconnectedBackend, return to the connection screen. Listening
      // (instead of watching+addPostFrameCallback in build) avoids the
      // build-time setState cycle flagged
      ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
        if (!mounted) return;
        if (_connectedServer != null &&
            next is DisconnectedBackend &&
            !_skippedConnection) {
          // Audit drop the checkpoint-once latch alongside the
          // backend swap. Otherwise a Settings-driven disconnect then
          // reconnect in the same app lifecycle would silently skip the
          // resume dialog even if the server now has a fresh
          // interrupted sequence.
          _checkpointChecked = false;
          setState(() {
            _connectedServer = null;
            _error = null;
            _statusMessage = '';
          });
          return;
        }
        // A rig switch from Saved Servers swaps in a fresh NetworkBackend
        // without routing through _connectToServer, so re-arm the WS monitor
        // on the new instance. Idempotent — it cancels any prior subscription
        // first.
        if (next is NetworkBackend && !identical(previous, next)) {
          _startConnectionMonitor();
        }
      });

      // If not connected and not skipped, show connection screen
      if (_connectedServer == null && !_skippedConnection) {
        final settings = ref.watch(appSettingsProvider).valueOrNull;
        final theme = resolveSkotiqThemeData(
          themeSetting: settings?.theme ?? 'dark',
          accentColorHex: settings?.accentColor,
        );
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemUiOverlayStyleFor(theme),
          child: MaterialApp(
            navigatorKey: _connectionNavigatorKey,
            title: 'Skotiq',
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
            supportedLocales: SkotiqLocalizations.supportedLocales,
            // The connection screen IS the app's ready state while it is
            // disconnected — pairing, discovery and manual connect all have
            // to stay reachable, so the splash plays its draw over it once
            // and lifts instead of holding a loading mark in front of
            // interactive prompts.
            home: SkotiqSplashGate(
              ready: true,
              child: Builder(builder: (context) => _buildConnectionScreen()),
            ),
          ),
        );
      }

      // Full UI parity: phones and tablets both route through the shared
      // GoRouter shell (`SkotiqApp(isMobile: true)`).
      return Consumer(
        builder: (context, ref, _) {
          // Activate location sync
          ref.watch(locationSyncProvider);

          // Mirror host rig state (profiles, connected devices, sequencer)
          // when controlling a remote desktop via NetworkBackend.
          ref.watch(remoteSessionSyncProvider);
          ref.watch(sequenceLibrarySyncProvider);
          ref.watch(remoteSequenceEditorSyncProvider);

          // Initialize mobile sequence hooks for background operation support
          ref.watch(mobileSequenceHooksProvider);

          // Architecture-unification, Subsystem 3: eager-mount the
          // NotificationRouter so the external transports (Discord, email,
          // Telegram, Pushover, MQTT, webhook) configured on this device fire
          // for routed events mirrored from the host over NetworkBackend —
          // even when no sequence is running. Watching it here keeps its
          // backend event-stream subscription alive for the lifetime of the
          // connected companion shell.
          ref.watch(notificationRouterProvider);

          // wire the iOS Live Activity lifecycle controller. The
          // controller installs its own ref.listen() bindings on construction;
          // on non-iOS platforms it is a no-op so the watch is cheap.
          ref.watch(liveActivityLifecycleProvider);

          // wire the Apple Watch complication lifecycle
          // controller. Same shape as the Live Activity one: on iOS it
          // installs listeners that throttle sequence + weather state
          // changes into App Group writes + `WidgetCenter` reloads at
          // most once per 30 s; on non-iOS platforms the provider is a
          // no-op so this watch costs nothing on Android/desktop.
          ref.watch(watchComplicationLifecycleProvider);

          // Wire notification taps into go_router. The router
          // is created lazily by `appRouterProvider`; reading it here also
          // ensures it exists before a notification can fire.
          final router = ref.watch(appRouterProvider);
          MobileNotificationService().setNavigator((location) {
            router.go(location);
          });
          // A tap that cold-started the app from a terminated state arrives
          // via getNotificationAppLaunchDetails rather than the tap callback,
          // so route it once the navigator above exists (guarded internally so
          // a rebuild can't double-route).
          unawaited(MobileNotificationService().handleLaunchNotification());

          // Check for checkpoint on first connection
          _checkForCheckpoint(context, ref);

          return const SkotiqApp(isMobile: true);
        },
      );
    } catch (e, stackTrace) {
      // Fallback UI if something goes wrong
      developer.log(
        'Error building app: $e',
        name: 'Main',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      return MaterialApp(
        title: 'Skotiq',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    SkotiqLocalizations.of(
                      context,
                    ).text('mobileErrorLoadingApp'),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Error: $e',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _connectedServer = null;
                        _error = null;
                        _isDiscovering = false;
                      });
                      _autoConnect();
                    },
                    child: Text(
                      SkotiqLocalizations.of(context).text('mobileRetry'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildConnectionScreen() {
    // Safe color access with fallback
    return Builder(
      builder: (context) {
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final colors = theme.extension<SkotiqColors>();

        // If colors extension not available, use default Material colors
        final bgColor = colors?.background ?? theme.scaffoldBackgroundColor;
        final surfaceColor = colors?.surface ?? theme.cardColor;
        final textColor =
            colors?.textPrimary ??
            theme.textTheme.bodyLarge?.color ??
            theme.colorScheme.onSurface;
        final textSecondary =
            colors?.textSecondary ??
            theme.textTheme.bodyMedium?.color ??
            theme.colorScheme.onSurfaceVariant;
        final borderColor = colors?.border ?? theme.colorScheme.outlineVariant;
        final primaryColor = colors?.primary ?? theme.colorScheme.primary;
        final errorColor = colors?.error ?? theme.colorScheme.error;

        return Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            backgroundColor: surfaceColor,
            title: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: SkotiqDecorations.iconChip(
                    primaryColor,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Skotiq',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Status card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: textSecondary,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.text('mobileNotConnected'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: SkotiqDecorations.emphasisSurface(
                            errorColor,
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(fontSize: 12, color: errorColor),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Connection options (Manual IP, QR scan, Tailscale)
                if (!_isDiscovering && !_showManualEntry) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SkotiqButton(
                        onPressed: () {
                          setState(() {
                            _showManualEntry = true;
                            _error = null;
                          });
                        },
                        icon: Icons.edit_location_alt,
                        label: l10n.text('mobileEnterIp'),
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                      ),
                      const SizedBox(width: 8),
                      SkotiqButton(
                        onPressed: _scanQrCode,
                        icon: Icons.qr_code_scanner,
                        label: l10n.text('mobileScanQr'),
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Off-site path: reach a remote rig over the tailnet. Kept
                  // distinct from QR/manual because it carries its own guided
                  // setup (install Tailscale, find the MagicDNS name, etc.).
                  Center(
                    child: SkotiqButton(
                      onPressed: _connectViaTailscale,
                      icon: LucideIcons.radioTower,
                      label: l10n.text('tailscaleConnect'),
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // v4 couch-grade remote: reach a rig from anywhere through a
                  // self-hosted relay (no VPN / port-forwarding). Collects the
                  // relay URL + appliance id, then tunnels via _connectViaRelay.
                  Center(
                    child: SkotiqButton(
                      onPressed: _showRelayConnectDialog,
                      icon: LucideIcons.globe,
                      label: l10n.text('relayConnect'),
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Saved Servers entry point on the DEFAULT connection screen.
                  // Lets an operator who manages multiple rigs roam between
                  // previously-paired hosts without re-discovering.
                  Center(
                    child: SkotiqButton(
                      onPressed: _openSavedServers,
                      icon: LucideIcons.server,
                      label: l10n.text('savedServersTitle'),
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                  ),
                ],

                // Manual IP entry field
                if (_showManualEntry) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ipController,
                    decoration: InputDecoration(
                      labelText: l10n.text('mobileServerIpAddress'),
                      hintText: 'skotiq.local:8080',
                      prefixIcon: const Icon(Icons.computer),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      filled: true,
                      fillColor: surfaceColor,
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _accessTokenController,
                    obscureText: !_accessTokenVisible,
                    decoration: InputDecoration(
                      labelText: 'Access Token',
                      hintText: 'Optional for paired or protected hosts',
                      prefixIcon: const Icon(Icons.vpn_key),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _accessTokenVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        tooltip: _accessTokenVisible
                            ? 'Hide access token'
                            : 'Show access token',
                        onPressed: () {
                          setState(() {
                            _accessTokenVisible = !_accessTokenVisible;
                          });
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      filled: true,
                      fillColor: surfaceColor,
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SkotiqButton(
                          onPressed: () {
                            setState(() {
                              _showManualEntry = false;
                            });
                          },
                          label: l10n.text('cancel'),
                          variant: ButtonVariant.outline,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SkotiqButton(
                          onPressed: _connectManually,
                          label: l10n.text('connect'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],

                // Action buttons
                if (_isDiscovering)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        children: [
                          SkotiqMark(
                            motion: SkotiqMarkMotion.loading,
                            size: 36,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _statusMessage.isNotEmpty
                                ? _statusMessage
                                : l10n.text('mobileSearchingForServer'),
                            style: TextStyle(
                              fontSize: 14,
                              color: textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (!_showManualEntry)
                  SizedBox(
                    width: double.infinity,
                    child: SkotiqButton(
                      onPressed: _autoConnect,
                      icon: Icons.search,
                      label: l10n.text('searchForServer'),
                      size: ButtonSize.large,
                    ),
                  ),

                if (!_isDiscovering && !_showManualEntry) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _skipConnection,
                    child: Text(
                      l10n.text('mobileSkipConnection'),
                      style: TextStyle(color: textSecondary),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // Instructions
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: surfaceColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 20,
                            color: textSecondary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            l10n.text('mobileHowToConnect'),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        l10n.text('mobileHowToConnectSteps'),
                        style: TextStyle(
                          fontSize: 12,
                          color: textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
