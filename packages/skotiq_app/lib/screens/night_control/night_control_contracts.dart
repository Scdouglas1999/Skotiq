// The shared vocabulary of the Tonight night-control screen.
//
// Nothing here reads a provider or a device. The view models sit in the part
// files under `contracts/`; import this file only.
//
// Two rules hold for every type below:
//  * a field the screen cannot honestly know is nullable, and null renders
//    as a dash or leaves the row out. No field defaults to 0;
//  * copy that a provider produces (it has no BuildContext) travels as a
//    [NightText], which the widget resolves against [SkotiqLocalizations].
//    Keys go into both the `en` and `es` maps of translations.dart.
//
// ## Provider names
//
// The packages that own them declare these providers in their own files.
// The widgets read only these, so a widget test overrides each with a plain
// value from `test/screens/night_control/fixtures/night_fixtures.dart`.
//
// | Provider                       | Type                       |
// |--------------------------------|----------------------------|
// | `nightRunPhaseProvider`        | `NightRunPhase`            |
// | `nightHeaderProvider`          | `NightHeaderVm`            |
// | `nightTimelineProvider`        | `NightTimelineVm?`         |
// | `nightTargetProvider`          | `NightTargetVm?`           |
// | `nightPlanProgressProvider`    | `NightPlanVm?`             |
// | `nightPlanStepsProvider`       | `List<PlanStepVm>`         |
// | `nightUpcomingProvider`        | `List<UpcomingItemVm>`     |
// | `nightSessionFramesProvider`   | `List<StripFrameVm>`       |
// | `nightFrameSeriesProvider`     | `NightSeriesVm`  (HFR, stars) |
// | `nightTemperatureSeriesProvider` | `NightSeriesVm` (temps, focuser) |
// | `nightGuideSeriesProvider`     | `NightSeriesVm`  (RA/Dec, px) |
// | `nightLastFrameProvider`       | `NightLastFrameVm?`        |
// | `nightSessionStatsProvider`    | `NightSessionVm`           |
// | `nightEquipmentProvider`       | `List<EquipmentRowVm>`     |
// | `nightConditionsProvider`      | `NightConditionsVm`        |
// | `nightLogProvider`             | `List<NightLogEntryVm>`    |
// | `nightBeforeYouStartProvider`  | `List<ChecklistItemVm>`    |
// | `nightActionApiProvider`       | `NightActionApi`           |
// | `nightActionStateProvider`     | `ManualActionState`        |
// | `nightManualActionsProvider`   | `List<ManualActionVm>`     |
// | `nightPanelTabProvider`        | `NightPanelTab`            |
//
// ## skotiq_ui kit widgets
//
// skotiq_ui cannot import this app, so the kit widgets (NightTimelineStrip,
// SeriesChart, MetricGrid, PanelTabStrip) take their own plain types and the
// screen maps the view models onto them. Colors resolve inside the widgets
// from `SkotiqColors` / `SkotiqChartColors`, never from the caller.
//
// The app-side tones below ([MetricGridTone], [SeriesChartTone]) carry the same names
// as the kit's, so the mapping is one switch.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../localization/skotiq_localizations.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart' show MetricGridTone, SeriesChartTone;

part 'contracts/plan_models.dart';
part 'contracts/session_models.dart';
part 'contracts/action_models.dart';

/// The right panel's tabs, in display order.
enum NightPanelTab { overview, camera, focus, mount, guide, solve }

extension NightPanelTabLabel on NightPanelTab {
  /// The tab's name in translations.dart.
  String get labelKey => switch (this) {
        NightPanelTab.overview => 'nightPanelTabOverview',
        NightPanelTab.camera => 'nightPanelTabCamera',
        NightPanelTab.focus => 'nightPanelTabFocus',
        NightPanelTab.mount => 'nightPanelTabMount',
        NightPanelTab.guide => 'nightPanelTabGuide',
        NightPanelTab.solve => 'nightPanelTabSolve',
      };
}

/// Where tonight's run stands, as the header shows it.
enum NightRunPhase {
  /// No plan loaded, or the rig is not connected enough to start one.
  notSetUp,

  /// A plan is loaded and could start now.
  ready,

  /// "Start at dark" is armed; the run starts at astronomical dark.
  armed,

  running,

  pausedByUser,

  /// The action controller paused the run to perform a manual action, or a
  /// manual Loop holds it. [ManualActionState.active] says which.
  pausedForAction,

  /// Stop was requested and the run is finalizing.
  stopping,

  /// The run ended (completed, stopped or failed) and nothing new is loaded.
  finished,
}

/// The manual actions: the center action bar's buttons, and [solve], the
/// Solve tab's own button.
///
/// [tracking] and [cooler] appear only when no run is active (the Ready
/// board); [dither] and [flip] only while a run is loaded. [solve] is never
/// on the action bar.
enum ManualActionId {
  snapshot,
  loop,
  autofocus,

  /// Solves the frame on screen without syncing; touches no device, so it
  /// never pauses the run.
  solve,
  solveSync,
  center,
  dither,
  flip,
  tracking,
  cooler,
}

/// The panel tab an action-bar button selects when pressed.
/// Automatic events never switch tabs.
extension ManualActionPanelTab on ManualActionId {
  NightPanelTab get panelTab => switch (this) {
        ManualActionId.snapshot || ManualActionId.loop => NightPanelTab.camera,
        ManualActionId.cooler => NightPanelTab.camera,
        ManualActionId.autofocus => NightPanelTab.focus,
        ManualActionId.solve ||
        ManualActionId.solveSync ||
        ManualActionId.center =>
          NightPanelTab.solve,
        ManualActionId.dither => NightPanelTab.guide,
        ManualActionId.flip || ManualActionId.tracking => NightPanelTab.mount,
      };
}

/// The selected right-panel tab. In memory only, so it survives navigation
/// away from Tonight and back, and resets when the app restarts.
final nightPanelTabProvider =
    StateProvider<NightPanelTab>((ref) => NightPanelTab.overview);

/// Counts the operator's requests to see the panel. In the single column
/// the panel sits below the frame, so opening a tab from elsewhere on the
/// page scrolls it into view.
final nightPanelRevealProvider = StateProvider<int>((ref) => 0);

/// Opens [tab] for the operator and brings the panel into view.
void nightOpenPanelTab(WidgetRef ref, NightPanelTab tab) {
  ref.read(nightPanelTabProvider.notifier).state = tab;
  ref.read(nightPanelRevealProvider.notifier).state++;
}

/// Copy produced away from a BuildContext.
///
/// Either a translations.dart key with `{name}` parameters, or a literal that
/// is already final (a target name, a filter, a device name, a number with
/// its unit).
@immutable
class NightText {
  const NightText(this.key, {this.params = const <String, String>{}})
      : literal = null;

  const NightText.literal(String text)
      : key = '',
        literal = text,
        params = const <String, String>{};

  /// The translations.dart key. Empty for a literal.
  final String key;

  /// The text itself, when it needs no translation.
  final String? literal;

  /// Values substituted for `{name}` in the translated string.
  final Map<String, String> params;

  String resolve(SkotiqLocalizations l10n) =>
      literal ?? l10n.text(key, params: params);

  @override
  bool operator ==(Object other) =>
      other is NightText &&
      other.key == key &&
      other.literal == literal &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
        key,
        literal,
        Object.hashAllUnordered(
          params.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );

  @override
  String toString() => literal ?? 'NightText($key, $params)';
}

bool _nullableListEquals<T>(List<T>? a, List<T>? b) =>
    a == null ? b == null : b != null && listEquals(a, b);

int? _nullableListHash<T>(List<T>? list) =>
    list == null ? null : Object.hashAll(list);
