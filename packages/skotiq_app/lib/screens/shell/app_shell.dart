import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../../localization/skotiq_localizations.dart';
import '../../utils/startup_surface_coordinator.dart';
import '../../widgets/command_palette/command_palette.dart';
import '../../widgets/onboarding_tour_replay_launcher.dart';
import '../../widgets/tutorial_overlay.dart';
import '../../widgets/mobile_sequence_overlay.dart';
import '../../widgets/running_sequence_mini_bar.dart';
import '../sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../../widgets/notification_toast_overlay.dart';
import '../../widgets/autofocus_progress_overlay.dart';
import '../../widgets/connection_stale_banner.dart';
import '../../widgets/disconnected_backend_banner.dart';
import '../../widgets/ios_background_banner.dart';
import '../../widgets/android_notifications_banner.dart';
import '../../widgets/weather/weather_alert_banner.dart';
import 'widgets/title_bar.dart';
import 'widgets/status_bar.dart';
import 'widgets/side_navigation.dart';
import 'shell_chrome.dart';
import 'shell_navigation.dart';
import 'widgets/skotiq_bottom_navigation.dart';

// Conditional import for window_manager (desktop only)
import 'app_shell_stub.dart' if (dart.library.io) 'app_shell_desktop.dart'
    as window_impl;

part 'app_shell_parts/_startup_checkpoint.dart';
part 'app_shell_parts/_mobile_settings_bar.dart';

/// The location of the route on top of the navigator — the screen the operator
/// is looking at.
///
/// The top-level match list is not the answer. `context.push` of a route that
/// lives inside this ShellRoute folds the pushed match *into* the existing
/// shell match, so the top-level list still ends with the shell, and the
/// shell's own `matchedLocation` is the rail route the push started from.
/// Reading it lights Analytics while the Darkroom is up — the exact claim
/// [_AppShellState._getCurrentIndex] documents as wrong. `lastOrNull` descends
/// through the shell to the leaf match, so a pushed `/darkroom` answers
/// `/darkroom`, the rail lights nothing, and the current-screen provider names
/// the screen that is actually painted.
///
/// An empty match list means the router has resolved nothing yet, which is the
/// state before the first frame; the shell's own start route answers for it.
@visibleForTesting
String topRouteLocation(GoRouter router) {
  return router
          .routerDelegate.currentConfiguration.lastOrNull?.matchedLocation ??
      '/dashboard';
}

class AppShell extends ConsumerStatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool _fallbackSideNavExpanded = true;
  Future<AppStartupCheckpointOutcome>? _checkpointCheck;

  @override
  void initState() {
    super.initState();
    // Initialize window manager if on desktop
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      window_impl.initWindowManager(
        this,
        onCloseRequested: _onCloseRequested,
      );
    }
    // Decide checkpoint recovery before showing any other startup modal.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_runStartupChecks());
    });
  }

  Future<void> _runStartupChecks() {
    return runAppStartupChecks(
      checkCheckpoint: _checkCheckpointIfNeeded,
      // Catalog setup is checklist step 4 on Tonight; no launch-time modal.
      checkCatalogs: () async {},
    );
  }

  /// Handle window close request - show confirmation if needed
  Future<bool> _onCloseRequested() async {
    final sessionState = ref.read(sessionStateProvider);
    final sequenceState = ref.read(sequenceExecutionStateProvider);
    final cameraState = ref.read(cameraStateProvider);
    final mountState = ref.read(mountStateProvider);
    final flatWizardState = ref.read(flatWizardProvider);
    final autofocusState = ref.read(autofocusOverlayProvider);
    final hasActiveOperations = appCloseHasActiveOperations(
      sequenceOwnsHardware: sequenceState.ownsHardware,
      sessionBusy: sessionState.isCapturing ||
          sessionState.isAutofocusing ||
          sessionState.isDithering ||
          sessionState.isGuiding,
      cameraBusy: cameraState.isExposing ||
          cameraState.isCooling ||
          cameraState.isWarming ||
          (cameraState.coolerPower ?? 0) > 2,
      mountBusy: mountState.isSlewing || mountState.isTracking,
      flatWizardBusy: flatWizardState.isCapturing,
      autofocusBusy: autofocusState.isRunning,
    );

    final settingsAsync = ref.read(appSettingsProvider);
    final loadedPreference = settingsAsync.hasValue &&
            !settingsAsync.isLoading &&
            !settingsAsync.hasError
        ? settingsAsync.valueOrNull!.confirmBeforeClosing
        : null;
    if (!appCloseShouldConfirm(
      hasActiveOperations: hasActiveOperations,
      confirmBeforeClosing: loadedPreference,
    )) {
      return _flushEditsBeforeClose();
    }

    // Show confirmation dialog
    final shouldClose = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final colors = SkotiqColors.of(context);
        final l10n = context.l10n;
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            l10n.text('closeSkotiqTitle'),
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            l10n.text('closeSkotiqBody'),
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(false),
              label: l10n.text('cancel'),
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(true),
              label: l10n.text('closeAnyway'),
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
            ),
          ],
        );
      },
    );

    if (shouldClose != true) return false;
    return _flushEditsBeforeClose();
  }

  Future<bool> _flushEditsBeforeClose() async {
    try {
      await ref.read(backendProvider.notifier).prepareForShutdown();
      return true;
    } catch (error) {
      if (!mounted) return false;
      final colors = SkotiqColors.of(context);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            'Latest sequence changes were not saved',
            style: TextStyle(color: colors.textPrimary),
          ),
          content: Text(
            'Skotiq is staying open so your edits are not lost. '
            'Check the database or remote-host connection, then try closing '
            'again.\n\n$error',
            style: TextStyle(color: colors.textSecondary),
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(context).pop(),
              label: 'Keep Skotiq open',
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
            ),
          ],
        ),
      );
      return false;
    }
  }

  @override
  void dispose() {
    // Dispose window manager if on desktop
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      window_impl.disposeWindowManager(this);
    }
    super.dispose();
  }

  Future<AppStartupCheckpointOutcome> _checkCheckpointIfNeeded() {
    return _checkpointCheck ??= _performCheckpointCheck();
  }

  Future<AppStartupCheckpointOutcome> _performCheckpointCheck() async {
    try {
      final backend = ref.read(sequencerBackendProvider);

      // Initialize the checkpoint directory on desktop so checkpoints are
      // actually persisted this session. The desktop GUI never set it, so no
      // checkpoint was ever written and a mid-night crash was unrecoverable
      // (no resume banner, all sequence state lost). Only when this process IS
      // the backend: a remote host owns its own storage layout, and pushing
      // this machine's support directory at it would point the rig's crash
      // recovery at a path that does not exist there.
      //
      // The directory is derived from the OPEN DATABASE, not from the shared
      // application-support folder — see [resolveGuiCheckpointDirectory] for
      // why that distinction is the difference between "your interrupted run"
      // and someone else's.
      final isLocalBackend = backend is! NetworkBackend;
      if (isLocalBackend &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
        try {
          final checkpointDir = await resolveGuiCheckpointDirectory();
          // Configure first, adopt second: nothing reads the directory until
          // hasCheckpoint() below, and a slow or failing adoption must not be
          // able to leave tonight's run with no checkpoint directory at all.
          await backend.sequencerSetCheckpointDir(checkpointDir.path);
          await adoptLegacyGuiCheckpoint(targetDir: checkpointDir);
        } catch (e) {
          ref.read(loggingServiceProvider).warning(
              '[AppShell] Failed to initialize checkpoint directory: $e',
              source: 'AppShell',
              fields: {'error': e.toString()});
        }
      }

      final hasCheckpoint = await backend.hasCheckpoint();
      if (!hasCheckpoint) return AppStartupCheckpointOutcome.noRecovery;

      final info = await backend.getCheckpointInfo();
      if (info == null || !info.canResume) {
        return AppStartupCheckpointOutcome.noRecovery;
      }

      if (!mounted) return AppStartupCheckpointOutcome.failed;

      return ref.read(startupSurfaceCoordinatorProvider).run(
            () => runAppCheckpointRecovery(
              choose: (lastFailure) async {
                if (!mounted) return null;
                return showDialog<AppCheckpointRecoveryChoice>(
                  context: context,
                  barrierDismissible: false,
                  builder: (dialogContext) => buildCheckpointRecoveryDialog(
                    context: dialogContext,
                    info: info,
                    failure: lastFailure,
                  ),
                );
              },
              checkpointStillResumable: () async {
                final current = await backend.getCheckpointInfo();
                return current?.canResume ?? false;
              },
              // Route through the SequenceExecutor provider — it re-seeds the
              // runtime config and starts the restored native tree. The raw backend
              // resume only prepares that tree and would leave execution idle.
              resume: () =>
                  ref.read(sequenceExecutorProvider).resumeFromCheckpoint(),
              discard: backend.discardCheckpoint,
            ),
          );
    } catch (e) {
      ref.read(loggingServiceProvider).error(
          '[AppShell] Error checking checkpoint: $e',
          source: 'AppShell',
          fields: {'error': e.toString()});
      return AppStartupCheckpointOutcome.failed;
    }
  }

  String _getCurrentLocation(BuildContext context) {
    try {
      return topRouteLocation(GoRouter.of(context));
    } catch (_) {
      return '/dashboard';
    }
  }

  int _getCurrentIndex(BuildContext context) {
    final location = _getCurrentLocation(context);

    // Update current screen provider for smart notifications
    // Use Future.microtask to avoid modification during build
    final screen = locationToAppScreen(location);
    Future.microtask(() {
      if (mounted) {
        ref.read(currentScreenProvider.notifier).state = screen;
      }
    });

    // -1 = nothing highlighted, which is the correct answer for every route no
    // rail destination hosts: Settings (+ its plate-solving child), Polar
    // Alignment, Tonight, the Flat Wizard, the mosaic / session-review /
    // stack-result viewers and /diagnostics/dump. Defaulting to 0 lights
    // Dashboard on all of them, so the rail claims the operator is on a screen
    // they are not. Sub-routes resolve to their HOST (/imaging/preview/:id
    // lights Imaging).
    return ShellNavigation.primaryIndexForLocation(location);
  }

  void _onTabSelected(int index, BuildContext context) {
    final route = ShellNavigation.primaryRouteForIndex(index);
    if (route == null) return;
    try {
      context.go(route);
    } catch (e, stack) {
      // A tab that does not move is indistinguishable from a tab that moved
      // and rendered the same thing, so the failure is logged rather than
      // absorbed: without this the only symptom is an unresponsive tab.
      developer.log(
        '[AppShell] Tab $index could not navigate to $route: $e',
        name: 'AppShell',
        level: 900,
        error: e,
        stackTrace: stack,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // One bool, not the whole settings object: the shell is the root of every
    // routed screen, so watching all of `appSettingsProvider` rebuilt the nav,
    // the status bar, the mini-player and the routed child's element tree on
    // every settings toggle, autosave and remote settings push.
    final sidebarCollapsed = ref.watch(
      appSettingsProvider.select((s) => s.valueOrNull?.sidebarCollapsed),
    );
    final currentLocation = _getCurrentLocation(context);
    final currentIndex = _getCurrentIndex(context);

    // Activate the error notification bridge so backend errors show as toast notifications
    ref.watch(errorNotificationBridgeProvider);
    // Why: keep the meridian-flip disconnect guard alive
    // for the shell's lifetime so a mount disconnect during an in-flight flip
    // resets `flipExecutionStateProvider` to `aborted` and unsticks the UI.
    ref.watch(meridianFlipDisconnectGuardProvider);
    // Why: the standalone meridian monitor must be kept
    // alive while the shell is mounted so the Sequencer Settings ->
    // "Standalone monitoring" toggle actually does something — when enabled,
    // it polls mount HA against the configured trigger and alerts the
    // operator when the meridian is crossed outside of a sequence run.
    ref.watch(meridianFlipStandaloneMonitorProvider);
    // Scheduler lifetime: keep auto-reevaluation listeners mounted
    // with the shell, not only while Plan Tonight -> Target Queue is visible.
    // Otherwise target/goals/constraint edits made elsewhere can stop waking
    // the scheduler once the operator navigates away from that tab.
    ref.watch(schedulerAutoReevalProvider);
    // Keep the longitude-baton scheduler mounted for the shell's lifetime so a
    // co-imaging session hands the night east on the rise/set even while the
    // operator is on another tab. Lazy otherwise, so this
    // read is what makes it tick in the GUI (the headless host eager-reads it in
    // main_headless). No-op until a session is joined and a site is configured.
    ref.watch(coImagingBatonSchedulerProvider);
    final isSideNavExpanded =
        sidebarCollapsed != null ? !sidebarCollapsed : _fallbackSideNavExpanded;

    return LayoutBuilder(
      builder: (context, constraints) {
        final useBottomNav =
            ShellChrome.useBottomNavigation(constraints.maxWidth);
        // The shell Scaffold owns IME resizing. If its fixed gear strip,
        // status bar, mini-player and bottom navigation remain mounted while a
        // landscape keyboard is open, they can consume the entire shrunken
        // body before the focused route gets any height. Keyboard interaction
        // is already a modal navigation context, so temporarily reclaim that
        // chrome and restore it unchanged when the IME closes.
        final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;

        // The first-launch tour is replay-only: OnboardingTourReplayLauncher
        // watches firstLaunchTourStatusProvider and overlays OnboardingOverlay on
        // top of the whole shell when the user re-runs it from Settings → Help.
        // Mounted at the shell level so the spotlight cutouts can target the
        // live side-navigation TutorialKeys.
        final Widget shell = OnboardingTourReplayLauncher(
          child: TutorialOverlay(
            // Ctrl/Cmd+K anywhere in the shell. BOTH activators are bound
            // rather than one chosen from the platform: a Mac with an external
            // PC keyboard sends Control, and an operator who has learned one of
            // the two should not have the app decide which one their keyboard
            // is allowed to send.
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                    () => showCommandPalette(context),
                const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                    () => showCommandPalette(context),
              },
              child: Scaffold(
                backgroundColor: colors.background,
                body: Column(
                  children: [
                    // Desktop title bar (window drag + global actions). Hidden on
                    // mobile — bottom nav covers primary routes; saves vertical space.
                    if (!useBottomNav) const TitleBar(),

                    // Mobile gear strip. Settings left the bottom bar in the
                    // six-tab consolidation, so this thin app-bar action keeps it
                    // one tap away on phones.
                    if (useBottomNav && !keyboardVisible)
                      SafeArea(
                        bottom: false,
                        child: _MobileSettingsBar(
                          onOpenSettings: () => context.go('/settings'),
                        ),
                      ),

                    // Desktop keeps the full recovery banner; mobile uses the
                    // compact status-bar connection indicator.
                    if (!useBottomNav) const DisconnectedBackendBanner(),

                    // iOS background-monitoring advisory. Renders
                    // above the weather banner so it's the first thing the
                    // operator sees while a sequence is running on iOS.
                    const IosBackgroundBanner(),

                    // Android POST_NOTIFICATIONS advisory. Visible
                    // whenever the runtime permission is denied on Android 13+
                    // so the operator knows sequence/safety alerts will not
                    // wake them and points to System Settings.
                    const AndroidNotificationsBanner(),

                    // Stale-connection advisory. Visible during
                    // the WS reconnect grace window so the operator knows
                    // controls may be momentarily out of date.
                    const ConnectionStaleBanner(),

                    // Weather Alert Banner
                    const WeatherAlertBanner(),

                    // Main content
                    Expanded(
                      child: Row(
                        children: [
                          // Side navigation (Desktop only)
                          if (!useBottomNav)
                            SideNavigation(
                              key: TutorialKeys.sideNavigation,
                              // Positional, so it tracks the rail order in
                              // ShellNavigation.primaryDestinations (04 §3.2):
                              // Tonight, Imaging, Sequencer, Guiding | Plan,
                              // Equipment, Weather | Darkroom, Analytics.
                              tutorialKeys: [
                                TutorialKeys.navDashboard,
                                TutorialKeys.navImaging,
                                TutorialKeys.navSequencer,
                                TutorialKeys.navGuiding,
                                TutorialKeys.navPlanner,
                                TutorialKeys.navEquipment,
                                null,
                                null,
                                TutorialKeys.navAnalytics,
                              ],
                              currentIndex: currentIndex,
                              onTabSelected: (index) =>
                                  _onTabSelected(index, context),
                              isExpanded: isSideNavExpanded,
                              onToggleExpanded: () {
                                final currentSettings =
                                    ref.read(appSettingsProvider).valueOrNull;
                                if (currentSettings != null) {
                                  ref
                                      .read(appSettingsProvider.notifier)
                                      .setSidebarCollapsed(
                                          !currentSettings.sidebarCollapsed);
                                } else {
                                  setState(() {
                                    _fallbackSideNavExpanded =
                                        !_fallbackSideNavExpanded;
                                  });
                                }
                              },
                            ),

                          // The page body. `background`-toned like the rail
                          // and the top bar; the rail draws the hairline
                          // between them on its own trailing edge, so the
                          // body no longer paints a second one on its leading
                          // edge over the top of it (04 §1: one hairline
                          // right of the rail, not two abutting).
                          Expanded(
                            child: ColoredBox(
                              color: colors.background,
                              child: Stack(
                                children: [
                                  // Both chromes own the top inset above this
                                  // content: desktop via the TitleBar, mobile via
                                  // the gear strip, so the content never re-insets
                                  // the notch/status-bar edge itself.
                                  SafeArea(
                                    top: false,
                                    bottom: false,
                                    child: _ContentSemanticsBoundary(
                                      child: widget.child,
                                    ),
                                  ),
                                  // Mobile sequence overlay (only on mobile and
                                  // sequencer screen). Gated on the shared route
                                  // constant instead of a literal string so the
                                  // router and this check stay in sync. The
                                  // app-wide running-sequence mini-player (run
                                  // controls reachable off the sequencer route)
                                  // lives in the bottom chrome below as
                                  // [RunningSequenceMiniBar].
                                  if (useBottomNav &&
                                      currentLocation.split('?').first ==
                                          kSequencerRoutePath)
                                    const MobileSequenceOverlay(),
                                  // Autofocus progress overlay
                                  const AutofocusProgressOverlay(),
                                  // Toast notifications - always on top
                                  const NotificationToastOverlay(),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // App-wide running-sequence mini-player. Persistent across
                    // every route so pause/stop/skip stay reachable after the
                    // operator navigates away from the sequencer mid-run; it
                    // self-hides on the sequencer route (full controls live there)
                    // and whenever no sequence is active. Sits just above the
                    // bottom chrome so it reads as part of the persistent
                    // run-control surface.
                    if (!keyboardVisible)
                      RunningSequenceMiniBar(currentLocation: currentLocation),

                    // Bottom chrome. On phone the bottom nav auto-hides when
                    // idle so it reclaims the short cover-screen height; on
                    // desktop the instrument bar is pinned and navigation is
                    // the rail.
                    //
                    // The narrow shell carries NO instrument bar (04 §5). The
                    // compact one used to sit above the nav, which spent 40px
                    // of a 640px-tall phone restating what the device pills on
                    // Tonight already said, and pushed the bar the operator
                    // navigates with further from their thumb.
                    //
                    // The nav does NOT hide. It used to sit under an
                    // always-visible grabber handle that collapsed it behind a
                    // "Menu" pill, on every narrow screen — 04 §3.3 gives the
                    // narrow shell a bottom nav, and a sheet's grabber belongs
                    // to the sheet (Imaging's controls), not to the shell.
                    // Below 768px the nav IS the navigation, and an affordance
                    // that takes it away is one an operator can only lose by.
                    if (useBottomNav && !keyboardVisible)
                      SkotiqBottomNavigation(
                        currentRoute: currentLocation,
                        onRouteSelected: (route) {
                          try {
                            context.go(route);
                          } catch (e, stack) {
                            developer.log(
                              '[AppShell] Bottom nav could not navigate '
                              'to $route: $e',
                              name: 'AppShell',
                              level: 900,
                              error: e,
                              stackTrace: stack,
                            );
                          }
                        },
                      )
                    else if (!useBottomNav)
                      const StatusBar(),
                  ],
                ),
              ),
            ),
          ),
        );

        if (!useBottomNav) return shell;
        // Dynamic UI shrink for phones: scale text down as the screen's short
        // side falls below a ~440px reference so dense cover screens (e.g. a
        // foldable ~369px) fit more without manual zoom. Multiplies (respects)
        // the user's own accessibility text scaling. Tablets (short side >=
        // 440) and desktop are unscaled.
        final mq = MediaQuery.of(context);
        final uiScale = (mq.size.shortestSide / 440.0).clamp(0.82, 1.0);
        // System-back policy (phone): primary tabs are go()-navigated, so the
        // router usually has nothing to pop and a bare back gesture would
        // finish the Activity from ANY screen. Order: a screen-registered
        // interceptor (e.g. Settings' detail pane) → pop a pushed route
        // (Flat Wizard, mosaic detail…) → return to Dashboard (Material
        // back-to-home convention) → only from Dashboard leave the app.
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (ShellBackDispatcher.dispatch()) return;
            final router = GoRouter.of(context);
            if (router.canPop()) {
              router.pop();
              return;
            }
            if (!_getCurrentLocation(context).startsWith('/dashboard')) {
              context.go('/dashboard');
              return;
            }
            SystemNavigator.pop();
          },
          child: MediaQuery(
            data: mq.copyWith(
              textScaler: TextScaler.linear(mq.textScaler.scale(1.0) * uiScale),
            ),
            child: shell,
          ),
        );
      },
    );
  }
}

/// Stops a routed page's modal barrier from erasing the shell chrome from the
/// accessibility tree.
///
/// [child] is the nested `Navigator` that go_router's `ShellRoute` hands the
/// shell. Every route it holds is a `ModalRoute`, and a `ModalRoute`'s first
/// overlay entry is a `ModalBarrier`, which is a `BlockSemantics` — it sets
/// `isBlockingSemanticsOfPreviouslyPaintedNodes`, and Flutter propagates that
/// "drop everything painted before me" flag UP through every ancestor render
/// object that is not itself a semantics boundary. Unbounded, it escaped the
/// overlay, the navigator and this content column, wiped the [SideNavigation]
/// out of the shell Row and then the [TitleBar] out of the shell Column: on
/// the Linux bundle the AT-SPI tree carried the routed screen and the status
/// bar but not one rail destination, not Collapse and not one title-bar
/// action, so assistive tech could not reach Settings or any other desktop
/// entry point. The phone chrome lost its gear strip the same way, and kept
/// its bottom bar only because that paints after the content.
///
/// `container: true` is the load-bearing flag: it makes this an explicit
/// semantics boundary, which is where the upward propagation stops. Modals
/// that SHOULD hide the chrome are unaffected — `showDialog` defaults to the
/// root navigator, whose barrier paints above the whole shell and blocks it
/// from outside this boundary.
class _ContentSemanticsBoundary extends StatelessWidget {
  final Widget child;

  const _ContentSemanticsBoundary({required this.child});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: child,
    );
  }
}
