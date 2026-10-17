import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// Import mobile-specific widgets
import 'sequence_progress_card.dart';

/// Overlay widget that displays mobile sequence progress only while a sequence
/// is actively running (or paused) on mobile devices.
///
/// The run *controls* (pause/stop/skip) live in `MobilePlaybackBar` inside the
/// builder body, so this overlay carries no second control surface — it is the
/// ambient progress card only.
///
/// The overlay's visibility matches `MobilePlaybackBar` — both hide on
/// the terminal `completed` / `failed` / idle states. The end-of-session report
/// dialog (opened from `sequencer_screen.dart`) is the post-run surface, so the
/// floating card disappears together with the controls instead of lingering on
/// a finished run.
class MobileSequenceOverlay extends ConsumerWidget {
  const MobileSequenceOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);

    // Only show while running / paused. Idle and the terminal completed /
    // failed states hide the overlay.
    final isActive = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;
    if (!isActive) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      // The progress card carries its own `IgnorePointer` so taps fall through
      // to the tree behind it; no outer one is needed.
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),

          // Progress card (non-interactive — taps pass through to the tree).
          const IgnorePointer(
            ignoring: true,
            child: SequenceProgressCard(),
          ),

          // Clear bottom nav + status bar + safe area below the content stack.
          SizedBox(
            height: ShellChromeMetrics.floatingOverlayBottomInset(
              context,
              useBottomNav: true,
              margin: 8,
            ),
          ),
        ],
      ),
    );
  }
}
