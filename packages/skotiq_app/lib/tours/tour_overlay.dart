import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../localization/skotiq_localizations.dart';
import '../router/app_routes.dart';
import 'tour.dart';
import 'tour_runner.dart';
import '../utils/snackbar_helper.dart';

part 'overlay/card.dart';
part 'overlay/coach_marks.dart';
part 'overlay/spotlight.dart';
part 'overlay/walkthrough.dart';

/// The box of the widget carrying [target], or null when none is being
/// painted.
///
/// Mounted is not enough: a tab that is kept alive but not shown, or a panel
/// held offstage, still has a context and a position, and a spotlight drawn
/// there lands on whatever is in front of it.
RenderBox? _paintedBox(TourTarget target) {
  final context = target.key.currentContext;
  // An IndexedStack hides its other children without taking them offstage;
  // only the Visibility it wraps them in knows.
  if (context == null || !Visibility.of(context)) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize || box.size.isEmpty) {
    return null;
  }
  RenderObject child = box;
  for (var parent = child.parent; parent != null; parent = child.parent) {
    if (!parent.paintsChild(child)) return null;
    child = parent;
  }
  return box;
}

/// The box a step about [target] spotlights. On a phone the rail's
/// destinations sit behind the bar's More button, so a step about one of
/// them points there.
RenderBox? _spotlightBox(TourTarget target) =>
    _paintedBox(target) ??
    (target.isRailDestination ? _paintedBox(TourTarget.navMore) : null);

/// Whether a step about [target] has something on screen to point at.
bool tourTargetIsOnShow(TourTarget target) => _spotlightBox(target) != null;

/// Which way the user was last moving through a tour.
enum TourDirection { forward, backward }

/// Where a tour should land when the step at [index] describes a panel that is
/// not on screen, or null when it should stay put.
///
/// A step whose target is absent has nothing to teach, so it is passed over in
/// whichever direction the user was already going, so Back does not bounce off
/// it. Steps with no target always stand.
///
/// The whole run of absent steps is passed over in one answer, never one step
/// per build: a step nobody should see must never become the current step,
/// where it would be announced.
///
/// One step absent among present siblings is a layout or a rig that does not
/// carry that panel. Nothing resolving is a different situation (the screen
/// has not finished building), so the rule stands down rather than racing to
/// the end of a tour on that evidence.
@visibleForTesting
int? tourStepIndexPastAbsentTarget({
  required List<TourStep> steps,
  required int index,
  required TourDirection direction,
  required bool Function(TourTarget target) isOnShow,
}) {
  if (index < 0 || index >= steps.length) return null;

  bool landable(int i) {
    final target = steps[i].target;
    return target == null || isOnShow(target);
  }

  if (landable(index)) return null;
  final anyOnShow = steps.any((step) {
    final target = step.target;
    return target != null && isOnShow(target);
  });
  if (!anyOnShow) return null;

  final stride = direction == TourDirection.forward ? 1 : -1;
  for (var next = index + stride;
      next >= 0 && next < steps.length;
      next += stride) {
    if (landable(next)) return next;
  }
  return null;
}

/// Draws the running tour over [child]: coach marks for most tours, a dialog
/// for the first-night walkthrough.
///
/// Mounted once, around the app shell, so a tour follows the user across
/// screens.
class TourOverlay extends ConsumerStatefulWidget {
  const TourOverlay({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<TourOverlay> createState() => _TourOverlayState();
}

enum _Move { next, back, skip }

/// A coach-mark step as drawn: the step, its place in the tour and where its
/// target is in the overlay's coordinates (null for a card on its own).
typedef _ShownStep = ({TourStep step, int index, Rect? spot});

class _TourOverlayState extends ConsumerState<TourOverlay>
    with SingleTickerProviderStateMixin {
  /// Ticks only while a coach-mark tour is on screen: it drives the pulse ring
  /// and re-measures the target each frame. A ticker left running keeps the
  /// whole app producing frames.
  late final AnimationController _pulse;

  /// What is drawn. It trails the runner's step until that step is settled:
  /// its target found, or found to be absent and the step left standing. A
  /// step that is passed over is never drawn or announced.
  final ValueNotifier<_ShownStep?> _shown = ValueNotifier<_ShownStep?>(null);

  _Move? _pendingMove;
  TourDirection _direction = TourDirection.forward;

  /// The location this tour last asked the router for. Compared instead of
  /// the router's current location because some paths redirect, so the
  /// location never equals what was asked for.
  String? _requestedLocation;

  /// When the current step became current, on the pulse's clock, and how
  /// many frames it has had since.
  Duration _stepSince = Duration.zero;
  int _stepFrames = 0;

  /// Whether the step asked for another screen. A screen that was just asked
  /// for needs time to build before its target can be called absent; one
  /// already on show does not.
  bool _stepChangedScreen = false;
  bool _stepSettled = false;
  bool _passingOver = false;

  /// Both must pass: the time covers a fast machine, where a page can still
  /// be loading after a dozen frames, and the frames cover a slow one, where
  /// half a second may be two frames.
  static const Duration _screenBuildTime = Duration(milliseconds: 450);
  static const int _screenBuildFrames = 12;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..addListener(_followTarget);
  }

  @override
  void dispose() {
    _pulse.dispose();
    _shown.dispose();
    super.dispose();
  }

  void _run(_Move move, Future<void> Function() operation) {
    if (move == _Move.next) _direction = TourDirection.forward;
    if (move == _Move.back) _direction = TourDirection.backward;
    if (_pendingMove != null) return;
    unawaited(() async {
      setState(() => _pendingMove = move);
      try {
        await operation();
      } catch (error, stack) {
        developer.log(
          'Tour progress was not saved',
          name: 'TourOverlay',
          level: 900,
          error: error,
          stackTrace: stack,
        );
        if (mounted) {
          context.showErrorSnackBar(
            'Could not save tutorial progress. Please try again.',
          );
        }
      } finally {
        if (mounted) setState(() => _pendingMove = null);
      }
    }());
  }

  void _onRunChanged(TourRunState? previous, TourRunState run) {
    final tour = run.active;
    if (tour != previous?.active) {
      _requestedLocation = null;
      _direction = TourDirection.forward;
      _shown.value = null;
    }
    if (tour == null || tour.style != TourStyle.coachMarks) {
      _pulse
        ..stop()
        ..value = 0;
      return;
    }
    if (!_pulse.isAnimating) _pulse.repeat();
    if (tour != previous?.active || run.stepIndex != previous?.stepIndex) {
      final asked = _goTo(tour.locationOfStep(run.stepIndex));
      _stepSince = _pulse.lastElapsedDuration ?? Duration.zero;
      _stepFrames = 0;
      _stepChangedScreen = asked;
      _stepSettled = false;
      _followTarget();
    }
  }

  /// Asks the router for [location] unless this tour is already there.
  /// Returns whether it asked.
  bool _goTo(String? location) {
    if (location == null || location == _requestedLocation) return false;
    final router = GoRouter.maybeOf(context);
    if (router == null) return false;
    _requestedLocation = location;
    if (router.routerDelegate.currentConfiguration.uri.toString() == location) {
      return false;
    }
    // A route change is a reaction to a provider update, and the router must
    // not be driven from inside a build.
    Future.microtask(() {
      if (mounted) router.go(location);
    });
    return true;
  }

  /// Settles the current step and then keeps its spotlight on the target as
  /// the target scrolls, animates or is laid out again.
  void _followTarget() {
    if (!mounted) return;
    final run = ref.read(tourRunnerProvider);
    final step = run.step;
    final overlay = context.findRenderObject();
    if (step == null || overlay is! RenderBox || !overlay.hasSize) return;

    final target = step.target;
    final box = target == null ? null : _spotlightBox(target);
    if (!_stepSettled) {
      if (_passingOver) return;
      _stepFrames++;
      if (target != null && box == null) {
        final waited =
            (_pulse.lastElapsedDuration ?? Duration.zero) - _stepSince;
        if (_stepChangedScreen &&
            (waited < _screenBuildTime || _stepFrames < _screenBuildFrames)) {
          return;
        }
        // The target is not coming. Either the tour moves on, and this step
        // is never drawn, or it stands as a card on its own.
        if (_passOverAbsentTarget(run)) return;
      }
      _stepSettled = true;
      if (box != null) _bringIntoView(box);
    }

    Rect? spot;
    if (box != null) {
      final rect = MatrixUtils.transformRect(
        box.getTransformTo(overlay),
        Offset.zero & box.size,
      );
      if (rect.overlaps(Offset.zero & overlay.size)) spot = rect;
    }
    final shown = (step: step, index: run.stepIndex, spot: spot);
    if (_shown.value != shown) _shown.value = shown;
  }

  /// Scrolls [box] into its scroll view when any of it is outside.
  void _bringIntoView(RenderBox box) {
    final Object? viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport is! RenderBox) return;
    final inViewport = MatrixUtils.transformRect(
      box.getTransformTo(viewport),
      Offset.zero & box.size,
    );
    final bounds = Offset.zero & viewport.size;
    if (bounds.contains(inViewport.topLeft) &&
        bounds.contains(inViewport.bottomRight)) {
      return;
    }
    box.showOnScreen(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Moves the tour past the current step when its target is absent and the
  /// rule in [tourStepIndexPastAbsentTarget] names a landing. Returns whether
  /// it moved.
  bool _passOverAbsentTarget(TourRunState run) {
    final tour = run.active;
    if (tour == null) return false;
    final landing = tourStepIndexPastAbsentTarget(
      steps: tour.steps,
      index: run.stepIndex,
      direction: _direction,
      isOnShow: tourTargetIsOnShow,
    );
    if (landing == null) return false;
    developer.log(
      'Passing over ${tour.id} step ${run.stepIndex} -> $landing '
      '(${tour.steps[run.stepIndex].target?.name} is not on show)',
      name: 'TourOverlay',
    );
    // One move across the whole absent run, so none of those steps is ever
    // the current step for longer than the write takes.
    _passingOver = true;
    ref.read(tourRunnerProvider.notifier).goTo(landing).catchError((
      Object error,
      StackTrace stack,
    ) {
      developer.log(
        'Could not pass over an absent tour step',
        name: 'TourOverlay',
        level: 900,
        error: error,
        stackTrace: stack,
      );
      // The write failed, so the step stands as a card on its own and the
      // user's own Next reports the failure.
      _stepSettled = true;
    }).whenComplete(() => _passingOver = false);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TourRunState>(tourRunnerProvider, _onRunChanged);
    final run = ref.watch(tourRunnerProvider);
    final runner = ref.read(tourRunnerProvider.notifier);
    final tour = run.active;
    final step = run.step;

    return Stack(
      children: [
        widget.child,
        if (tour != null && step != null)
          switch (tour.style) {
            TourStyle.coachMarks => _CoachMarks(
                key: ValueKey(tour),
                shown: _shown,
                total: tour.steps.length,
                pulse: _pulse,
                pendingMove: _pendingMove,
                onNext: () => _run(_Move.next, runner.next),
                onBack: () => _run(_Move.back, runner.back),
                onSkip: () => _run(_Move.skip, runner.skip),
              ),
            TourStyle.walkthrough when run.parked => _ParkedWalkthrough(
                index: run.stepIndex,
                total: tour.steps.length,
                onReturn: runner.unpark,
                onClose: runner.close,
              ),
            TourStyle.walkthrough => _Walkthrough(
                step: step,
                index: run.stepIndex,
                total: tour.steps.length,
                busy: _pendingMove != null,
                onNext: () => _run(_Move.next, runner.next),
                onBack: () => _run(_Move.back, runner.back),
                onSkip: () => _run(_Move.skip, runner.skip),
                onClose: runner.close,
                onShowMe: (AppRoute route) {
                  runner.park();
                  context.go(route.path);
                },
              ),
          },
      ],
    );
  }
}
