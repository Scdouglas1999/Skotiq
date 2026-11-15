part of '../flat_wizard_screen.dart';

/// Gap between two panels of the settings column.
const double _panelGap = SkotiqTokens.spaceLg;

/// Label column of every form row in the settings column.
const double _formLabelWidth = 136;

/// The settings of the mode on show, as a column of panels: what the last run
/// left to say or do, then the filters, the exposure search and the camera.
class _ControlsColumn extends ConsumerWidget {
  const _ControlsColumn();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasMessage = ref.watch(flatWizardProvider
        .select((s) => s.errorMessage != null || s.warningMessage != null));
    final isCapturing =
        ref.watch(flatWizardProvider.select((s) => s.isCapturing));
    final hasRunOutput = !ref.watch(flatRunOutputProvider).isEmpty;

    final panels = <Widget>[
      if (hasMessage) const _RunBanners(),
      // The run's finish: its flats become masters in the library.
      if (!isCapturing && hasRunOutput) const FlatBuildMasterStep(),
      const _PerFilterPanel(),
      const _ExposurePanel(),
      const _CameraPanel(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < panels.length; i++) ...[
          if (i > 0) const SizedBox(height: _panelGap),
          panels[i],
        ],
      ],
    );
  }
}
