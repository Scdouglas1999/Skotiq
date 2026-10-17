import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Tonight's single opinionated target for the one-tap flow.
///
/// Prefers the live scheduler's pick (`schedulerPreviewDecisionProvider`) so
/// the one-tap headline IS what the autopilot would slew to next. Falls back
/// to the best whole-night suggestion (`tonightSuggestionsProvider.first`)
/// when the scheduler has no eligible target at this instant (e.g. nothing
/// scheduled yet) but the outlook still has a strong candidate.
///
/// Returns null only when there is genuinely nothing imageable tonight; the
/// screen surfaces that honestly rather than dispatching a bad run.
final oneTapTargetProvider =
    FutureProvider.autoDispose<TargetSuggestion?>((ref) async {
  final suggestions = await ref.watch(tonightSuggestionsProvider.future);
  if (suggestions.isEmpty) return null;

  // The scheduler preview is best-effort: if it throws (no engine state yet)
  // we still have a ranked suggestion list to fall back on, so the one-tap
  // flow degrades to the top whole-night candidate instead of erroring.
  int? chosenId;
  try {
    final decision = await ref.watch(schedulerPreviewDecisionProvider.future);
    chosenId = decision.chosenTargetId;
  } catch (_) {
    chosenId = null;
  }

  if (chosenId != null) {
    for (final s in suggestions) {
      if (s.targetId == chosenId) return s;
    }
  }
  // Scheduler had no eligible pick (or it isn't in the suggestion set) — fall
  // back to the top-scored whole-night candidate.
  return suggestions.first;
});
