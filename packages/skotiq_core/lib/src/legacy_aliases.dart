/// Public aliases for class names that are intentionally hidden from the
/// core barrel because they collide with another exported symbol of the
/// same name. The originals stay under their canonical names in their
/// source files; consumers reach them through these `*Legacy` / `*Model`
/// aliases via the public barrel and avoid `// ignore: implementation_imports`.
///
/// See `skotiq_core.dart` for the `hide` clauses that motivate these.
library;

import 'models/tutorial/tutorial_step.dart' as tutorial_step;
import 'providers/settings_provider.dart' as settings_provider;

/// Model-layer first-night-wizard helper exposed from
/// `src/models/tutorial/tutorial_step.dart`. The barrel hides the original
/// `FirstNightWizard` because the `skotiq_app` widget of the same name
/// would shadow it. UI code that needs the model wrapper imports
/// `FirstNightWizardModel` instead.
///
/// The model is the static `steps` provider that maps
/// `TutorialDefinitions.firstNight` into `FirstNightWizardStep` rows for the
/// wizard widget. Tests that reach in for the static `steps` getter use this
/// alias.
typedef FirstNightWizardModel = tutorial_step.FirstNightWizard;

/// Legacy 8-point compass horizon profile exposed from
/// `src/providers/settings_provider.dart`. The barrel hides the original
/// `HorizonProfile` because the scheduler's samples-based profile (the
/// `src/services/scheduler/horizon_profile.dart` class of the same name) is
/// the canonical public class.
///
/// The legacy profile is still persisted as JSON in
/// `app_settings.horizon_profile_json` and consumed by the settings UI and
/// `target_suggestion_service.dart`. Callers that need the legacy compass
/// profile import this alias.
typedef LegacyHorizonProfile = settings_provider.HorizonProfile;
