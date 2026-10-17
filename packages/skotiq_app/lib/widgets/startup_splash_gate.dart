import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Where the shared startup splash is in its lifecycle.
///
/// Kept in a provider rather than in widget state because the splash outlives
/// individual mounts: the mobile app swaps its connection-screen `home:` for
/// `SkotiqApp` on connect, and the connected shell must not replay the brand
/// draw (or re-cover the app) when that swap happens mid-animation.
enum SkotiqSplashPhase {
  /// The draw pass is running or the app is still becoming ready.
  drawing,

  /// The app is ready and the splash is fading out.
  handingOff,

  /// The splash has finished; later mounts render straight through.
  done,
}

/// The wall-clock instant the first gate began its draw pass.
///
/// The draw is a shared deadline, not a per-mount animation: a gate that
/// mounts while another's draw is still running switches to the loading
/// motion rather than restarting the brand moment, and a ready app is never
/// held longer than one draw pass even if the gates handing the splash to
/// each other disagree about timing.
final skotiqSplashPhaseProvider =
    StateProvider<SkotiqSplashPhase>((_) => SkotiqSplashPhase.drawing);

/// Splash mark diameter, per the brand spec ("about 96 px").
const double kSkotiqSplashMarkSize = 96;

/// Covers [child] with the brand splash while the app starts.
///
/// Behavior:
/// - While startup runs, a [SkotiqMarkMotion.draw] mark sits centered on the
///   theme background.
/// - When [ready] is true the splash fades out over
///   `SkotiqTokens.durationSmooth`. A ready app is never held longer than
///   the draw pass — the fade starts the moment both conditions hold.
/// - If [ready] is still false when the draw finishes, the same mark keeps
///   animating in [SkotiqMarkMotion.loading], with [statusText] underneath it
///   when provided.
/// - [MediaQuery.disableAnimations] renders the still mark and a zero-length
///   fade, so the gate lifts as soon as the app is ready.
///
/// The gate belongs INSIDE the app's own content (the shell, or the mobile
/// connection screen's `home:`), not wrapped around the Navigator: startup
/// dialogs are pushed as routes on the root navigator, and a splash layered
/// over the navigator would hide pairing and recovery prompts it is meant to
/// sit behind.
class SkotiqSplashGate extends ConsumerStatefulWidget {
  const SkotiqSplashGate({
    super.key,
    required this.ready,
    required this.child,
    this.statusText,
  });

  /// Whether the app behind the splash is ready to be seen.
  final bool ready;

  /// The app content. Always kept in the tree so the splash is only a cover,
  /// never a different route — navigation state and provider lifetime are
  /// undisturbed underneath it.
  final Widget child;

  /// Optional status line shown under the mark once it is in the loading
  /// motion. Kept verbatim from whatever startup surface the gate covers.
  final String? statusText;

  /// Restores the shared draw clock for tests. The clock is static, so it
  /// would otherwise leak across `pumpWidget` calls in one test process.
  @visibleForTesting
  static void debugResetDrawClock() {
    _SkotiqSplashGateState._drawStart = null;
    _SkotiqSplashGateState._deadlinePassed = false;
  }

  @override
  ConsumerState<SkotiqSplashGate> createState() => _SkotiqSplashGateState();
}

class _SkotiqSplashGateState extends ConsumerState<SkotiqSplashGate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  late final Animation<double> _fadeCurve;

  /// True for the gate that started the shared draw clock. Only the owner's
  /// mark plays [SkotiqMarkMotion.draw]; later mounts inherit the deadline
  /// and show the loading motion.
  bool _ownsDraw = false;
  bool _drawComplete = false;
  bool _handOffScheduled = false;
  Timer? _deadlineTimer;

  /// The wall-clock instant the first gate began its draw pass.
  ///
  /// Static, not provider state: it is written in `initState` (where Riverpod
  /// mutations are illegal), it must outlive any single mount (the mobile app
  /// swaps its connection-screen `home:` for the shell mid-splash), and it
  /// must survive a fresh `ProviderScope` the same way the phase provider
  /// survives a remounted gate.
  static DateTime? _drawStart;

  /// Whether the shared draw deadline has passed. Set by the first deadline
  /// timer that fires; gates that mount later (after the owner was swapped
  /// away mid-draw) inherit it instead of owning a clock of their own.
  static bool _deadlinePassed = false;

  static final Duration _drawDuration = TrailsMotion.drawDuration(
    trailsLevels[trailsLevelForSize(kSkotiqSplashMarkSize)]!,
  );

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSmooth,
    )..addStatusListener(_handleFadeStatus);
    _fadeCurve = CurvedAnimation(
      parent: _fade,
      curve: SkotiqTokens.curveStandard,
    );

    if (_drawStart == null) {
      _drawStart = DateTime.now();
      _ownsDraw = true;
    }
    _armDeadline();

    // A gate that mounts while the previous gate is mid-fade finishes the
    // hand-off instantly instead of restarting it.
    if (ref.read(skotiqSplashPhaseProvider) == SkotiqSplashPhase.handingOff) {
      _fade.value = 1.0;
    }
  }

  void _handleFadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) {
      ref.read(skotiqSplashPhaseProvider.notifier).state =
          SkotiqSplashPhase.done;
    }
  }

  /// The draw ends for every gate at the same instant, owner or not; the
  /// timer exists so a gate that never receives `onDrawComplete` (it mounted
  /// after the draw started) still reevaluates at the deadline.
  void _armDeadline() {
    final start = _drawStart!;
    var remaining = _drawDuration - DateTime.now().difference(start);
    if (remaining.isNegative) remaining = Duration.zero;
    _deadlineTimer = Timer(remaining, () {
      _deadlinePassed = true;
      if (mounted) setState(() {});
    });
  }

  void _scheduleHandOff() {
    if (_handOffScheduled) return;
    _handOffScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(skotiqSplashPhaseProvider.notifier);
      if (notifier.state == SkotiqSplashPhase.drawing) {
        notifier.state = SkotiqSplashPhase.handingOff;
      }
      _fade.duration = animationDuration(context, SkotiqTokens.durationSmooth);
      _fade.forward();
    });
  }

  @override
  void dispose() {
    _deadlineTimer?.cancel();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(skotiqSplashPhaseProvider);
    if (phase == SkotiqSplashPhase.done) return widget.child;

    final reduced = animationsDisabled(context);
    final drawOver = reduced || _drawComplete || _deadlinePassed;
    final handOff = widget.ready && drawOver;

    if (handOff &&
        phase == SkotiqSplashPhase.drawing &&
        !_fade.isAnimating &&
        _fade.value < 1.0) {
      _scheduleHandOff();
    }

    final colors = SkotiqColors.of(context);
    final motion = reduced
        ? SkotiqMarkMotion.none
        : (_ownsDraw && !drawOver
            ? SkotiqMarkMotion.draw
            : SkotiqMarkMotion.loading);
    final status = widget.statusText;
    // The status line belongs to the loading wait: while the draw is still
    // playing the mark stands alone, and once the hand-off starts the splash
    // is leaving anyway.
    final showStatus = !handOff && drawOver && status != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // Once the app reports ready the splash stops absorbing input even
        // while the fade still runs; a covering layer that swallows taps on a
        // live shell is worse than one that lifts a beat early.
        IgnorePointer(
          ignoring: widget.ready,
          child: FadeTransition(
            opacity: ReverseAnimation(_fadeCurve),
            child: ColoredBox(
              color: colors.background,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SkotiqMark(
                      size: kSkotiqSplashMarkSize,
                      motion: motion,
                      semanticLabel: showStatus ? status : 'Loading',
                      onDrawComplete: () {
                        _drawComplete = true;
                        if (mounted) setState(() {});
                      },
                    ),
                    // The status slot is always laid out (invisible while
                    // the draw plays) so the mark never shifts off-center
                    // when the text appears.
                    const SizedBox(height: SkotiqTokens.space4xl),
                    Opacity(
                      opacity: showStatus ? 1 : 0,
                      child: Text(
                        status ?? ' ',
                        textAlign: TextAlign.center,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
