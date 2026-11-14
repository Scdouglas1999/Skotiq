part of '../flat_wizard_screen.dart';

/// Padding shared by the three mode columns.
const EdgeInsets _controlsPadding = EdgeInsets.all(SkotiqTokens.spaceLg);

/// Gap between two groups in a controls column (03 §3.1: section gap).
const double _groupGap = SkotiqTokens.spaceLg;

class _QuickCaptureControls extends ConsumerWidget {
  const _QuickCaptureControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(flatWizardProvider);
    final notifier = ref.read(flatWizardProvider.notifier);
    final cameraConfig = ref.watch(flatCameraConfigProvider);
    // Only the mode on show carries the tour targets: the tab view keeps the
    // outgoing mode mounted across a switch.
    final isSelected = state.mode == FlatWizardMode.quick;

    // Label-to-the-LEFT form rows (05 §8), not a stack of h6 captions each
    // sitting above its control.
    return SingleChildScrollView(
      padding: _controlsPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormRow(
            label: 'Filter',
            child: _FilterSelector(
              key: isSelected ? TourTarget.flatFilterSelect.key : null,
            ),
          ),
          if (state.filterSettings.isNotEmpty)
            _FilterSettingsRow(
                index: state.currentFilterIndex
                    .clamp(0, state.filterSettings.length - 1)),
          const SizedBox(height: FormRow.rowGap),
          // Camera settings the run will actually command.
          const FormRow(
              label: 'Camera settings', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              key: isSelected ? TourTarget.flatTargetAdu.key : null,
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
              key: isSelected ? TourTarget.flatFrameCount.key : null,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          const _CalibrationAttemptsRow(),
          const SizedBox(height: _groupGap),
        ],
      ),
    );
  }
}

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
            key: isSelected ? TourTarget.flatFilterSelect.key : null,
          ),
          const SizedBox(height: _groupGap),
          const SectionTitle(
            icon: LucideIcons.sliders,
            title: 'Capture settings',
          ),
          const FormRow(
              label: 'Camera settings', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              key: isSelected ? TourTarget.flatTargetAdu.key : null,
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
              key: isSelected ? TourTarget.flatFrameCount.key : null,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          const _CalibrationAttemptsRow(),
          const SizedBox(height: _groupGap),
        ],
      ),
    );
  }
}

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
            key: isSelected ? TourTarget.flatFilterSelect.key : null,
          ),
          const SizedBox(height: _groupGap),
          const SectionTitle(
            icon: LucideIcons.sliders,
            title: 'Capture settings',
          ),
          const FormRow(
              label: 'Camera settings', child: _CaptureConfigSummary()),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Histogram target',
            child: _HistogramTargetSlider(
              key: isSelected ? TourTarget.flatTargetAdu.key : null,
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
              key: isSelected ? TourTarget.flatFrameCount.key : null,
              value: state.globalSettings.frameCount,
              onChanged: notifier.setFrameCount,
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          const _CalibrationAttemptsRow(),
          const SizedBox(height: _groupGap),
        ],
      ),
    );
  }
}
