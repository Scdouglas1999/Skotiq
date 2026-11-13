import 'widgets/mount/mount_site_reconciliation_card.dart';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/widgets/quick_start_checker.dart';
import 'package:skotiq_app/widgets/update/update_manager_widget.dart';
import 'package:skotiq_app/widgets/your_sky_off_notice.dart';
import 'package:skotiq_app/widgets/red_night_filter.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_app/startup/startup_surface_queue.dart';
import 'package:skotiq_app/widgets/database_recovery_launcher.dart';
import 'package:skotiq_app/widgets/equipment_onboarding_launcher.dart';
import 'package:skotiq_app/widgets/night_end_toasts.dart';

class SkotiqApp extends ConsumerWidget {
  final bool isDesktop;

  /// Always-on services that live in the app embedding this one (the phone
  /// app's platform integrations), started with the shared ones.
  final List<AlwaysOnService> platformServices;

  const SkotiqApp({
    this.isDesktop = false,
    this.platformServices = const [],
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

    return AlwaysOnServicesScope(
      role: isDesktop
          ? (ref.watch(remoteClientLaunchProvider)
              ? AppRole.linkedClient
              : AppRole.hostGui)
          : AppRole.mobile,
      platformServices: platformServices,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemUiOverlayStyleFor(theme),
        child: MaterialApp.router(
          title: 'Skotiq',
          theme: theme,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
          localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
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
            // Everything below inherits the app's text scale and theme;
            // a prompt raised from outside this builder would render
            // unscaled on high-DPI displays.
            Widget result = StartupPrompts(child: scaledChild);

            // Desktop and Android both install Skotiq from its
            // GitHub releases, so both can update in place. (The old
            // reasoning here — that mobile updates through an app store
            // — was never true of this APK: it is sideloaded, so with
            // the manager left off, an Android install had no way to
            // learn a new version existed.) iOS is excluded because
            // sideloading an update is not possible there.
            if (isDesktop || (!kIsWeb && Platform.isAndroid)) {
              result = UpdateManagerWidget(
                // This builder sits above the router's Navigator; the
                // update dialogs need the key to reach it.
                navigatorKey: router.routerDelegate.navigatorKey,
                child: result,
              );
            }
            return RedNightScreen(child: result);
          },
        ),
      ),
    );
  }
}

/// The widgets that raise a prompt by themselves, at launch or on an event.
///
/// Their order here does not matter. What the user sees first is decided by
/// [StartupSurface]: each launcher takes its turn in the
/// [StartupSurfaceQueue], so a new install is led through one path (data
/// reset notice, interrupted run, interrupted session, previous setup,
/// equipment setup) with one prompt on screen at a time.
class StartupPrompts extends StatelessWidget {
  const StartupPrompts({super.key, required this.child});

  final Widget child;

  static final List<Widget Function(Widget child)> _launchers = [
    (child) => DatabaseRecoveryLauncher(child: child),
    (child) => QuickStartChecker(child: child),
    (child) => EquipmentOnboardingLauncher(child: child),
    (child) => YourSkyOffNoticeChecker(child: child),
    (child) => MountSiteReconciliationListener(child: child),
    (child) => NightEndToasts(child: child),
  ];

  @override
  Widget build(BuildContext context) =>
      _launchers.fold(child, (inner, wrap) => wrap(inner));
}

/// Runs the always-on services of [role] for as long as the app is mounted.
class AlwaysOnServicesScope extends ConsumerStatefulWidget {
  const AlwaysOnServicesScope({
    super.key,
    required this.role,
    required this.child,
    this.platformServices = const [],
  });

  final AppRole role;
  final List<AlwaysOnService> platformServices;
  final Widget child;

  @override
  ConsumerState<AlwaysOnServicesScope> createState() =>
      _AlwaysOnServicesScopeState();
}

class _AlwaysOnServicesScopeState extends ConsumerState<AlwaysOnServicesScope> {
  late final AlwaysOnServices _services;

  @override
  void initState() {
    super.initState();
    _services = startAlwaysOnServices(
      ProviderScope.containerOf(context, listen: false),
      widget.role,
      platformServices: widget.platformServices,
    );
  }

  @override
  void dispose() {
    _services.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
