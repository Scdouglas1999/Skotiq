import 'widgets/mount/mount_site_reconciliation_card.dart';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_updater/skotiq_updater.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/services/location_sync_service.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/widgets/quick_start_checker.dart';
import 'package:skotiq_app/widgets/auto_discovery_launcher.dart';
import 'package:skotiq_app/widgets/startup_auto_connect_launcher.dart';
import 'package:skotiq_app/widgets/database_recovery_launcher.dart';
import 'package:skotiq_app/widgets/equipment_onboarding_launcher.dart';
import 'package:skotiq_app/widgets/auto_integration_launcher.dart';

class SkotiqApp extends ConsumerWidget {
  final bool isMobile;
  final bool isDesktop;

  const SkotiqApp({
    this.isMobile = false,
    this.isDesktop = false,
    super.key,
  });

  /// Calculate UI scale factor for high-DPI displays
  ///
  /// On Linux and some other platforms, Flutter may not properly scale UI
  /// elements for high-DPI displays. This detects the device pixel ratio
  /// and applies additional scaling to make the UI readable.
  double _calculateUiScaleFactor(BuildContext context, String? uiScaleSetting) {
    // If user has explicitly set a scale, use it
    if (uiScaleSetting != null && uiScaleSetting != 'Auto') {
      switch (uiScaleSetting) {
        case 'Small (0.8x)':
          return 0.8;
        case 'Normal (1.0x)':
          return 1.0;
        case 'Large (1.2x)':
          return 1.2;
        case 'Extra Large (1.4x)':
          return 1.4;
      }
    }

    // Auto-detect scale for high-DPI displays
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    // On Linux with high-DPI displays, apply additional scaling
    // Linux Wayland/X11 doesn't always properly scale Flutter apps
    // High-DPI is typically > 1.5 device pixel ratio
    if (!kIsWeb && Platform.isLinux && devicePixelRatio > 1.5) {
      // For high DPI displays, apply more aggressive scaling
      // DPR 2.0 -> 1.25x scale, DPR 2.5 -> 1.5x scale, DPR 3.0 -> 1.75x scale
      final extraScale = 1.0 + (devicePixelRatio - 1.5) * 0.5;
      return extraScale.clamp(1.0, 1.75);
    }

    // For desktops with small windows, don't scale down
    // For mobile, let Flutter handle it naturally
    return 1.0;
  }

  /// Get text scale factor from font size setting
  double _getTextScaleFactor(String fontSize) {
    switch (fontSize) {
      case 'Small':
        return 0.85;
      case 'Large':
        return 1.15;
      case 'Medium':
      default:
        return 1.0;
    }
  }

  Locale? _resolveLocale(String? languageCode) {
    switch (languageCode) {
      case 'en':
        return const Locale('en');
      case 'es':
        return const Locale('es');
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    // Activate location sync to keep planetarium in sync with settings
    ref.watch(locationSyncProvider);
    ref.watch(pushNotificationServiceProvider);
    ref.watch(remoteSessionSyncProvider);
    ref.watch(hostLocalSyncProvider);
    ref.watch(sequenceLibrarySyncProvider);
    ref.watch(remoteSequenceEditorSyncProvider);
    // MASTER -> SLAVE: push the master's open sequencer canvas to slaves live.
    // Self-gates to a no-op unless this instance is a serving FfiBackend master.
    ref.watch(masterSequenceEditorMirrorProvider);
    // Runtime results (solves, centering, autofocus, the frame on screen):
    // published by a hardware-owning host, reported up by a linked client.
    ref.watch(hostRuntimeMirrorProvider);
    ref.watch(clientRuntimeReporterProvider);
    // Keep science.camera.* (read noise / gain / saturation) in sync with
    // the connected camera or active profile so photometry works without
    // manual sensor-spec entry.
    ref.watch(scienceCameraAutoConfigProvider);
    // Keep the Night Narrator alive for the active session: it is a plain
    // Provider (recreated when the session id changes) and nothing else
    // watches it, so without this watch it would never instantiate and no
    // detector could ever fire. Mirrors the always-on service keepalives above.
    ref.watch(narratorServiceProvider);

    // Get settings
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    final themeSetting = settings?.theme ?? 'dark';
    final textScaleFactor = _getTextScaleFactor(settings?.fontSize ?? 'Medium');
    final uiScaleSetting = settings?.uiScale;
    final theme = resolveSkotiqThemeData(
      themeSetting: themeSetting,
      accentColorHex: settings?.accentColor,
    );

    return StartupAutoConnectLauncher(
      child: AutoDiscoveryLauncher(
        child: QuickStartChecker(
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: systemUiOverlayStyleFor(theme),
            child: MaterialApp.router(
              title: 'Skotiq',
              theme: theme,
              debugShowCheckedModeBanner: false,
              routerConfig: router,
              localizationsDelegates:
                  SkotiqLocalizations.localizationsDelegates,
              supportedLocales: SkotiqLocalizations.supportedLocales,
              locale: _resolveLocale(settings?.language),
              builder: (context, child) {
                // Calculate UI scale factor INSIDE builder where we have proper MediaQuery
                // The outer context doesn't have accurate devicePixelRatio from the window
                final uiScaleFactor = _calculateUiScaleFactor(
                  context,
                  uiScaleSetting,
                );
                final combinedTextScale = textScaleFactor * uiScaleFactor;

                // Scale text only. Flutter handles DPI scaling for the widget
                // tree natively, and a Transform.scale over the whole tree
                // causes rendering artifacts.
                final appChild = child ?? const SizedBox.shrink();
                Widget scaledChild = appChild;

                if (uiScaleFactor != 1.0 || textScaleFactor != 1.0) {
                  // Apply combined text scaling from both UI scale and font size settings
                  // Why: copyWith requires the full MediaQueryData; granular
                  // accessors only return individual fields. This intentionally
                  // rebuilds on any MQ change so that nested widgets receive a
                  // correctly-merged inherited MediaQuery.
                  scaledChild = MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: TextScaler.linear(combinedTextScale),
                    ),
                    child: appChild,
                  );
                }
                // Wrap with ScaledConfigProvider to make responsive scaling
                // configuration available to all descendant widgets. Everything
                // below inherits the app's text scale and theme — putting a
                // launcher's dialog outside this would render it at unscaled
                // size on high-DPI displays.
                //
                // Single-spine startup model (Onboarding & First-Light IA, C13):
                // the launcher stack is now exactly two startup gates, ordered
                // by priority so the higher-priority one always wins the dialog
                // stack:
                //
                //   1. DatabaseRecoveryLauncher — one-shot "your data was reset"
                //      dialog after corruption recovery. Outermost so it fires
                //      before the user is pulled into onboarding for what would
                //      otherwise look like a fresh install.
                //   2. EquipmentOnboardingLauncher — routes a brand-new install
                //      (zero profiles, no onboarding completion record) to the
                //      `/onboarding` spine. This is the *single* entry point for
                //      first-run setup; the spine itself hands off to first
                //      light by routing to `/imaging?firstLight=1` when setup
                //      finishes (see app_router.dart's FirstLightQueryLauncher).
                //
                // The legacy first-launch tour overlay (OnboardingTourLauncher)
                // and the first-night wizard auto-launcher
                // (FirstNightWizardLauncher) were removed from the startup spine:
                // both are now replay-only, reachable from Settings → Help &
                // Tutorials. Collapsing them here means a first-run user follows
                // one linear path (recovery → equipment onboarding → first light)
                // instead of racing overlapping auto-launching dialogs.
                // The site/time card sits INSIDE the startup gates: it is
                // raised by connecting a mount, which cannot happen until the
                // user is past onboarding, and it must never outrank the
                // "your data was reset" dialog.
                Widget result = ScaledConfigProvider(
                  child: AutoIntegrationLauncher(
                    child: DatabaseRecoveryLauncher(
                      child: EquipmentOnboardingLauncher(
                        child: MountSiteReconciliationListener(
                          child: scaledChild,
                        ),
                      ),
                    ),
                  ),
                );

                // Desktop and Android both install Skotiq from its
                // GitHub releases, so both can update in place. (The old
                // reasoning here — that mobile updates through an app store
                // — was never true of this APK: it is sideloaded, so with
                // the manager left off, an Android install had no way to
                // learn a new version existed.) iOS is excluded because
                // sideloading an update is not possible there.
                if (isDesktop || (!kIsWeb && Platform.isAndroid)) {
                  return UpdateManagerWidget(
                    // This builder sits above the router's Navigator; the
                    // update dialogs need the key to reach it.
                    navigatorKey: router.routerDelegate.navigatorKey,
                    child: result,
                  );
                }
                return result;
              },
            ),
          ),
        ),
      ),
    );
  }
}
