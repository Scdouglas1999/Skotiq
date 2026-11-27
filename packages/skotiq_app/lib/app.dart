import 'startup/fujifilm_notice_after_connect.dart';
import 'startup/mount_site_reconciliation_card.dart';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/startup/quick_start_checker.dart';
import 'package:skotiq_app/startup/update/update_manager_widget.dart';
import 'package:skotiq_app/startup/your_sky_off_notice.dart';
import 'package:skotiq_app/app_frame.dart';
import 'package:skotiq_app/startup/always_on_services.dart';
import 'package:skotiq_app/utils/startup_surface_queue.dart';
import 'package:skotiq_app/startup/database_recovery_launcher.dart';
import 'package:skotiq_app/startup/equipment_onboarding_launcher.dart';
import 'package:skotiq_app/startup/night_end_toasts.dart';

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    final look = SkotiqAppLook(ref.watch(appSettingsProvider).valueOrNull);
    final theme = look.theme;

    return AlwaysOnServicesScope(
      role: ref.watch(launchRoleProvider),
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
          locale: look.locale,
          builder: (context, child) {
            final scaledChild =
                look.scaled(context, child ?? const SizedBox.shrink());
            // Everything below inherits the app's text scale and theme;
            // a prompt raised from outside this builder would render
            // unscaled on high-DPI displays.
            Widget result = StartupPrompts(child: scaledChild);

            // Desktop and Android both install Skotiq from its GitHub
            // releases (the APK is sideloaded, not from a store), so both
            // can update in place. iOS cannot sideload an update.
            if (isDesktop || (!kIsWeb && Platform.isAndroid)) {
              result = UpdateManagerWidget(
                // This builder sits above the router's Navigator; the
                // update dialogs need the key to reach it.
                navigatorKey: router.routerDelegate.navigatorKey,
                child: result,
              );
            }
            return skotiqAppFrame(result);
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
    (child) => FujifilmNoticeAfterConnect(child: child),
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

  final LaunchRole role;
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
