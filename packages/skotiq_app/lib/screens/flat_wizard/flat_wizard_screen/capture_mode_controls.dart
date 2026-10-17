part of '../flat_wizard_screen.dart';

/// Padding shared by the three mode columns.
const EdgeInsets _controlsPadding = EdgeInsets.all(SkotiqTokens.space2xl);

/// Gap between two groups in a controls column (03 §3.1: section gap).
const double _groupGap = SkotiqTokens.space3xl;

// Quick capture controls

class _QuickCaptureControls extends ConsumerWidget {
  const _QuickCaptureControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final cameraConfig = ref.watch(flatCameraConfigProvider);

    // Label-to-the-LEFT form rows (05 §8), not a stack of h6 captions each
    // sitting above its control.
    return SingleChildScrollView(
      padding: _controlsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FormRow(label: 'Filter', child: _FilterSelector()),
          const SizedBox(height: FormRow.rowGap),
          // Camera settings the run will actually command.
          const FormRow(label: 'Camera', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              value: state.globalSettings.histogramTarget,
              onChanged: notifier.setHistogramTarget,
              config: cameraConfig,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Tolerance',
            child: _ToleranceSlider(
              value: state.globalSettings.tolerancePercent,
              onChanged: notifier.setTolerance,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Frames',
            child: _FrameCountInput(
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: _groupGap),
          const _ActionButtons(mode: FlatWizardMode.quick),
        ],
      ),
    );
  }
}

// Batch capture controls

class _BatchCaptureControls extends ConsumerWidget {
  const _BatchCaptureControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final cameraConfig = ref.watch(flatCameraConfigProvider);
    final isSelected = state.mode == FlatWizardMode.batch;

    return SingleChildScrollView(
      padding: _controlsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle(icon: LucideIcons.filter, title: 'Filters'),
          // Only the SELECTED tab claims the shared tutorial GlobalKeys: the
          // TabBarView keeps the outgoing tab mounted across a switch, and a
          // GlobalKey attached twice throws "specified multiple times in the
          // widget tree".
          _FilterChecklist(
            key: isSelected ? FlatWizardTutorialKeys.filterSelect : null,
          ),
          const SizedBox(height: _groupGap),
          const SectionTitle(
            icon: LucideIcons.sliders,
            title: 'Capture settings',
          ),
          const FormRow(label: 'Camera', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              key: isSelected ? FlatWizardTutorialKeys.targetAdu : null,
              value: state.globalSettings.histogramTarget,
              onChanged: notifier.setHistogramTarget,
              config: cameraConfig,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Tolerance',
            child: _ToleranceSlider(
              value: state.globalSettings.tolerancePercent,
              onChanged: notifier.setTolerance,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Frames',
            child: _FrameCountInput(
              key: isSelected ? FlatWizardTutorialKeys.frameCount : null,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: _groupGap),
          const _ActionButtons(mode: FlatWizardMode.batch),
        ],
      ),
    );
  }
}

// Sky flats controls

class _SkyFlatsControls extends ConsumerWidget {
  const _SkyFlatsControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final cameraConfig = ref.watch(flatCameraConfigProvider);
    final isSelected = state.mode == FlatWizardMode.skyFlats;

    return SingleChildScrollView(
      padding: _controlsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle(icon: LucideIcons.sunrise, title: 'Twilight'),
          _TwilightModeSelector(
            mode: state.twilightMode,
            onChanged: notifier.setTwilightMode,
          ),
          const SizedBox(height: _groupGap),
          SectionTitle(
            icon: LucideIcons.filter,
            title: 'Filters',
            trailing: SkotiqButton(
              label: 'Auto-order',
              icon: LucideIcons.arrowUpDown,
              // Reordering mid-run would invalidate the run's stable filter
              // indices, so the control is disabled while capturing.
              onPressed:
                  state.isCapturing ? null : notifier.autoOrderForTwilight,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
          ),
          _FilterChecklist(
            key: isSelected ? FlatWizardTutorialKeys.filterSelect : null,
          ),
          const SizedBox(height: _groupGap),
          const SectionTitle(
            icon: LucideIcons.sliders,
            title: 'Capture settings',
          ),
          const FormRow(label: 'Camera', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              key: isSelected ? FlatWizardTutorialKeys.targetAdu : null,
              value: state.globalSettings.histogramTarget,
              onChanged: notifier.setHistogramTarget,
              config: cameraConfig,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Tolerance',
            child: _ToleranceSlider(
              value: state.globalSettings.tolerancePercent,
              onChanged: notifier.setTolerance,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Frames',
            child: _FrameCountInput(
              key: isSelected ? FlatWizardTutorialKeys.frameCount : null,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: _groupGap),
          const _ActionButtons(mode: FlatWizardMode.skyFlats),
        ],
      ),
    );
  }
}
