// Mosaic start-corner selector and the create-project button.
part of '../framing_controls.dart';

/// The four start corners as one row of the panel's 28 px buttons.
class FramingStartCornerSelector extends StatelessWidget {
  final MosaicStartCorner selected;
  final ValueChanged<MosaicStartCorner> onChanged;

  const FramingStartCornerSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  static const List<(MosaicStartCorner, String, String)> _corners = [
    (MosaicStartCorner.topLeft, 'TL', 'Start top left'),
    (MosaicStartCorner.topRight, 'TR', 'Start top right'),
    (MosaicStartCorner.bottomLeft, 'BL', 'Start bottom left'),
    (MosaicStartCorner.bottomRight, 'BR', 'Start bottom right'),
  ];

  @override
  Widget build(BuildContext context) {
    return NightPanelGrid(
      columns: 4,
      children: [
        for (final (corner, label, semantic) in _corners)
          Tooltip(
            message: semantic,
            child: NightPanelButton(
              label: label,
              semanticLabel: semantic,
              selected: selected == corner,
              onPressed: () => onChanged(corner),
            ),
          ),
      ],
    );
  }
}

/// Button that persists the framed mosaic as a DURABLE mosaic
/// project (the same `mosaic_projects` + per-panel `mosaic_panels`/`targets`
/// structure the mosaic wizard's "Create Project" writes) and routes the user
/// to the project screen (`/mosaic/:id`) so the scheduler/sequencer can consume
/// it.
///
/// A durable project rather than orphaned `targets` rows (`objectType:
/// 'mosaic'`), because only a project can be driven by a sequence. The grid
/// geometry is taken from the live framing state via
/// [FramingNotifier.createDurableMosaicProject], so the persisted project
/// matches the panels shown on the canvas.
class FramingExportMosaicButton extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final List<FramingMosaicPanel> panels;
  final String targetName;

  const FramingExportMosaicButton({
    super.key,
    required this.colors,
    required this.panels,
    required this.targetName,
  });

  @override
  ConsumerState<FramingExportMosaicButton> createState() =>
      _FramingExportMosaicButtonState();
}

class _FramingExportMosaicButtonState
    extends ConsumerState<FramingExportMosaicButton> {
  bool _isExporting = false;

  Future<void> _createProject() async {
    if (_isExporting || widget.panels.isEmpty) return;
    if (ref.read(backendProvider) is NetworkBackend) {
      context.showInfoSnackBar(
        'Create durable mosaic projects on the imaging host.',
      );
      return;
    }

    setState(() => _isExporting = true);

    try {
      // Persist the framed grid as a durable mosaic project (project row +
      // per-panel target/panel rows) rather than orphaned target rows, then
      // route to the project screen so the scheduler/sequencer can drive it.
      final projectId = await ref
          .read(framingProvider.notifier)
          .createDurableMosaicProject(name: widget.targetName);

      if (!mounted) return;
      if (projectId == null) {
        context.showErrorSnackBar(
          'Could not create mosaic project: no framed target or rig field of '
          'view available.',
        );
        return;
      }

      context.showSuccessSnackBar(
          'Created mosaic project with ${widget.panels.length} panels');
      unawaited(context.push('/mosaic/$projectId'));
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not create mosaic project: $e');
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    return SkotiqButton(
      label: _isExporting
          ? 'Creating project...'
          : isRemote
              ? 'Create mosaic project on imaging host'
              : 'Create mosaic project (${widget.panels.length} panels)',
      icon: SkotiqIcons.layoutGrid,
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
      isLoading: _isExporting,
      onPressed: _isExporting ? null : _createProject,
    );
  }
}
