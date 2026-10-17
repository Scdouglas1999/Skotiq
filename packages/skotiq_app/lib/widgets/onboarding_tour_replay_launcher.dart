import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'onboarding/onboarding_overlay.dart';

/// Mounts the [OnboardingOverlay] above the app shell whenever the first-launch
/// tour's persisted status is [FirstLaunchTourStatus.pending].
///
/// The tour is REPLAY-ONLY — the equipment onboarding spine owns first-run
/// setup. Settings → Help & Tutorials → "Re-run onboarding tour" calls
/// [OnboardingTourNotifier.reset], which flips the persisted status back to
/// pending and invalidates [firstLaunchTourStatusProvider]; this launcher
/// watches that provider and overlays the tour on the running app, so the
/// replay button works without a restart.
///
/// `pending` means "a replay was explicitly requested and is unfinished". A
/// brand-new install has no row at all and reads as
/// [FirstLaunchTourStatus.notStarted], which mounts nothing.
///
/// The overlay sits in a [Stack] above [child] (rather than as a route) so it
/// floats over whatever screen the user is on — exactly where the per-step
/// spotlight cutouts need to be to highlight the live navigation chrome. When
/// the user completes or skips the tour, [OnboardingTourNotifier] persists the
/// terminal status and invalidates the provider, so this launcher tears the
/// overlay down on the next rebuild.
class OnboardingTourReplayLauncher extends ConsumerWidget {
  final Widget child;

  const OnboardingTourReplayLauncher({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(firstLaunchTourStatusProvider);

    // Only overlay the tour on an explicit pending status. Loading and error
    // states fail closed to "do not show" — a tour is a non-critical nicety and
    // must never wedge the app or flash on a transient read error.
    final showTour = statusAsync.maybeWhen(
      data: (status) => status == FirstLaunchTourStatus.pending,
      orElse: () => false,
    );

    if (!showTour) {
      return child;
    }

    return Stack(
      children: [
        child,
        const Positioned.fill(
          child: OnboardingOverlay(),
        ),
      ],
    );
  }
}
