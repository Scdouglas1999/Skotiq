part of '../framing_sidebar.dart';

/// The Rotation section: exact angle entry, ±1 / ±90 steps and the slider.
/// Rotation needs the camera's field, so it is disabled until a profile
/// resolves.
class FramingRotationSection extends ConsumerWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingRotationSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasEquipment = equipmentAsync.valueOrNull?.isReady ?? false;
    return FramingPanelSection(
      title: 'Rotation',
      note: hasEquipment ? null : 'Needs a camera',
      children: [
        FramingRotationField(
          key: FramingTutorialKeys.rotation,
          value: framingState.rotation,
          colors: colors,
          onChanged: hasEquipment
              ? (value) => ref.read(framingProvider.notifier).setRotation(value)
              : null,
        ),
      ],
    );
  }
}

/// The Sky view section: what the canvas shows. Survey, preview field of
/// view, the camera-field overlay, the Grid / Labels / Directions layers, and
/// the survey image's own actions (reload it, cache it to disk).
class FramingSkyViewSection extends ConsumerWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;
  final VoidCallback onCacheImage;

  const FramingSkyViewSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentAsync,
    required this.onCacheImage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = equipmentAsync.valueOrNull;
    final equipment = result?.equipment;
    final hasEquipment = result?.isReady ?? false;
    final notifier = ref.read(framingProvider.notifier);
    final hasTarget = framingState.target != null;
    final hasSurveyImage = framingState.surveyImageBytes != null;

    final String? surveyNote;
    final Color? surveyNoteColor;
    if (framingState.isLoadingImage) {
      surveyNote = 'Loading…';
      surveyNoteColor = null;
    } else if (framingState.imageError != null) {
      surveyNote = 'Image failed';
      surveyNoteColor = colors.error;
    } else {
      surveyNote = framingState.surveySource.displayName;
      surveyNoteColor = null;
    }

    return FramingPanelSection(
      title: 'Sky view',
      note: surveyNote,
      noteColor: surveyNoteColor,
      collapsible: true,
      children: [
        // The sky is browsable without a profile, so these stay live.
        FramingFormRow(
          label: 'Survey',
          child: SkotiqDropdown(
            value: framingState.surveySource.name,
            isExpanded: true,
            items: SurveySource.values.map((s) => s.name).toList(),
            itemLabels: SurveySource.values.map((s) => s.displayName).toList(),
            onChanged: (name) {
              if (name == null) return;
              notifier.setSurveySource(SurveySource.values.byName(name));
            },
          ),
        ),
        if (framingState.imageError case final error?)
          FramingNote(error, color: colors.error, icon: SkotiqIcons.warning),
        FramingPreviewFovSlider(
          colors: colors,
          value: framingState.previewFovDegrees,
          hasEquipment: hasEquipment,
          equipmentFov: equipment?.fovWidthDeg,
          onChanged: notifier.setPreviewFov,
        ),
        // Only when the preview is wider than the camera's own field.
        if (hasEquipment &&
            equipment != null &&
            framingState.previewFovDegrees > equipment.fovWidthDeg)
          FramingEquipmentFovOverlayControls(
            colors: colors,
            showOverlay: framingState.showEquipmentFovOverlay,
            opacity: framingState.equipmentFovOverlayOpacity,
            onToggle: notifier.toggleEquipmentFovOverlay,
            onOpacityChanged: notifier.setEquipmentFovOverlayOpacity,
          ),
        // The canvas layers as one row of toggles across the full width, so
        // "Directions" fits at the column's 250 px minimum.
        NightPanelGrid(
          columns: 3,
          children: [
            NightPanelButton(
              label: 'Grid',
              semanticLabel: 'Show coordinate grid',
              selected: framingState.showGrid,
              onPressed: notifier.toggleGrid,
            ),
            NightPanelButton(
              label: 'Labels',
              semanticLabel: 'Show object labels',
              selected: framingState.showLabels,
              onPressed: notifier.toggleLabels,
            ),
            NightPanelButton(
              label: 'Directions',
              semanticLabel: 'Show sky directions',
              selected: framingState.showCardinalDirections,
              disabledReason: 'Needs a camera',
              onPressed:
                  hasEquipment ? notifier.toggleCardinalDirections : null,
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        NightPanelGrid(
          columns: 2,
          children: [
            NightPanelButton(
              label: 'Reload image',
              disabledReason: 'Pick a target first',
              onPressed: hasTarget ? notifier.loadSurveyImage : null,
            ),
            NightPanelButton(
              label: 'Cache image',
              disabledReason: 'Wait for the survey image to load',
              onPressed: hasSurveyImage ? onCacheImage : null,
            ),
          ],
        ),
      ],
    );
  }
}
