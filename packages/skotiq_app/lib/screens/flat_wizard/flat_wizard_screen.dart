import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/path_tail.dart';
import '../../tours/tour_target.dart';
import 'flat_failure_diagnosis.dart';
import 'widgets/flat_build_master_step.dart';
import 'widgets/flat_wizard_panel.dart';
import 'widgets/flat_wizard_split_view.dart';
import 'widgets/flat_preview_panel.dart';
import 'widgets/save_path_dialog.dart';
import '../../widgets/sensitivity_field.dart';

part 'flat_wizard_screen/capture_mode_controls.dart';
part 'flat_wizard_screen/filter_controls.dart';
part 'flat_wizard_screen/tuning_controls.dart';
part 'flat_wizard_screen/header_actions.dart';

/// Flats for one filter, a batch of filters, or the twilight sky: the run's
/// settings in a column of panels on the left, the frame and its results on
/// the right, and the run's start and stop in the page header.
class FlatWizardScreen extends ConsumerStatefulWidget {
  const FlatWizardScreen({super.key});

  @override
  ConsumerState<FlatWizardScreen> createState() => _FlatWizardScreenState();
}

class _FlatWizardScreenState extends ConsumerState<FlatWizardScreen> {
  /// Below this window width the save folder is an icon, so the mode tabs
  /// keep their labels.
  static const double _folderLabelMinWidth = 1100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(flatWizardProvider.notifier).loadFilters();
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(flatWizardProvider.select((s) => s.mode));
    final isCapturing =
        ref.watch(flatWizardProvider.select((s) => s.isCapturing));
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width < ShellChromeMetrics.shellLayoutBreakpoint;

    return Column(
      children: [
        PageHeader(
          key: TourTarget.flatModeTabs.key,
          icon: LucideIcons.sun,
          title: 'Flat wizard',
          tabs: AdaptiveTabBar(
            tabs: const [
              AdaptiveTab(label: 'Quick capture', icon: LucideIcons.zap),
              AdaptiveTab(
                label: 'Multi-filter batch',
                icon: LucideIcons.layers,
              ),
              AdaptiveTab(label: 'Sky flats', icon: LucideIcons.sunrise),
            ],
            selectedIndex: mode.index,
            // The tabs stay live during a run so its settings can be read; the
            // run took its mode when it started.
            onSelected: (i) => ref
                .read(flatWizardProvider.notifier)
                .setMode(FlatWizardMode.values[i]),
          ),
          actions: <Widget>[
            // The Stop button already says a run is on; a phone header has no
            // room for both.
            if (isCapturing && !narrow)
              const SkotiqChip(
                label: 'Capturing',
                tone: ChipTone.success,
                dot: true,
              ),
            _SaveFolderButton(compact: width < _folderLabelMinWidth),
            const _RunButton(),
          ],
        ),
        Expanded(
          child: FlatWizardSplitView(
            controlsPanel: const _ControlsColumn(),
            previewPanel: FlatPreviewPanel(key: TourTarget.flatPreview.key),
          ),
        ),
      ],
    );
  }
}
