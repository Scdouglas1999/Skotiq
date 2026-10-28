import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../widgets/tutorial_keys/flat_wizard_keys.dart';
import 'flat_failure_diagnosis.dart';
import 'widgets/flat_build_master_step.dart';
import 'widgets/flat_wizard_split_view.dart';
import 'widgets/flat_preview_panel.dart';
import 'widgets/save_path_dialog.dart';

part 'flat_wizard_screen/capture_mode_controls.dart';
part 'flat_wizard_screen/filter_controls.dart';
part 'flat_wizard_screen/tuning_controls.dart';
part 'flat_wizard_screen/action_buttons.dart';

class FlatWizardScreen extends ConsumerStatefulWidget {
  const FlatWizardScreen({super.key});

  @override
  ConsumerState<FlatWizardScreen> createState() => _FlatWizardScreenState();
}

class _FlatWizardScreenState extends ConsumerState<FlatWizardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 3,
        vsync: this,
        initialIndex: ref.read(flatWizardProvider).mode.index);
    _tabController.addListener(_onTabChanged);

    // Load filters on first build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(flatWizardProvider.notifier).loadFiltersFromWheel();
    });
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final mode = switch (_tabController.index) {
      0 => FlatWizardMode.quick,
      1 => FlatWizardMode.batch,
      2 => FlatWizardMode.skyFlats,
      _ => FlatWizardMode.quick,
    };
    ref.read(flatWizardProvider.notifier).setMode(mode);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(flatWizardProvider);

    return Column(
      children: [
        // One 56px page header (04 §4): title, underline mode tabs, and the
        // live "Capturing" chip as the header's action. This was a bespoke
        // 'surface' bar with the title folded inline beside the tab strip.
        PageHeader(
          key: FlatWizardTutorialKeys.tabs,
          icon: LucideIcons.sun,
          title: 'Flat wizard',
          tabs: AnimatedBuilder(
            animation: _tabController,
            builder: (context, _) => AdaptiveTabBar(
              tabs: const [
                AdaptiveTab(label: 'Quick capture', icon: LucideIcons.zap),
                AdaptiveTab(
                  label: 'Multi-filter batch',
                  icon: LucideIcons.layers,
                ),
                AdaptiveTab(label: 'Sky flats', icon: LucideIcons.sunrise),
              ],
              selectedIndex: _tabController.index,
              onSelected: (i) => _tabController.animateTo(i),
            ),
          ),
          actions: <Widget>[
            // The kit chip, not a bespoke radiusXl outlined capsule with a
            // spinner in it: 05 §10 gives status one shape.
            if (state.isCapturing)
              const SkotiqChip(
                label: 'Capturing',
                tone: ChipTone.success,
                dot: true,
              ),
          ],
        ),

        // Split view content
        Expanded(
          child: FlatWizardSplitView(
            controlsPanel: Column(children: [
              Expanded(
                  child: TabBarView(
                controller: _tabController,
                children: const [
                  _QuickCaptureControls(),
                  _BatchCaptureControls(),
                  _SkyFlatsControls(),
                ],
              )),
              Padding(
                padding: _controlsPadding,
                child: _ActionButtons(mode: state.mode),
              ),
            ]),
            previewPanel: FlatPreviewPanel(key: FlatWizardTutorialKeys.preview),
          ),
        ),
      ],
    );
  }
}
