import 'package:flutter/widgets.dart';

/// Single step in the first-launch onboarding tour.
///
/// The tour is a fixed-length walkthrough that the OnboardingOverlay
/// renders as a dim full-screen scrim with a transparent cutout around the
/// step's target widget. Each step is identified by an immutable
/// description and a target [GlobalKey] resolver — null targets render a
/// centered tooltip (used by the welcome and completion cards).
///
/// Why a sealed value object instead of a freezed model: the step list is
/// a const seven-element array that never changes at runtime. A freezed
/// model would add codegen for zero benefit — these are static UI strings
/// alongside a key resolver, not domain state.
@immutable
class OnboardingStep {
  /// Stable id, used by tests and analytics. Not shown in UI.
  final String id;

  /// Heading shown at the top of the tooltip card.
  final String title;

  /// Body copy. Kept short (1–3 sentences) so the tooltip stays compact
  /// over the spotlighted control.
  final String body;

  /// Resolver for the target widget's GlobalKey. Lazily called every time
  /// the overlay re-renders so it picks up keys that mount late (the
  /// side-nav, for example, animates in on the first frame). Returns null
  /// for steps that have no spotlight (welcome / completion cards).
  final GlobalKey? Function() targetKey;

  /// Optional override for the cutout padding. Defaults to 8 in the
  /// painter; nav-rail entries look better with a bit more breathing room.
  final double padding;

  const OnboardingStep({
    required this.id,
    required this.title,
    required this.body,
    required this.targetKey,
    this.padding = 8,
  });

  /// True if this step has a UI target to spotlight. Welcome and
  /// completion cards return false here so the overlay centers them and
  /// drops the surrounding pulse ring.
  bool get hasTarget => targetKey() != null;
}
