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

import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart' show MetricGridTone, SeriesChartTone;

import '../../services/night_actions/night_action_api.dart';
import '../../services/night_actions/night_text.dart';
import '../../services/run_control/run_control.dart';

export '../../services/night_actions/night_action_api.dart';
export '../../services/night_actions/night_text.dart';
export '../../services/run_control/run_control.dart'
    show NightRunPhase, NightRunPhaseFacts, RunControl;

part 'contracts/plan_models.dart';
part 'contracts/session_models.dart';

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

bool _nullableListEquals<T>(List<T>? a, List<T>? b) =>
    a == null ? b == null : b != null && listEquals(a, b);

int? _nullableListHash<T>(List<T>? list) =>
    list == null ? null : Object.hashAll(list);
