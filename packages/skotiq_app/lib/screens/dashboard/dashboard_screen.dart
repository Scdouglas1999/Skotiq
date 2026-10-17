// Tonight (`/dashboard`) — 06 §Tonight.
//
// ONE layout, three states. The page is always: page header, hero, night band,
// grid. What changes between "nothing is set up", "a sequence is loaded" and "a
// run is live" is what the HERO says and whether the grid is the first-light
// CHECKLIST or the five monitoring panels. The old split between a full-canvas
// standby briefing and a separate zone cockpit is gone, along with the command
// bar, the action row, the "no active target" bar and the floating prompts they
// carried.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../localization/skotiq_localizations.dart';
import '../sequencer/widgets/run_dashboard/critical_event_banner.dart';
import '../sequencer/widgets/run_dashboard/recovery_banner.dart';
import '../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'dashboard_layout.dart';
import 'dashboard_layout_provider.dart';
import 'widgets/dashboard_header_actions.dart';
import 'widgets/dashboard_tile.dart';
import 'widgets/tonight/tonight_checklist_panel.dart';
import 'widgets/tonight/tonight_grid.dart';
import 'widgets/tonight/tonight_hero.dart';
import 'widgets/tonight/tonight_night_band.dart';
import 'widgets/tonight/tonight_side_panels.dart';
import 'widgets/widget_picker_dialog.dart';

/// The page body's gutter and the gap above the hero (06 §Tonight: 24 px
/// gutter, 20 px top).
const double _gutter = SkotiqTokens.space2xl;
const double _topGap = SkotiqTokens.spaceXl;

/// Below this the first-run checklist and its side column stack.
const double _checklistStackWidth = 900;

/// The first-run split: checklist c7, side column c5.
const int _checklistSpan = 7;
const int _sideSpan = 5;

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    // Pulse is created stopped; build() drives it based on device activity so
    // it doesn't burn frames on an idle dashboard.
    _pulseController = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationPulse,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    // Ensure PHD2 controller is active and listening to events.
    ref.watch(phd2ControllerProvider);
    // Keep the critical-events → notifications bridge alive while the dashboard
    // is shown. It's a Provider<void> whose side effects only run while watched.
    ref.watch(runDashboardCriticalEventsBridgeProvider);

    // Pulse only on genuine ACTIVITY (an exposure in progress), not on mere
    // connection: on a remote slave the mirrored devices report "connected"
    // permanently, so gating on connection burned a 60 Hz repaint forever.
    final sessionCapturing =
        ref.watch(sessionStateProvider.select((s) => s.isCapturing));
    if (sessionCapturing) {
      if (!_pulseController.isAnimating) _pulseController.repeat(reverse: true);
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
    }

    final layoutAsync = ref.watch(dashboardLayoutProvider);
    // The checklist owns the page whenever the operator is not set up. It is
    // the SAME signal the old standby briefing used, so nothing about when the
    // dashboard "wakes up" has changed — only what it shows.
    final firstRun = ref.watch(dashboardStandbyProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PageHeader(
          icon: LucideIcons.moonStar,
          title: l10n.text('navTonight'),
          context: _today(context, ref.watch(clockProvider)),
          actions: <Widget>[
            DashboardHeaderActions(
              isEditing: _isEditing,
              canEdit: !firstRun,
              onToggleEdit: _toggleEdit,
              onManageWidgets: _showWidgetPicker,
              onResetLayout: _resetLayout,
            ),
          ],
        ),
        Expanded(
          child: layoutAsync.when(
            data: (layout) => _Body(
              layout: layout,
              colors: colors,
              pulseController: _pulseController,
              isEditing: _isEditing,
              firstRun: firstRun,
              onReorder: (dragged, target) => ref
                  .read(dashboardLayoutProvider.notifier)
                  .reorder(dragged, target),
              onResize: (id) {
                final tile = layout.tiles.firstWhere((t) => t.widgetId == id);
                ref
                    .read(dashboardLayoutProvider.notifier)
                    .setTileSize(id, tile.size.next());
              },
              onToggleEnabled: (id, enabled) => ref
                  .read(dashboardLayoutProvider.notifier)
                  .setTileEnabled(id, enabled),
            ),
            loading: () => const DashboardLoading(),
            error: (error, _) =>
                DashboardLayoutError(error: error, onReset: _resetLayout),
          ),
        ),
      ],
    );
  }

  void _toggleEdit() => setState(() => _isEditing = !_isEditing);

  Future<void> _resetLayout() async {
    await ref.read(dashboardLayoutProvider.notifier).resetLayout();
  }

  void _showWidgetPicker() => showWidgetPickerModal(context);

  /// Today's date in the reader's language.
  ///
  /// `MaterialLocalizations`, not intl's `DateFormat`: the Global*Localizations
  /// delegates the app installs guarantee this locale's date symbols are
  /// loaded, while a bare `DateFormat('…', 'es')` throws unless
  /// `initializeDateFormatting` has been called. The clock, not
  /// `DateTime.now()`, so the page dates itself on the site the operator chose.
  static String _today(BuildContext context, Clock clock) =>
      MaterialLocalizations.of(context).formatMediumDate(clock.now());
}

/// Hero, band, then either the checklist split or the panel grid.
class _Body extends ConsumerWidget {
  const _Body({
    required this.layout,
    required this.colors,
    required this.pulseController,
    required this.isEditing,
    required this.firstRun,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
  });

  final DashboardLayout layout;
  final SkotiqColors colors;
  final AnimationController pulseController;
  final bool isEditing;
  final bool firstRun;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(_gutter, _topGap, _gutter, _gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // The two run-level alerts. They are the app's ONE banner per problem
          // (05 §11) and they self-hide; nothing else on this page restates a
          // run fault.
          const RunDashboardRecoveryBanner(),
          const RunDashboardCriticalBanner(),

          const TonightHero(),
          const SizedBox(height: 14),

          // Absent when no site is set: checklist step 1 is the one place that
          // problem is represented (06 §Tonight).
          const TonightNightBand(),
          const SizedBox(height: kTonightGridGap),

          if (isEditing) ...<Widget>[
            SkotiqBanner(
              title: context.l10n.text('tnEditModeTitle'),
              message: context.l10n.text('dbEditModeHint'),
            ),
            const SizedBox(height: kTonightGridGap),
          ],

          if (firstRun)
            const _FirstRunSplit()
          else
            TonightGrid(
              tiles: layout.tiles,
              colors: colors,
              pulseController: pulseController,
              isEditing: isEditing,
              onReorder: onReorder,
              onResize: onResize,
              onToggleEnabled: onToggleEnabled,
            ),
        ],
      ),
    );
  }
}

/// The first-run state: the checklist at c7 beside moon / weather / last night
/// at c5.
class _FirstRunSplit extends StatelessWidget {
  const _FirstRunSplit();

  @override
  Widget build(BuildContext context) {
    const side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TonightMoonPanel(),
        SizedBox(height: kTonightGridGap),
        TonightWeatherPanel(),
        SizedBox(height: kTonightGridGap),
        TonightLastNightPanel(),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _checklistStackWidth) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TonightChecklistPanel(),
              SizedBox(height: kTonightGridGap),
              side,
            ],
          );
        }
        return const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(flex: _checklistSpan, child: TonightChecklistPanel()),
            SizedBox(width: kTonightGridGap),
            Expanded(flex: _sideSpan, child: side),
          ],
        );
      },
    );
  }
}
