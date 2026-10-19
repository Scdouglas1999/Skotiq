import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'tutorial_keys/tutorial_keys.dart';
import 'tutorial_overlay/tutorial_routes.dart';

export 'tutorial_overlay/tutorial_routes.dart' show tutorialRouteForStep;

part 'tutorial_overlay/content.dart';
part 'tutorial_overlay/spotlight.dart';
part 'tutorial_overlay/tooltip.dart';

/// Spotlight shape for tutorial highlighting
/// This is defined locally in case the model hasn't been updated yet.
/// Once tutorial_models.dart has SpotlightShape, this can be removed
/// and the import used instead.
enum SpotlightShape {
  /// Circular spotlight - ideal for icons and circular buttons
  circle,

  /// Rounded rectangle - default shape for most UI elements
  roundedRect,

  /// Pill/capsule shape - horizontal oval for text buttons and labels
  pill,
}

/// Global keys for tutorial targets
class TutorialKeys {
  // Navigation keys (used by multiple tutorials)
  static final sideNavigation = GlobalKey(debugLabel: 'side_navigation');
  static final navDashboard = GlobalKey(debugLabel: 'nav_dashboard');
  static final navEquipment = GlobalKey(debugLabel: 'nav_equipment');
  static final navImaging = GlobalKey(debugLabel: 'nav_imaging');
  static final navGuiding = GlobalKey(debugLabel: 'nav_guiding');
  static final navSequencer = GlobalKey(debugLabel: 'nav_sequencer');
  static final navPlanetarium = GlobalKey(debugLabel: 'nav_planetarium');
  static final navFraming = GlobalKey(debugLabel: 'nav_framing');
  static final navFlatWizard = GlobalKey(debugLabel: 'nav_flat_wizard');
  static final navAnalytics = GlobalKey(debugLabel: 'nav_analytics');
  static final navWeather = GlobalKey(debugLabel: 'nav_weather');
  static final navPlanner = GlobalKey(debugLabel: 'nav_planner');
  static final navScheduler = GlobalKey(debugLabel: 'nav_scheduler');
  static final navSettings = GlobalKey(debugLabel: 'nav_settings');

  /// Get a GlobalKey by its string ID.
  /// Delegates to screen-specific key classes based on the key prefix.
  static GlobalKey? getKey(String? keyId) {
    if (keyId == null) return null;

    // Navigation keys (shared across tutorials)
    switch (keyId) {
      case 'side_navigation':
        return sideNavigation;
      case 'nav_dashboard':
        return navDashboard;
      case 'nav_equipment':
        return navEquipment;
      case 'nav_imaging':
        return navImaging;
      case 'nav_guiding':
        return navGuiding;
      case 'nav_sequencer':
        return navSequencer;
      case 'nav_planetarium':
        return navPlanetarium;
      case 'nav_framing':
        return navFraming;
      case 'nav_flat_wizard':
        return navFlatWizard;
      case 'nav_analytics':
        return navAnalytics;
      case 'nav_weather':
        return navWeather;
      case 'nav_settings':
        return navSettings;
    }

    // Delegate to screen-specific key classes based on prefix
    if (keyId.startsWith('equipment_')) {
      return EquipmentTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('imaging_')) {
      return ImagingTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('guiding_')) {
      return GuidingTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('sequencer_')) {
      return SequencerTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('planetarium_')) {
      return PlanetariumTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('framing_')) {
      return FramingTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('analytics_')) {
      return AnalyticsTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('flat_')) {
      return FlatWizardTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('weather_')) {
      return WeatherTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('settings_')) {
      return SettingsTutorialKeys.getKey(keyId);
    }
    if (keyId.startsWith('polar_')) {
      return PolarAlignmentTutorialKeys.getKey(keyId);
    }

    return null;
  }
}

/// Which way the operator was last moving through a tour.
enum TutorialDirection { forward, backward }

/// Where a tour should land when the step at [index] describes a panel that is
/// not on screen, or null when it should stay put.
///
/// A tour step whose target key resolves to no widget has nothing to teach, so
/// it is passed over — in whichever DIRECTION the operator was already going,
/// so Back does not bounce off it. Steps with no target at all (the centred
/// welcome and completion cards) always stand.
///
/// Returns null at the ends of the tour and whenever the target is live, which
/// is what makes the walk terminate.
///
/// The WHOLE run of absent steps is passed over in ONE answer, never one step
/// per build: hopping a single step and re-entering walks the operator through
/// the absent steps, and each becomes the current step long enough to be
/// announced. A step nobody should see must never become the current step.
///
/// One step absent among present siblings is a layout that does not carry that
/// panel. NOTHING resolving is a different situation — the screen has not
/// finished building, or the operator is elsewhere — so the whole rule stands
/// down rather than racing to the end of a tour on that evidence.
@visibleForTesting
int? tutorialStepIndexPastMissingTarget({
  required List<TutorialStep> steps,
  required int index,
  required TutorialDirection direction,
  required bool Function(String targetKey) isTargetLive,
}) {
  if (index < 0 || index >= steps.length) return null;

  // A step is landable when it points at nothing (the centred welcome and
  // completion cards) or at something that is on screen.
  bool landable(int i) {
    final key = steps[i].targetKey;
    return key == null || key.isEmpty || isTargetLive(key);
  }

  if (landable(index)) return null;
  final anyLive = steps.any((step) {
    final key = step.targetKey;
    return key != null && key.isNotEmpty && isTargetLive(key);
  });
  if (!anyLive) return null;

  final stride = direction == TutorialDirection.forward ? 1 : -1;
  for (var next = index + stride;
      next >= 0 && next < steps.length;
      next += stride) {
    if (landable(next)) return next;
  }
  // Every remaining step that way is absent too; there is nowhere to land, so
  // the tour stays where it is rather than running off the end.
  return null;
}

/// Tutorial overlay that displays coach marks with spotlight effect
class TutorialOverlay extends ConsumerStatefulWidget {
  final Widget child;

  const TutorialOverlay({super.key, required this.child});

  @override
  ConsumerState<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends ConsumerState<TutorialOverlay>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late AnimationController _pulseController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _ringAnimation;
  late Animation<double> _ringOpacityAnimation;
  _TutorialOverlayAction? _pendingAction;

  /// Route this tour last asked for. Cleared when the tour ends so replaying it
  /// routes again.
  String? _routeRequestedForTour;

  /// Which way the operator last moved, so a step that has to be passed over is
  /// passed over in the same direction rather than bouncing them forward again.
  TutorialDirection _direction = TutorialDirection.forward;

  /// Guards the post-frame absent-target check against re-entering itself while
  /// the move it asked for is still in flight.
  bool _resolvingMissingTarget = false;

  void _runAction(
    _TutorialOverlayAction action,
    Future<void> Function() operation,
  ) {
    if (action == _TutorialOverlayAction.next) {
      _direction = TutorialDirection.forward;
    } else if (action == _TutorialOverlayAction.previous) {
      _direction = TutorialDirection.backward;
    }
    if (_pendingAction != null) return;
    unawaited(() async {
      setState(() => _pendingAction = action);
      try {
        await operation();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text(
                'Could not save tutorial progress. Please try again.',
              ),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _pendingAction = null);
      }
    }());
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );

    // Pulse controller for the expanding ring effect (2 second cycle).
    //
    // NOT started here. This overlay wraps the whole app and stays mounted on
    // every screen, but it only draws its spotlight ring while a tutorial is
    // actually running. Repeating unconditionally kept a Ticker alive forever,
    // which keeps Flutter's vsync loop alive: the app produced ~30 frames per
    // second, running the full build/layout/paint/semantics pipeline, on every
    // screen, permanently — for a ring that is not on screen. It is started and
    // stopped in build, alongside the fade controller.
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    // Ring expands from 0 to 1 (spotlight edge to outer ring)
    _ringAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeOut,
      ),
    );

    // Ring fades out as it expands
    _ringOpacityAnimation = Tween<double>(begin: 0.8, end: 0.0).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeIn,
      ),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Take the operator to the screen the current step is talking about.
  ///
  /// The route is resolved from the STEP, not from a map of `nav_*` target
  /// keys almost no step carries — which would leave the coach mark on whatever
  /// screen the operator was already on, saying "Click the Profiles tab" over a
  /// screen that has none.
  void _navigateForStep(BuildContext context, TutorialStep step) {
    if (!context.mounted) return;

    final route = tutorialRouteForStep(step);
    if (route == null || route == _routeRequestedForTour) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;

    // Compare against what we last asked for, not against the current
    // location: /planetarium and /framing redirect onto Planner tabs, so the
    // location never equals the requested path and a location check would
    // re-navigate on every step of those tours.
    _routeRequestedForTour = route;
    if (router.routerDelegate.currentConfiguration.uri.path == route) return;

    // Defer past this build: the route change is a reaction to a provider
    // update and go_router must not be driven from inside a build phase.
    Future.microtask(() {
      if (context.mounted) router.go(route);
    });
  }

  /// Move past a step whose target never appeared.
  ///
  /// Deferred a beat past the frame: the step may have just asked go_router for
  /// another screen, and a target that has not finished building is not a
  /// missing one.
  void _passOverMissingTarget(TutorialProgress progress) {
    if (_resolvingMissingTarget || _pendingAction != null) return;
    final category = progress.activeCategory;
    if (category == null) return;
    final steps = TutorialDefinitions.getStepsForCategory(category);
    final index = progress.currentStepIndex;
    _resolvingMissingTarget = true;
    Future.delayed(const Duration(milliseconds: 450), () async {
      if (!mounted) {
        _resolvingMissingTarget = false;
        return;
      }
      try {
        final current = ref.read(tutorialProvider);
        if (current.activeCategory != category ||
            current.currentStepIndex != index) {
          return;
        }
        final target = tutorialStepIndexPastMissingTarget(
          steps: steps,
          index: index,
          direction: _direction,
          isTargetLive: (key) =>
              TutorialKeys.getKey(key)?.currentContext != null,
        );
        if (target == null) return;
        // One log line that names THIS overlay and the jump it made. The tour
        // is narrated by two different widgets (this coach-mark overlay and
        // the first-launch OnboardingOverlay), and a fix that changed nothing
        // on screen is otherwise indistinguishable from a fix applied to the
        // one that does not run.
        developer.log(
          'TutorialOverlay pass-over: ${category.name} '
          '$index -> $target (absent target ${steps[index].targetKey})',
          name: 'TutorialOverlay',
        );
        final notifier = ref.read(tutorialProvider.notifier);
        try {
          // goToStep, not repeated next/previous: the run is crossed in one
          // move so no absent step is ever the current step, and therefore
          // none of them is announced to a screen reader.
          await notifier.goToStep(target);
        } catch (_) {
          // Passing over an absent panel is a courtesy, not an instruction the
          // operator gave. A progress write that fails here leaves the tour
          // where it is; the operator's own Next still reports the failure.
        }
      } finally {
        _resolvingMissingTarget = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tutorialState = ref.watch(tutorialProvider);
    final notifier = ref.read(tutorialProvider.notifier);
    if (tutorialState.activeCategory != null) {
      _passOverMissingTarget(tutorialState);
    }

    // Listen for tutorial state changes to navigate to appropriate tabs
    ref.listen<TutorialProgress>(tutorialProvider, (previous, current) {
      if (current.activeCategory != previous?.activeCategory) {
        _routeRequestedForTour = null;
      }
      if (current.activeCategory != null && current.currentStepIndex >= 0) {
        final steps =
            TutorialDefinitions.getStepsForCategory(current.activeCategory!);
        if (current.currentStepIndex < steps.length) {
          _navigateForStep(context, steps[current.currentStepIndex]);
        }
      }
    });

    // Note: this overlay only renders spotlight coach marks for an actively
    // running tutorial; it does not gate a separate welcome takeover.

    // Animate when tutorial state changes. The pulse ring only exists while a
    // tutorial is running, so its ticker is stopped the rest of the time (see
    // initState) — otherwise it holds the whole app at ~30fps forever.
    if (tutorialState.activeCategory != null) {
      _animController.forward();
      if (!_pulseController.isAnimating) _pulseController.repeat();
    } else {
      _animController.reverse();
      if (_pulseController.isAnimating) {
        _pulseController.stop();
        _pulseController.value = 0;
      }
    }

    return Stack(
      children: [
        widget.child,

        // Tutorial overlay
        if (tutorialState.activeCategory != null)
          FadeTransition(
            opacity: _fadeAnimation,
            child: _TutorialOverlayContent(
              step: notifier.currentStep,
              currentIndex: tutorialState.currentStepIndex,
              totalSteps: notifier.totalSteps,
              isFirst: notifier.isFirstStep,
              isLast: notifier.isLastStep,
              ringAnimation: _ringAnimation,
              ringOpacityAnimation: _ringOpacityAnimation,
              isBusy: _pendingAction != null,
              isAdvancing: _pendingAction == _TutorialOverlayAction.next,
              isGoingBack: _pendingAction == _TutorialOverlayAction.previous,
              isSkipping: _pendingAction == _TutorialOverlayAction.skip,
              onNext: () => _runAction(
                _TutorialOverlayAction.next,
                notifier.nextStep,
              ),
              onPrevious: () => _runAction(
                _TutorialOverlayAction.previous,
                notifier.previousStep,
              ),
              onSkip: () => _runAction(
                _TutorialOverlayAction.skip,
                notifier.dismissTutorial,
              ),
              onSpotlightTapped: () {
                // Action completion callback - fires when user interacts with spotlight
                // This can be used to auto-advance steps in the future
              },
            ),
          ),
      ],
    );
  }
}

enum _TutorialOverlayAction { next, previous, skip }
