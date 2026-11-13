import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/startup/app_overrides.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/widgets/red_night_filter.dart';
import 'screens/qr_scanner_screen.dart';
import 'screens/setup/first_run_setup_screen.dart';
import 'screens/servers/saved_servers_screen.dart';
import 'services/saved_servers_service.dart';
import 'services/android_system_ui.dart';
import 'services/foreground_service.dart';
import 'services/manual_server_endpoint.dart';
import 'services/mobile_pairing_service.dart';
import 'services/mobile_platform_services.dart';
import 'services/mobile_preferences.dart';
import 'services/battery_service.dart';
import 'services/network_service.dart';
import 'services/notification_service.dart';
import 'services/push_registration_service.dart';
import 'services/voice_control_lifecycle_provider.dart';
import 'services/voice_control_service.dart';
import 'utils/error_snackbar.dart';
import 'widgets/checkpoint_resume_dialog.dart';
import 'widgets/phone_battery_indicator.dart';
import 'widgets/tailscale_setup_sheet.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';

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
  Log.info('Starting Skotiq...', source: 'Main');
  WidgetsFlutterBinding.ensureInitialized();

  // Respect the user's immersive-mode preference. Edge-to-edge keeps the
  // system clock and battery indicator visible by default; users who want
  // full-screen can opt in.
  if (Platform.isAndroid) {
    final prefs = await SharedPreferences.getInstance();
    final immersiveSticky = MobilePreferences(prefs).androidImmersiveSticky;
    await applyAndroidSystemUiPreference(immersiveSticky);
  }

  try {
    final appDir = await resolveSkotiqDocumentsDirectory();
    await CatalogManager.instance.initialize(
      appDir.path,
      builtIn: builtInCatalogs,
    );
  } catch (e) {
    Log.error('Failed to initialize CatalogManager: $e', source: 'Main');
  }

  try {
    await NetworkService().initialize();
    Log.debug('NetworkService initialized', source: 'Main');
  } catch (e) {
    Log.error('Failed to initialize NetworkService: $e', source: 'Main');
  }

  // Sampled before the first frame so the top-bar battery warning and the
  // poll pace start from a real reading. Without one both act as if the
  // battery were full.
  try {
    await BatteryService().start();
    Log.debug('BatteryService started', source: 'Main');
  } catch (e, st) {
    Log.error(
      'Failed to start BatteryService: $e',
      source: 'Main',
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
      Log.debug('MobileNotificationService initialized', source: 'Main');
    } catch (e, st) {
      Log.error(
        'Failed to initialize MobileNotificationService: $e',
        source: 'Main',
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
        Log.debug('ImagingForegroundService initialized', source: 'Main');
      } catch (e, st) {
        Log.error(
          'Failed to initialize ImagingForegroundService: $e',
          source: 'Main',
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Log.error(
      'Flutter Error: ${details.exception}',
      source: 'Main',
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
        ...appProviderOverrides(appVersion),
        phoneBarStatusProvider.overrideWithValue(const PhoneBatteryIndicator()),
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
        navContext.showInfoSnackBar('No captured image yet this session.');
      }
      return;
    }
    router.go(AppRoute.imaging.path);
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
        if (_connectedServer != null && next.hasNoHost && !_skippedConnection) {
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
      });
      // A rig switch from Saved Servers swaps in a fresh NetworkBackend
      // without routing through _connectToServer, so re-arm the WS monitor
      // on the new link. Idempotent — it cancels any prior subscription
      // first. This follows the link, not the backend: a backend listener
      // runs before the link is rebuilt.
      ref.listen<HostLink?>(linkedHostLinkProvider, (previous, next) {
        if (!mounted) return;
        if (next != null && !identical(previous, next)) {
          _startConnectionMonitor();
        }
      });

      if (_connectedServer == null && !_skippedConnection) {
        // The connection screen IS the app's ready state while it is
        // disconnected — pairing, discovery and manual connect all have
        // to stay reachable, so the splash plays its draw over it once
        // and lifts instead of holding a loading mark in front of
        // interactive prompts.
        return _standaloneApp(
          SkotiqSplashGate(
            ready: true,
            child: Builder(builder: (context) => _buildConnectionScreen()),
          ),
          navigatorKey: _connectionNavigatorKey,
        );
      }

      // Full UI parity: phones and tablets both route through the shared
      // GoRouter shell (`SkotiqApp`).
      final shell = Consumer(
        builder: (context, ref, _) {
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

          return SkotiqApp(platformServices: mobilePlatformServices);
        },
      );
      if (_connectedServer == null) return shell;
      return FirstRunSetupGate(frame: _standaloneApp, child: shell);
    } catch (e, stackTrace) {
      Log.error(
        'Error building app: $e',
        source: 'Main',
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
                      fontSize: SkotiqTypography.fontSize18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Error: ${userFacingError(e)}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                    ),
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

  /// The themed app frame for what the phone shows outside the shell: the
  /// connection screen and first-run setup.
  Widget _standaloneApp(
    Widget home, {
    GlobalKey<NavigatorState>? navigatorKey,
  }) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final theme = resolveSkotiqThemeData(
      themeSetting: settings?.theme ?? 'dark',
      accentColorHex: settings?.accentColor,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: systemUiOverlayStyleFor(theme),
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Skotiq',
        debugShowCheckedModeBanner: false,
        theme: theme,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        builder: (context, child) =>
            RedNightScreen(child: child ?? const SizedBox.shrink()),
        home: home,
      ),
    );
  }

  Widget _buildConnectionScreen() {
    return Builder(
      builder: (context) {
        final l10n = context.l10n;
        final theme = Theme.of(context);
        final colors = theme.extension<SkotiqColors>();

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
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
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
                    fontSize: SkotiqTypography.fontSize18,
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
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
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
                              fontSize: SkotiqTypography.fontSize14,
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
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize12,
                              color: errorColor,
                            ),
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

                if (_showManualEntry) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _ipController,
                    decoration: InputDecoration(
                      labelText: l10n.text('mobileServerIpAddress'),
                      hintText: 'skotiq.local:8080',
                      prefixIcon: const Icon(Icons.computer),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusLg,
                        ),
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
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusLg,
                        ),
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
                              fontSize: SkotiqTypography.fontSize14,
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
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
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
                              fontSize: SkotiqTypography.fontSize14,
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
                          fontSize: SkotiqTypography.fontSize12,
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
