import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/skotiq_app.dart';
import 'package:skotiq_app/router/app_routes.dart';
import 'package:skotiq_app/screens/connection/link_mismatch_actions.dart';
import 'package:skotiq_app/startup/app_overrides.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skotiq_app/widgets/red_night_filter.dart';
import 'screens/setup/first_run_setup_screen.dart';
import 'screens/servers/saved_servers_screen.dart';
import 'services/saved_servers_service.dart';
import 'services/android_system_ui.dart';
import 'services/foreground_service.dart';
import 'services/manual_server_endpoint.dart';
import 'services/mobile_platform_services.dart';
import 'services/mobile_preferences.dart';
import 'services/mobile_sequence_hooks.dart';
import 'services/battery_service.dart';
import 'services/network_service.dart';
import 'services/notification_service.dart';
import 'services/phone_rig_connection.dart';
import 'services/voice_control_lifecycle_provider.dart';
import 'services/voice_control_service.dart';
import 'widgets/connect_texts.dart';
import 'widgets/phone_battery_indicator.dart';
import 'widgets/relay_connect_dialog.dart';
import 'widgets/tailscale_setup_sheet.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';

part 'main_parts/mobile_connect_actions.dart';

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

void main() async {
  Log.listen();
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
      nebulaLight: builtInNebulaLight,
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

  // Set up notifications without asking for POST_NOTIFICATIONS: the linked
  // shell offers it with the reason (AndroidNotificationsBanner). Both
  // plugins read the same Android permission, so the foreground plugin is
  // configured without prompting either.
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
        launchRoleProvider.overrideWithValue(LaunchRole.mobile),
        ...appProviderOverrides(appVersion),
        phoneBarStatusProvider.overrideWithValue(const PhoneBatteryIndicator()),
        androidNotificationsRequestProvider.overrideWithValue(
          Platform.isAndroid
              ? MobileNotificationService().requestAndroidNotificationPermission
              : null,
        ),
        ...phoneConnectionOverrides,
      ],
      child: const SkotiqMobileApp(),
    ),
  );
}

class SkotiqMobileApp extends ConsumerStatefulWidget {
  const SkotiqMobileApp({super.key});

  @override
  ConsumerState<SkotiqMobileApp> createState() => _SkotiqMobileAppState();
}

class _SkotiqMobileAppState extends ConsumerState<SkotiqMobileApp>
    with WidgetsBindingObserver, _MobileConnectActions {
  StreamSubscription<VoiceControlAction>? _voiceActionSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Creating the connect flow starts the search.
    ref.read(rigConnectionProvider);

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
      _connection.appResumed();
      // Alerts may have been turned on in Android's settings meanwhile.
      unawaited(
        ref
            .read(mobileSequenceHooksProvider)
            .refreshAndroidNotificationsAuthorization(),
      );
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _connection.appBackgrounded();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceActionSub?.cancel();
    _ipController.dispose();
    _accessTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    try {
      // The phone rests on the demo rig instead of no backend while it is
      // turned on in Settings > Replay & debug.
      ref.watch(demoRigSelectionProvider);
      final connection = ref.watch(rigConnectionProvider).state;
      ref.listen<bool>(rigConnectionProvider.select((c) => c.state.stale), (
        _,
        stale,
      ) {
        ref.read(connectionStaleProvider.notifier).state = stale;
      });

      if (connection.connected == null && !connection.skipped) {
        // The connection screen IS the app's ready state while it is
        // disconnected — pairing, discovery and manual connect all have
        // to stay reachable, so the splash plays its draw over it once
        // and lifts instead of holding a loading mark in front of
        // interactive prompts.
        return _standaloneApp(
          SkotiqSplashGate(
            ready: true,
            child: Builder(
              builder: (context) => _buildConnectionScreen(connection),
            ),
          ),
          navigatorKey: phoneConnectionNavigatorKey,
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

          return SkotiqApp(platformServices: mobilePlatformServices);
        },
      );
      if (connection.connected == null) return shell;
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
                      _connection.resetAfterAppError();
                      unawaited(_connection.autoConnect());
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
        // The shell's own router app ends text editing on keyboard close;
        // this covers the connection screen (pairing code, address).
        builder: (context, child) => UnfocusOnKeyboardClose(
          child: RedNightScreen(child: child ?? const SizedBox.shrink()),
        ),
        navigatorObservers: [UnfocusTextOnPopupObserver()],
        home: home,
      ),
    );
  }

  Widget _buildConnectionScreen(RigConnectState connection) {
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
        final errorColor = colors?.error ?? theme.colorScheme.error;

        final busy = connection.busy;
        final manualEntryOpen = connection.manualEntryOpen;
        final status = connectActivityText(connection.activity, l10n);
        final problem = connection.problem;
        final error = problem == null
            ? null
            : connectProblemText(problem, l10n);
        final showChoices = !busy && !manualEntryOpen;

        Widget awayRow({
          required IconData icon,
          required String label,
          required String detail,
          required VoidCallback onTap,
        }) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: SkotiqTokens.spaceMd,
              horizontal: SkotiqTokens.spaceSm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: textSecondary),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: SkotiqTypography.bodyMedium.copyWith(
                          color: textColor,
                        ),
                      ),
                      Text(
                        detail,
                        style: SkotiqTypography.caption.copyWith(
                          color: textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 18, color: textSecondary),
              ],
            ),
          ),
        );

        return Scaffold(
          backgroundColor: bgColor,
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: SkotiqLockup(markSize: 20),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    l10n.text('mobileConnectTitle'),
                    style: SkotiqTypography.h3.copyWith(color: textColor),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text(
                    l10n.text('mobileConnectBody'),
                    style: SkotiqTypography.body.copyWith(color: textSecondary),
                  ),
                  const SizedBox(height: 20),

                  if (busy)
                    Container(
                      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                      decoration: BoxDecoration(
                        color: surfaceColor,
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusLg,
                        ),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          SkotiqMark(
                            motion: SkotiqMarkMotion.loading,
                            size: 24,
                          ),
                          const SizedBox(width: SkotiqTokens.spaceMd),
                          Expanded(
                            child: Text(
                              status.isNotEmpty
                                  ? status
                                  : l10n.text('mobileLookingOnWifi'),
                              style: SkotiqTypography.body.copyWith(
                                color: textColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (error != null) ...[
                    if (busy) const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: SkotiqDecorations.statusChip(
                        errorColor,
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusMd,
                        ),
                      ),
                      child: Text(
                        error,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize13,
                          color: errorColor,
                        ),
                      ),
                    ),
                    if (connection.mismatchedHost case final host?
                        when host.linkMismatch != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: LinkMismatchActions(
                          host: host,
                          mismatch: host.linkMismatch!,
                        ),
                      ),
                    const SizedBox(height: 16),
                  ],

                  if (connection.unpairedHost case final found?
                      when showChoices) ...[
                    Container(
                      padding: const EdgeInsets.fromLTRB(
                        SkotiqTokens.spaceLg,
                        SkotiqTokens.spaceMd,
                        SkotiqTokens.spaceMd,
                        SkotiqTokens.spaceMd,
                      ),
                      decoration: BoxDecoration(
                        color: surfaceColor,
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusLg,
                        ),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.monitor,
                            size: 20,
                            color: textSecondary,
                          ),
                          const SizedBox(width: SkotiqTokens.spaceMd),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.text(
                                    'mobileFoundHost',
                                    params: {'name': found.name},
                                  ),
                                  style: SkotiqTypography.bodyMedium.copyWith(
                                    color: textColor,
                                  ),
                                ),
                                Text(
                                  l10n.text(
                                    'mobileFoundHostDetail',
                                    params: {'host': found.host},
                                  ),
                                  style: SkotiqTypography.caption.copyWith(
                                    color: textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          SkotiqButton(
                            onPressed: () =>
                                unawaited(_connection.connect(found)),
                            label: l10n.text('mobilePair'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceLg),
                  ],

                  if (showChoices) ...[
                    SkotiqButton(
                      onPressed: _scanQrCode,
                      icon: LucideIcons.scanLine,
                      label: l10n.text('mobileScanQr'),
                      size: ButtonSize.large,
                      // A found computer's Pair is the step; its dialog
                      // offers the scan too.
                      variant: connection.unpairedHost == null
                          ? ButtonVariant.primary
                          : ButtonVariant.secondary,
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    Text(
                      l10n.text('mobileQrWhere'),
                      textAlign: TextAlign.center,
                      style: SkotiqTypography.caption.copyWith(
                        color: textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: SkotiqButton(
                            onPressed: _connection.autoConnect,
                            icon: LucideIcons.search,
                            label: l10n.text('mobileSearchAgain'),
                            variant: ButtonVariant.secondary,
                          ),
                        ),
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        Expanded(
                          child: SkotiqButton(
                            onPressed: _connection.openManualEntry,
                            icon: LucideIcons.keyboard,
                            label: l10n.text('mobileEnterAddress'),
                            variant: ButtonVariant.secondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SkotiqButton(
                      onPressed: _openSavedServers,
                      icon: LucideIcons.server,
                      label: l10n.text('savedServersTitle'),
                      variant: ButtonVariant.ghost,
                    ),
                  ],

                  if (manualEntryOpen) ...[
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
                        labelText: l10n.text('mobileAccessTokenLabel'),
                        hintText: l10n.text('mobileAccessTokenHint'),
                        prefixIcon: const Icon(Icons.vpn_key),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _accessTokenVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          tooltip: l10n.text(
                            _accessTokenVisible
                                ? 'mobileHideAccessToken'
                                : 'mobileShowAccessToken',
                          ),
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
                            onPressed: _connection.closeManualEntry,
                            label: l10n.text('cancel'),
                            variant: ButtonVariant.secondary,
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
                  ],

                  if (showChoices) ...[
                    const SizedBox(height: 28),
                    Text(
                      l10n.text('mobileAwayFromHome').toUpperCase(),
                      style: SkotiqTypography.overline.copyWith(
                        color: textSecondary,
                      ),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceXs),
                    // Off-site paths, each with its own guided setup.
                    awayRow(
                      icon: LucideIcons.radioTower,
                      label: l10n.text('tailscaleConnect'),
                      detail: l10n.text('tailscaleConnectDetail'),
                      onTap: _connectViaTailscale,
                    ),
                    awayRow(
                      icon: LucideIcons.globe,
                      label: l10n.text('relayConnect'),
                      detail: l10n.text('relayConnectDetail'),
                      onTap: _showRelayConnectDialog,
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: TextButton(
                        onPressed: _connection.skip,
                        child: Text(
                          l10n.text('mobileLookAround'),
                          style: TextStyle(color: textSecondary),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
