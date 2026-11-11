import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Counts the times the wizard refused Next on the current step.
///
/// A step with fields listens to it to mark every field that blocks it, the
/// moment the refusal happens, instead of leaving the only explanation in the
/// notice band below the card.
final onboardingBlockedNextProvider = StateProvider<int>((ref) => 0);
