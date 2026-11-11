import 'dart:async';
import '../../utils/snackbar_helper.dart';
import 'dart:developer' as developer;
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, SystemNavigator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../../localization/skotiq_localizations.dart';
import '../../startup/startup_surface_queue.dart';
import '../../widgets/command_palette/command_palette.dart';
import '../../widgets/onboarding_tour_replay_launcher.dart';
import '../../widgets/tutorial_overlay.dart';
import '../../widgets/mobile_sequence_overlay.dart';
import '../../widgets/running_sequence_mini_bar.dart';
import '../night_control/night_control_screen.dart' show isTonightLocation;
import '../sequencer/sequencer_screen.dart' show kSequencerRoutePath;
import '../../widgets/notification_toast_overlay.dart';
import '../../widgets/autofocus_progress_overlay.dart';
import '../../widgets/polar_alignment_run_overlay.dart';
import '../../widgets/connection_stale_banner.dart';
import '../../widgets/disconnected_backend_banner.dart';
import '../../widgets/ios_background_banner.dart';
import '../../widgets/android_notifications_banner.dart';
import '../../widgets/weather/weather_alert_banner.dart';
import '../../widgets/startup_splash_gate.dart';
import 'widgets/window_chrome.dart';
import 'widgets/side_navigation.dart';
import 'shell_chrome.dart';
import 'shell_navigation.dart';
import 'widgets/skotiq_bottom_navigation.dart';

// Conditional import for window_manager (desktop only)
import 'app_shell_stub.dart' if (dart.library.io) 'app_shell_desktop.dart'
    as window_impl;
import '../settings/settings_sections.dart';

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
  late final StartupSurfaceQueue _startupQueue;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      window_impl.initWindowManager(
        this,
        onCloseRequested: _onCloseRequested,
      );
    }
    _startupQueue = ref.read(startupSurfaceQueueProvider)
      ..expect(StartupSurface.checkpointRecovery);
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
            'again.\n\n${userFacingError(error)}',
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
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      window_impl.disposeWindowManager(this);
    }
    _startupQueue.pass(StartupSurface.checkpointRecovery);
    super.dispose();
  }

  Future<AppStartupCheckpointOutcome> _checkCheckpointIfNeeded() {
    return _checkpointCheck ??= _performCheckpointCheck().whenComplete(() {
      _startupQueue.pass(StartupSurface.checkpointRecovery);
    }).then((outcome) async {
      // After the checkpoint prompt: a run it restored has loaded its own
      // plan, and the open plan only fills an empty editor.
      await _restoreOpenPlan();
      return outcome;
    });
  }

  /// Put back the plan that was open in the editor when Skotiq last stopped,
  /// and say so when it carries edits that were never saved.
  Future<void> _restoreOpenPlan() async {
    if (!mounted) return;
    // The container outlives this shell; the restore can finish after it.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      final restored = await restoreOpenPlan(container.read);
      if (restored == null || !restored.unsaved || !mounted) return;
      context.showInfoSnackBar(
        'Restored "${restored.sequence.name}", the plan you were editing '
        'when Skotiq last closed. It is not saved yet.',
      );
    } catch (e) {
      container.read(loggingServiceProvider).warning(
            'Could not restore the open plan: $e',
            source: 'AppShell',
          );
    }
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
      final isLocalBackend = backend.remoteHost == null;
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

      if (await hostRunHoldsCheckpoint(backend)) {
        return AppStartupCheckpointOutcome.noRecovery;
      }

      final hasCheckpoint = await backend.hasCheckpoint();
      if (!hasCheckpoint) return AppStartupCheckpointOutcome.noRecovery;

      final info = await backend.getCheckpointInfo();
      // Only a run the app died under is offered here. A run that was
      // stopped, failed or ended early keeps its checkpoint and is continued
      // from History, not raised as an interruption at every launch.
      if (info == null || !offersCheckpointRecovery(info)) {
        return AppStartupCheckpointOutcome.noRecovery;
      }

      if (!mounted) return AppStartupCheckpointOutcome.failed;

      return _startupQueue.turn(
        StartupSurface.checkpointRecovery,
        () => _answeringCheckpointPrompt(() => runAppCheckpointRecovery(
              choose: (lastFailure) async {
                if (!mounted) return null;
                // A linked client asks again when the prompt's turn comes:
                // the host may have started a run while other startup
                // prompts were up, and its checkpoint is then that run's.
                if (await hostRunHoldsCheckpoint(backend)) {
                  return AppCheckpointRecoveryChoice.later;
                }
                if (!mounted) return null;
                final remoteHost = backend.remoteHost?.link.serverHost;
                BuildContext? dialogContext;
                // The prompt describes the checkpoint at the moment it
                // opened. Once a run starts (on a linked client: on the host)
                // the checkpoint is that run's, so the prompt closes itself
                // and leaves it alone: Discard would delete the live run's
                // resume point.
                final hostRun = ref.listenManual<SequenceExecutionState>(
                  sequenceExecutionStateProvider,
                  (_, next) {
                    final open = dialogContext;
                    if (!next.canStart && open != null && open.mounted) {
                      Navigator.of(open).pop(
                        AppCheckpointRecoveryChoice.later,
                      );
                    }
                  },
                );
                try {
                  return await showDialog<AppCheckpointRecoveryChoice>(
                    context: context,
                    barrierDismissible: false,
                    builder: (routeContext) {
                      dialogContext = routeContext;
                      return buildCheckpointRecoveryDialog(
                        context: routeContext,
                        info: info,
                        failure: lastFailure,
                        remoteHost: remoteHost,
                      );
                    },
                  );
                } finally {
                  hostRun.close();
                }
              },
              checkpointStillResumable: () async {
                final current = await backend.getCheckpointInfo();
                return current?.canResume ?? false;
              },
              // Restore only: the run is loaded with its progress and waits
              // for the operator's Start. Nothing executes from this dialog.
              resume: () =>
                  ref.read(sequenceExecutorProvider).restoreFromCheckpoint(),
              discard: backend.discardCheckpoint,
            )),
      );
    } catch (e) {
      ref.read(loggingServiceProvider).error(
          '[AppShell] Error checking checkpoint: $e',
          source: 'AppShell',
          fields: {'error': e.toString()});
      return AppStartupCheckpointOutcome.failed;
    }
  }

  /// Runs the checkpoint prompt and tells the start-up queue when the
  /// operator settled the interrupted run in it, so Quick Start does not ask
  /// about the same run again.
  Future<AppStartupCheckpointOutcome> _answeringCheckpointPrompt(
    Future<AppStartupCheckpointOutcome> Function() prompt,
  ) async {
    final outcome = await prompt();
    if (outcome == AppStartupCheckpointOutcome.resumed ||
        outcome == AppStartupCheckpointOutcome.discarded) {
      _startupQueue.answered(StartupSurface.checkpointRecovery);
    }
    return outcome;
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
    // The brand splash covers the shell until the first settings read
    // resolves — the same "startup is done" signal the rest of the app
    // waits on — then hands off with a short fade. Watching only the
    // loading flag keeps the "shell rebuilds on any settings write"
    // regression test honest.
    final startupReady = !ref.watch(
      appSettingsProvider.select((s) => s.isLoading),
    );
    final currentLocation = _getCurrentLocation(context);
    final currentIndex = _getCurrentIndex(context);

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
        // The splash wraps the shell's content rather than the Navigator so
        // routes pushed during startup — checkpoint recovery, onboarding,
        // update prompts — paint above it and stay interactive.
        final Widget shell = SkotiqSplashGate(
          ready: startupReady,
          child: OnboardingTourReplayLauncher(
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
                  // Focus order is the reading order of the glass: the sidebar
                  // first (the app's own controls), then the page it governs,
                  // then the window controls — the part that belongs to the
                  // window, not to the app.
                  body: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Stack(
                      children: [
                        Column(
                          children: [
                            // Mobile gear strip. Settings left the bottom bar
                            // in the six-tab consolidation, so this thin
                            // app-bar action keeps it one tap away on phones.
                            if (useBottomNav && !keyboardVisible)
                              SafeArea(
                                bottom: false,
                                child: _MobileSettingsBar(
                                  onOpenSettings: () => openSettings(context),
                                ),
                              ),

                            Expanded(
                              child: Row(
                                children: [
                                  // The sidebar (desktop only) — a
                                  // full-height pane of the slate: chrome
                                  // header, destinations, Rig card.
                                  if (!useBottomNav)
                                    FocusTraversalOrder(
                                      order: const NumericFocusOrder(0),
                                      child: SideNavigation(
                                        key: TutorialKeys.sideNavigation,
                                        // Positional, so it tracks the rail
                                        // order in ShellNavigation
                                        // .primaryDestinations (04 §3.2):
                                        // Tonight, Imaging, Sequencer,
                                        // Guiding | Plan, Equipment, Flat wizard, Weather
                                        // | Darkroom, Analytics.
                                        tutorialKeys: [
                                          TutorialKeys.navDashboard,
                                          TutorialKeys.navImaging,
                                          TutorialKeys.navSequencer,
                                          TutorialKeys.navGuiding,
                                          TutorialKeys.navPlanner,
                                          TutorialKeys.navEquipment,
                                          null,
                                          null,
                                          null,
                                          TutorialKeys.navAnalytics,
                                        ],
                                        currentIndex: currentIndex,
                                        onTabSelected: (index) =>
                                            _onTabSelected(index, context),
                                        isExpanded: isSideNavExpanded,
                                        onToggleExpanded: () {
                                          final currentSettings = ref
                                              .read(appSettingsProvider)
                                              .valueOrNull;
                                          if (currentSettings != null) {
                                            ref
                                                .read(
                                                  appSettingsProvider.notifier,
                                                )
                                                .setSidebarCollapsed(
                                                  !currentSettings
                                                      .sidebarCollapsed,
                                                );
                                          } else {
                                            setState(() {
                                              _fallbackSideNavExpanded =
                                                  !_fallbackSideNavExpanded;
                                            });
                                          }
                                        },
                                      ),
                                    ),

                                  // The page's pane: the top band, the
                                  // banners, the routed content.
                                  Expanded(
                                    child: FocusTraversalOrder(
                                      order: const NumericFocusOrder(1),
                                      child: Column(
                                        children: [
                                          // The window's top edge: clock and
                                          // LST, the global actions, then the
                                          // window controls. Its empty space
                                          // drags the window.
                                          if (!useBottomNav)
                                            const ShellTopBand(),

                                          // Desktop keeps the full recovery
                                          // banner; mobile uses the compact
                                          // connection indicator.
                                          if (!useBottomNav)
                                            const DisconnectedBackendBanner(),

                                          const IosBackgroundBanner(),

                                          const AndroidNotificationsBanner(),

                                          const ConnectionStaleBanner(),

                                          const WeatherAlertBanner(),

                                          Expanded(
                                            child: ColoredBox(
                                              color: colors.background,
                                              child: Stack(
                                                children: [
                                                  // Both chromes own the top
                                                  // inset above this content:
                                                  // desktop via the top band,
                                                  // mobile via the gear
                                                  // strip, so the content
                                                  // never re-insets the
                                                  // notch/status-bar edge
                                                  // itself.
                                                  SafeArea(
                                                    top: false,
                                                    bottom: false,
                                                    child:
                                                        _ContentSemanticsBoundary(
                                                      child: HostLinkStaleScope(
                                                        child: widget.child,
                                                      ),
                                                    ),
                                                  ),
                                                  // Mobile sequence overlay
                                                  // (only on mobile and the
                                                  // sequencer screen). Gated
                                                  // on the shared route
                                                  // constant instead of a
                                                  // literal string so the
                                                  // router and this check
                                                  // stay in sync.
                                                  if (useBottomNav &&
                                                      currentLocation
                                                              .split('?')
                                                              .first ==
                                                          kSequencerRoutePath)
                                                    const MobileSequenceOverlay(),
                                                  // Autofocus progress
                                                  // overlay. Tonight shows
                                                  // the run in its Focus
                                                  // tab and on the frame.
                                                  if (!isTonightLocation(
                                                    currentLocation,
                                                  ))
                                                    const AutofocusProgressOverlay(),
                                                  // A live polar alignment,
                                                  // on every screen but its
                                                  // own, however it started.
                                                  if (currentLocation
                                                          .split('?')
                                                          .first !=
                                                      kPolarAlignmentRoutePath)
                                                    const PolarAlignmentRunOverlay(),
                                                  // Toast notifications -
                                                  // always on top
                                                  const NotificationToastOverlay(),
                                                ],
                                              ),
                                            ),
                                          ),

                                          // App-wide running-sequence
                                          // mini-player. Persistent across
                                          // every route so pause/stop/skip
                                          // stay reachable after the operator
                                          // navigates away from the sequencer
                                          // mid-run; it self-hides on the
                                          // sequencer route (full controls
                                          // live there) and whenever no
                                          // sequence is active. On desktop it
                                          // sits at the bottom of the main
                                          // pane — the sidebar runs the full
                                          // window height, so nothing spans
                                          // the window's foot any more.
                                          if (!keyboardVisible)
                                            RunningSequenceMiniBar(
                                              currentLocation: currentLocation,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Bottom chrome. On phone the bottom nav
                            // auto-hides when idle so it reclaims the short
                            // cover-screen height.
                            //
                            // The narrow shell carries NO status bar. The nav
                            // does NOT hide: below 768px the nav IS the
                            // navigation, and an affordance that takes it
                            // away is one an operator can only lose by.
                            if (useBottomNav && !keyboardVisible)
                              SkotiqBottomNavigation(
                                currentRoute: currentLocation,
                                onRouteSelected: (route) {
                                  try {
                                    context.go(route);
                                  } catch (e, stack) {
                                    developer.log(
                                      '[AppShell] Bottom nav could not '
                                      'navigate to $route: $e',
                                      name: 'AppShell',
                                      level: 900,
                                      error: e,
                                      stackTrace: stack,
                                    );
                                  }
                                },
                              ),
                          ],
                        ),

                        // The window's own 1 px edge, drawn by the app on
                        // Linux where nothing else draws one — about 9% of
                        // the theme's ink, so red night gets a red-tinted
                        // edge rather than a white one. Gated on the chrome
                        // state: a maximized or full-screen window has no
                        // free edge to outline.
                        if (!kIsWebLike &&
                            Platform.isLinux &&
                            ShellChrome.isDesktopWindow)
                          const Positioned.fill(child: WindowEdgeHairline()),
                      ],
                    ),
                  ),
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
/// out of the shell Row and then the [ShellTopBand] out of the shell Column:
/// on the Linux bundle the AT-SPI tree carried the routed screen and the
/// status strip but not one rail destination, not Collapse and not one
/// top-band action, so assistive tech could not reach Settings or any other
/// desktop
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
