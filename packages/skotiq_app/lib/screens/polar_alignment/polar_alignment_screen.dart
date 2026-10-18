import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/tutorial_keys/polar_alignment_keys.dart';
import 'polar_alignment_body_layout.dart';
import 'polar_alignment_error_format.dart';
import 'widgets/all_sky_target_reticle.dart';
import 'widgets/polar_alignment_segmented_button.dart';
// File split: the PolarAlignmentScreen state keeps lifecycle and alignment
// actions. Panel builders, helper widgets, and painters live in focused library
// parts so the private provider-facing implementation remains encapsulated.

part 'polar_alignment_screen_parts/_status_and_settings.dart';
part 'polar_alignment_screen_parts/_progress_widgets.dart';
part 'polar_alignment_screen_parts/_error_visualization.dart';
part 'polar_alignment_screen_parts/_screen_shell.dart';
part 'polar_alignment_screen_parts/_configuration_panel.dart';
part 'polar_alignment_screen_parts/_history_panel.dart';
part 'polar_alignment_screen_parts/_center_panel.dart';
part 'polar_alignment_screen_parts/_measurement_panel.dart';
part 'polar_alignment_screen_parts/_completion_panel.dart';
part 'polar_alignment_screen_parts/_right_panel.dart';

/// The footer line that names why Start Alignment is refusing.
///
/// Present only while a prerequisite is unmet, so a widget test asserting on it
/// is asserting the operator can READ the refusal. A hover tooltip is invisible
/// to a click, to a screen reader and to a photograph of the screen.
const Key startBlockedNoticeKey = Key('polar-alignment-start-blocked');

class PolarAlignmentScreen extends ConsumerStatefulWidget {
  const PolarAlignmentScreen({super.key});

  @override
  ConsumerState<PolarAlignmentScreen> createState() =>
      _PolarAlignmentScreenState();
}

class _PolarAlignmentScreenState extends ConsumerState<PolarAlignmentScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;

  /// Header width at which the device chips and the labelled Back and History
  /// fit on the header row beside the title, the method tabs and the primary.
  static const double headerRoomyWidth = 1200;

  /// Scroll position of the left configuration column, owned here so the header
  /// History toggle can bring the panel it reveals into view. The panel is
  /// appended BELOW Essential/Common/Advanced, so with the collapsibles open it
  /// lands past the bottom of the viewport and the toggle looked like a dead
  /// control: the button lit up and nothing else on screen changed.
  final ScrollController _configScrollController = ScrollController();

  /// Captured every build so [dispose] can act on them: `ref` is already
  /// invalid by the time a ConsumerState is disposed.
  PolarAlignmentController? _controller;
  PolarAlignPhase _phase = PolarAlignPhase.idle;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _releaseFinishedRun();
    _configScrollController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Drop a FINISHED run's state as the operator leaves the wizard.
  ///
  /// The alignment state is app-scoped, so pressing Done (which pops back to
  /// Imaging) left the terminal state standing: re-entering Polar Alignment
  /// reopened straight onto last night's green "Alignment Complete" summary,
  /// with Restart as the only route back to the instructions — a wizard that
  /// says it succeeded when nothing has run. The result itself is already
  /// persisted to the History panel by the time the phase goes terminal, so
  /// nothing is lost. A run still in flight is deliberately untouched: coming
  /// back to a live measurement has to show the live measurement.
  void _releaseFinishedRun() {
    if (_phase != PolarAlignPhase.complete && _phase != PolarAlignPhase.error) {
      return;
    }
    final controller = _controller;
    if (controller == null) return;
    // After the tree settles: mutating a provider inside a widget's dispose can
    // land mid-teardown of the frame that removed the route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        controller.reset();
      } on PolarAlignmentBusyException {
        // The run's history row is still being written; the next entry clears
        // it. Never force a reset over an in-flight save.
      }
    });
  }

  /// Marks the Alignment History panel so the toggle can scroll to it.
  final GlobalKey _historyPanelKey = GlobalKey(debugLabel: 'polar_history');

  /// Bring the Alignment History panel into view after the toggle adds it to
  /// the bottom of the configuration column.
  ///
  /// Scrolls to the panel itself, not to the column's current end: the panel
  /// streams its rows in after it is first laid out, and on a phone the
  /// column is a tab page that is still sliding in, so the end measured on
  /// the first frame is short of where the panel finally sits. The panel may
  /// not be built for a few frames while that tab animates, hence the retry.
  void _revealHistoryPanel([int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final panel = _historyPanelKey.currentContext;
      if (panel == null || !_configScrollController.hasClients) {
        if (attempt < 30) _revealHistoryPanel(attempt + 1);
        return;
      }
      Scrollable.ensureVisible(
        panel,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _startAlignment() async {
    // A polar-axis error is decomposed into azimuth/altitude corrections using
    // the SITE latitude. The app installs a (0, 0) observer location at startup
    // so the native guard (`polar_align/mod.rs` refuses only when the location
    // is None) can never fire, and the wizard would happily print corrections
    // for an observer on the equator. Refuse here, alongside the camera / mount
    // / solver prerequisites.
    final settings = await ref.read(appSettingsProvider.future);
    if (!mounted) return;
    if (!settings.hasObserverLocation) {
      ref.read(polarAlignmentStateProvider.notifier).reset();
      context.showErrorSnackBar(
        'No observing location set. Polar error is measured relative to your '
        'site latitude — set an observing location in Settings first.',
      );
      return;
    }

    // Validate equipment is connected before starting
    final cameraState = ref.read(cameraStateProvider);
    final mountState = ref.read(mountStateProvider);

    if (cameraState.connectionState != DeviceConnectionState.connected) {
      ref.read(polarAlignmentStateProvider.notifier).reset();
      context.showErrorSnackBar(
        'Camera not connected. Please connect a camera before starting polar alignment.',
      );
      return;
    }

    if (mountState.connectionState != DeviceConnectionState.connected) {
      ref.read(polarAlignmentStateProvider.notifier).reset();
      context.showErrorSnackBar(
        'Mount not connected. Please connect a mount before starting polar alignment.',
      );
      return;
    }

    // The footer states this and the button is disabled for it, but a mount
    // that parks between build and click must still be told, not silently
    // obeyed: a parked mount cannot slew between the three measurement points
    // and is not pointing at sky, so the run would expose, fail to solve, and
    // report a solver timeout for a mount the app knew was parked.
    if (mountState.isParked) {
      ref.read(polarAlignmentStateProvider.notifier).reset();
      context.showErrorSnackBar(
        'Mount is parked — unpark it before aligning. A parked mount cannot '
        'slew between the three measurement points.',
      );
      return;
    }

    // Check the user's actual solver selection before either alignment mode
    // starts capturing or moving equipment. It is not enough for a different
    // solver to be installed when the selected one is unusable.
    try {
      await ref.read(plateSolveServiceProvider).ensureSolverAvailable();
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar(
        'Plate solver not ready. Check Plate Solving settings: $e',
      );
      return;
    }

    final mode = ref.read(polarAlignmentUiStateProvider).mode;
    final config = ref.read(polarAlignmentConfigProvider);
    if (mode == PolarAlignmentMode.allSky) {
      // All-sky routine: route through the single guarded state machine, which
      // transitions into the adjusting phase and calls the bridge
      // `apiStartAllSkyPolarAlignment` entry point. The backend raises a
      // structured "Plate solver required — install ASTAP" error when no solver
      // is configured; surface it directly.
      try {
        await ref
            .read(polarAlignmentStateProvider.notifier)
            .startAllSkyAlignment(config);
      } catch (e) {
        if (!mounted) return;
        context.showErrorSnackBar('All-sky polar alignment failed: $e');
      }
      return;
    }

    // TPPA: startAlignment now fails the awaited command on invalid config or
    // when a run is already active — surface it instead of letting it throw
    // uncaught. The error phase already reflects the reason on-screen.
    try {
      await ref.read(polarAlignmentControllerProvider).start();
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not start polar alignment: $e');
    }
  }

  /// True while a Stop is in flight. Teardown waits for the run to reach a
  /// checkpoint — an exposure or a plate solve, seconds either way — and an
  /// unchanged button over those seconds is what made Stop look ignored.
  bool _stopping = false;

  Future<void> _stopAlignment() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    try {
      await ref.read(polarAlignmentControllerProvider).stop();
    } catch (e) {
      if (!mounted) return;
      // Stop failed/timed out: the run stays blocked and visibly in error.
      context.showErrorSnackBar('Could not stop polar alignment: $e');
    } finally {
      if (mounted) setState(() => _stopping = false);
    }
  }

  Future<void> _completeAlignment() async {
    try {
      await ref.read(polarAlignmentControllerProvider).complete();
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not complete polar alignment: $e');
    }
  }

  void _resetAlignment() {
    final controller = ref.read(polarAlignmentControllerProvider);
    controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    // Pulse animation only ticks while alignment is running; otherwise it
    // burns a frame/sec for a status indicator that isn't visible.
    ref.listen<PolarAlignmentState>(polarAlignmentStateProvider, (prev, next) {
      final wasRunning = prev?.isRunning ?? false;
      if (next.isRunning && !wasRunning) {
        _pulseController.repeat(reverse: true);
      } else if (!next.isRunning && wasRunning) {
        _pulseController.stop();
      }
    });

    // A History toggle whose only effect is off-screen is indistinguishable
    // from a dead button, so scroll the panel it reveals into view. On the
    // compact (tabbed) layout the configuration column is a tab, so also select
    // it — the field is inert in the wide layout, where all three panels show.
    ref.listen<bool>(
      polarAlignmentUiStateProvider.select((s) => s.showHistoryPanel),
      (prev, next) {
        if (!next || prev == next) return;
        ref.read(polarAlignmentUiStateProvider.notifier).setCompactTabIndex(0);
        _revealHistoryPanel();
      },
    );

    // Surface config persistence failures truthfully — settings that failed to
    // save must not look persisted.
    ref.listen<String?>(polarAlignmentConfigSaveErrorProvider, (prev, next) {
      if (next != null && next != prev && mounted) {
        context.showErrorSnackBar(next);
      }
    });

    final colors = SkotiqColors.of(context);
    final state = ref.watch(polarAlignmentStateProvider);
    final config = ref.watch(polarAlignmentConfigProvider);

    // Snapshot for dispose, which cannot read `ref`.
    _controller = ref.read(polarAlignmentControllerProvider);
    _phase = state.phase;

    final isRunning = state.isRunning;

    return Scaffold(
      backgroundColor: colors.background,
      body: Column(
        children: [
          // The one page header. It carries the identity, the method switch,
          // the device chips and the screen's ONE primary — the footer bar
          // that used to hold the primary (and repeat every blocker beside it
          // in warning colour) is gone.
          _buildHeader(colors, isRunning),

          // Main content — responsive layout avoids squeezing the guide
          // column when embedded beside the app shell or on smaller displays.
          Expanded(
            child: PolarAlignmentBodyLayout(
              leftPanel: _buildLeftPanel(colors, state, config, isRunning),
              centerPanel: state.phase == PolarAlignPhase.idle
                  ? null
                  : _buildCenterPanel(colors, state, config),
              rightPanel: _buildRightPanel(colors, state, config),
            ),
          ),
        ],
      ),
    );
  }
}
