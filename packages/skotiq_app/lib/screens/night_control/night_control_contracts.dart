// The shared vocabulary of the Tonight night-control screen.
//
// Every package of the rework (docs/design/night-control-plan.md section 3)
// builds against this file: the data providers (P1a, P1b) produce these view
// models, the action controller (P2) implements [NightActionApi], and the
// header, center and panel packages (P4 to P7) render them. Nothing here
// reads a provider or a device. The view models sit in the part files under
// `contracts/`; import this file only.
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
// | Provider                       | Type                       | Owner |
// |--------------------------------|----------------------------|-------|
// | `nightRunPhaseProvider`        | `NightRunPhase`            | P1a   |
// | `nightHeaderProvider`          | `NightHeaderVm`            | P1a   |
// | `nightTimelineProvider`        | `NightTimelineVm?`         | P1a   |
// | `nightTargetProvider`          | `NightTargetVm?`           | P1a   |
// | `nightPlanProgressProvider`    | `NightPlanVm?`             | P1a   |
// | `nightPlanStepsProvider`       | `List<PlanStepVm>`         | P1a   |
// | `nightUpcomingProvider`        | `List<UpcomingItemVm>`     | P1a   |
// | `nightSessionFramesProvider`   | `List<StripFrameVm>`       | P1b   |
// | `nightFrameSeriesProvider`     | `NightSeriesVm`  (HFR, stars) | P1b |
// | `nightTemperatureSeriesProvider` | `NightSeriesVm` (temps, focuser) | P1b |
// | `nightGuideSeriesProvider`     | `NightSeriesVm`  (RA/Dec, px) | P1b |
// | `nightLastFrameProvider`       | `NightLastFrameVm?`        | P1b   |
// | `nightSessionStatsProvider`    | `NightSessionVm`           | P1b   |
// | `nightEquipmentProvider`       | `List<EquipmentRowVm>`     | P1b   |
// | `nightConditionsProvider`      | `NightConditionsVm`        | P1b   |
// | `nightLogProvider`             | `List<NightLogEntryVm>`    | P1b   |
// | `nightBeforeYouStartProvider`  | `List<ChecklistItemVm>`    | P1b   |
// | `nightActionApiProvider`       | `NightActionApi`           | P2    |
// | `nightActionStateProvider`     | `ManualActionState`        | P2    |
// | `nightManualActionsProvider`   | `List<ManualActionVm>`     | P2    |
// | `nightPanelTabProvider`        | `NightPanelTab`            | P0 (below) |
//
// ## skotiq_ui kit widgets (P3)
//
// skotiq_ui cannot import this app, so the kit widgets take their own plain
// types and the screen maps the view models onto them. P3 builds exactly
// these signatures; P4 to P7 call them. Colors resolve inside the widgets
// from `SkotiqColors` / `SkotiqChartColors`, never from the caller.
//
// ```dart
// // 14 px night strip with several windows, a now marker and a labels row.
// enum NightTimelineSpanState { done, active, planned }
// class NightTimelineSpan {
//   const NightTimelineSpan({required DateTime start, required DateTime end,
//       required NightTimelineSpanState state});
// }
// class NightTimelineLabel {
//   // Laid out left to right, spaced between. Emphasized = the "now" label.
//   const NightTimelineLabel(String text, {bool emphasized = false});
// }
// class NightTimelineStrip extends StatelessWidget {
//   const NightTimelineStrip({
//     super.key,
//     required DateTime start,          // sunset: left edge
//     required DateTime end,            // sunrise: right edge
//     DateTime? darkStart,              // astronomical dark band, if any
//     DateTime? darkEnd,
//     required DateTime now,            // marker; clamped to the strip
//     List<NightTimelineSpan> spans = const [],
//     List<NightTimelineLabel> labels = const [],
//     required String semanticLabel,    // one sentence, from data
//     double? width,                    // null = fill the constraints
//   });
//   static const double stripHeight = 14;
// }
//
// // Up to three line series against time, null y = gap, vertical markers,
// // highlighted points, optional second axis, no axis chrome.
// enum SeriesChartTone { primary, secondary, tertiary, muted, warning, error }
// enum SeriesChartAxis { left, right }
// class SeriesChartLine {
//   const SeriesChartLine({required List<(DateTime, double?)> points,
//       required SeriesChartTone tone, SeriesChartAxis axis = SeriesChartAxis.left,
//       bool dashed = false, bool stepped = false,
//       double? minY, double? maxY});   // fixed range; null = fit the data
// }
// class SeriesChartMarker {
//   const SeriesChartMarker(DateTime at, {SeriesChartTone tone = SeriesChartTone.muted});
// }
// class SeriesChartHighlight {
//   const SeriesChartHighlight(DateTime at, double y,
//       {SeriesChartAxis axis = SeriesChartAxis.left,
//       SeriesChartTone tone = SeriesChartTone.error});
// }
// class SeriesChart extends StatelessWidget {
//   const SeriesChart({
//     super.key,
//     required List<SeriesChartLine> lines,   // at most 3
//     List<SeriesChartMarker> markers = const [],
//     List<SeriesChartHighlight> highlights = const [],
//     DateTime? from,                   // x range; null = fit the data
//     DateTime? to,
//     double? zeroLineY,                // a center line (guide error 0)
//     double height = 70,
//     required String semanticLabel,
//   });
// }
//
// // Dense value / label / delta grid built on Readout.
// enum MetricGridTone { neutral, good, warning, bad }
// class MetricGridItem {
//   const MetricGridItem({required String label, String? value,  // null = "—"
//       String? delta, MetricGridTone deltaTone = MetricGridTone.neutral,
//       MetricGridTone valueTone = MetricGridTone.neutral});
// }
// class MetricGrid extends StatelessWidget {
//   const MetricGrid({super.key, required List<MetricGridItem> items,
//       int columns = 4});
// }
//
// // The six text tabs with a dot badge; arrow keys move the selection.
// enum PanelTabBadge { none, active, alert }
// class PanelTabItem {
//   const PanelTabItem(String label, {PanelTabBadge badge = PanelTabBadge.none});
// }
// class PanelTabStrip extends StatelessWidget {
//   const PanelTabStrip({super.key, required List<PanelTabItem> tabs,
//       required int selectedIndex, required ValueChanged<int> onSelected,
//       required String semanticLabel});
//   static const double height = 36;
// }
// ```
//
// The app-side tones below ([MetricTone], [SeriesTone]) carry the same names
// as the kit's, so the mapping is one switch.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' show FrameExclusionKind;

import '../../localization/skotiq_localizations.dart';

part 'contracts/plan_models.dart';
part 'contracts/session_models.dart';
part 'contracts/action_models.dart';

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// The right panel's tabs, in display order.
enum NightPanelTab { overview, camera, focus, mount, guide, solve }

/// Where tonight's run stands, as the header shows it.
enum NightRunPhase {
  /// No plan loaded, or the rig is not connected enough to start one.
  notSetUp,

  /// A plan is loaded and could start now.
  ready,

  /// "Start at dark" is armed; the run starts at astronomical dark.
  armed,

  /// The run is executing.
  running,

  /// The operator paused the run.
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

/// The panel tab an action-bar button selects when pressed (plan section 2).
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

/// Emphasis for a value, a delta or a row. Maps one to one onto the kit's
/// `MetricGridTone`.
enum MetricTone { neutral, good, warning, bad }

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

bool _nullableListEquals<T>(List<T>? a, List<T>? b) =>
    a == null ? b == null : b != null && listEquals(a, b);

int? _nullableListHash<T>(List<T>? list) =>
    list == null ? null : Object.hashAll(list);
