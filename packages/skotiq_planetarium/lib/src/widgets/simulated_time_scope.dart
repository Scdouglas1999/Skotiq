import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/planetarium_providers.dart';

/// Confines simulated ("time travel") observation time to the planetarium.
///
/// The observation clock is app-wide on purpose — the sky maths, the Dashboard
/// header, its astronomical-dark countdown and the moon phase all evaluate
/// against it — but only the planetarium's transport can move it. So scrubbing
/// the planetarium forward and walking away left the Dashboard reporting a
/// clock 8.5 h out, "Dark in 3h 54m" instead of 12h 19m, and a 6% moon instead
/// of 1%, with the fictional value the one labelled "Local". Nothing outside
/// the planetarium hinted that "now" had been redefined.
///
/// Wrapping the planetarium in this scope returns the clock to the real instant
/// when the planetarium leaves the tree, so no other screen can inherit a
/// simulated one.
class SimulatedTimeScope extends ConsumerStatefulWidget {
  const SimulatedTimeScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SimulatedTimeScope> createState() => _SimulatedTimeScopeState();
}

class _SimulatedTimeScopeState extends ConsumerState<SimulatedTimeScope> {
  late final ObservationTimeNotifier _clock;

  @override
  void initState() {
    super.initState();
    // Resolved now, not in dispose: `ref` is not usable once the element is
    // being unmounted.
    _clock = ref.read(observationTimeProvider.notifier);
  }

  @override
  void dispose() {
    final clock = _clock;
    // Deferred: dispose runs inside the frame that is tearing this subtree
    // down, and notifying the clock's listeners there would mark them dirty
    // mid-build. `mounted` covers the container going away with us.
    scheduleMicrotask(() {
      if (clock.mounted) clock.setRealTime(true);
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
