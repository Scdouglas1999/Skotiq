# Internationalization (i18n) — Contributing Guide

Skotiq ships with an in-app localization layer. English (`en`) is the
**source of truth**; Spanish (`es`) is the second supported language. This guide
explains the mechanism, how to add a key, how to add a language, and what is
still left to extract.

## The mechanism

There is **one** localization mechanism, shared by every Flutter surface
(desktop via `packages/skotiq_app`, and `apps/mobile`):

- **`packages/skotiq_app/lib/localization/skotiq_localizations.dart`** —
  the `SkotiqLocalizations` class, its `LocalizationsDelegate`, the
  `supportedLocales` list, and the `BuildContext.l10n` extension.
- **`.../skotiq_localizations/translations.dart`** — a single
  `_localizedValues` map of `locale -> key -> value`. This is the entire
  translation table. (It is a `part of` the file above.)

It is **not** `flutter gen-l10n` / ARB and **not** raw `intl`. It is a
hand-maintained map with `{placeholder}` interpolation. This was chosen because
it already existed, is wired end-to-end, and needs zero codegen step. Do **not**
introduce ARB/`intl` in parallel — extend this table instead.

### Wiring (already done)

- `SkotiqApp` (`packages/skotiq_app/lib/app.dart`) passes
  `SkotiqLocalizations.localizationsDelegates` / `supportedLocales` and sets
  `locale: _resolveLocale(settings?.language)`. When the user's language
  setting is `null`, `locale` is `null` and Flutter resolves from the **system**
  locale (falling back to `en` for unsupported locales).
- `apps/mobile/lib/main.dart` wires the same delegates/locales for its
  pre-connection screens.
- The **in-app language override** lives in **Settings → General → Language**
  (`packages/skotiq_app/lib/screens/settings/widgets/general_settings.dart`),
  backed by `appSettings.language` (`setLanguage('en' | 'es')`).

## Reading a string in code

```dart
import '.../localization/skotiq_localizations.dart';

final l10n = context.l10n;
Text(l10n.text('plannerTabProjects'));

// With placeholders:
Text(l10n.text('firstNightWizardStepLabel',
    params: {'current': '2', 'total': '7'})); // "Step 2 of 7"
```

`text()` falls back to the `en` value, then to the raw key, if a key is missing
in the active locale — so a missing translation degrades gracefully but is
caught by the completeness test (below).

## Adding a key

1. Open `translations.dart`.
2. Add the key to the **`en`** map with the English source string.
3. Add the **same key** to **every other locale** (`es`) with a translation.
4. Use `{placeholderName}` for interpolated values; pass them via `params:`.
   The placeholder set must match across locales (the test enforces this).
5. Prefer a screen/domain prefix for the key name
   (`equipmentProfileDeleted`, `plannerTabProgress`, `settingsImaging`,
   `commonClose`). Reuse the `common*` keys for generic verbs/buttons.

## Adding a language

1. Add a `Locale('xx')` to `SkotiqLocalizations.supportedLocales`.
2. Add a top-level `'xx': { ... }` block to `_localizedValues` containing
   **every** key present in `en`.
3. Add the language to the Settings → General dropdown
   (`general_settings.dart`) and to `_resolveLocale` in `app.dart`.
4. Add display-name keys (`languageXxx`) for the dropdown.
5. Run the completeness test — it will list any missing keys.

## Tests

`packages/skotiq_app/test/localization/translation_completeness_test.dart`
asserts, for every non-`en` locale:

- every `en` key exists,
- no extra keys exist beyond `en`,
- no blank values,
- `{placeholder}` sets match `en`,
- plus a smoke test of fallback + param substitution.

Run it with:

```bash
cd packages/skotiq_app && flutter test test/localization/
```

The table is exposed to the test via
`SkotiqLocalizations.debugLocalizedValues` (`@visibleForTesting`).

## Coverage status

**Fully localized / wired:**

- App shell navigation group and destination labels (`shell_navigation.dart`).
- Settings catalog section labels (`settings_catalog.dart`) and General /
  Appearance / many section bodies.
- Mobile connection screens, Tailscale setup sheet, saved-servers screen.
- Tonight, analytics, diagnostics chrome, planner header + tab labels.
- First-night wizard chrome + step UI (was the `v2.5.x i18n` TODO).
- Equipment screen profile management snackbars/dialogs.

**Remaining (the long tail — NOT yet extracted).** These still contain
hard-coded English `Text('...')` / labels. Tackle them screen-by-screen using
the recipe above; do not bulk-extract blindly. Each item is a checklist entry:

- [ ] Settings **bodies** (per-section): imaging, plate-solving, autofocus,
      calibration, notifications, remote-access detail panes, etc. Labels are
      localized; the body controls/help text mostly are not.
- [ ] Sequencer **body**: node palette, properties panel, toolbars, run
      dashboard, dialogs (`screens/sequencer/widgets/*`, `dialogs/*`,
      `tabs/*`). NOTE: the guiding panel is **out of scope** — do not touch.
- [ ] Equipment **body**: profile sidebar, discovery panel, health/readiness
      panels, device cards, profile editor dialog.
- [ ] Planner **body**: recommendation list, projects/scheduler/week/progress
      tab contents, filter chips, controls bar.
- [ ] Framing, planetarium, weather, flat-wizard, transients screens.
- [ ] Tonight / first-light onboarding spine copy.
- [ ] Common confirmation dialogs and error/snackbar copy not yet routed
      through `common*` keys.
- [ ] Mosaic wizard dialog (`screens/sequencer/widgets/mosaic_wizard_dialog.dart`).
- [ ] `skotiq_ui` / `skotiq_core`-level user-facing strings (these
      packages do not depend on `skotiq_app`; a shared string source would
      be needed before they can use `SkotiqLocalizations`).

### A note on scope boundaries

- **Guiding** screens/widgets/providers are intentionally excluded from this
  pass.
- `skotiq_core` and `skotiq_ui` cannot import `skotiq_app`'s
  localization (dependency direction). Strings that originate there (e.g. model
  enum labels, design-system defaults) need either a callback-based label hook
  or relocation of the table to a lower package before they can be localized.
- A few **structural** strings in `settings_catalog.dart` (group titles in
  `kGroupTitles`, deep-link keys) are deliberately fixed English literals
  because they are locale-independent navigation identifiers, not display chrome
  in the localized sense. Leave them as-is.
