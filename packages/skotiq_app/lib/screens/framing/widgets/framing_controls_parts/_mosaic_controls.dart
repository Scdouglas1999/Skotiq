// Mosaic spinner, option buttons, start-corner selector and export button.
part of '../framing_controls.dart';

/// Integer spinner (label + -/+ buttons) used for mosaic columns / rows.
class FramingMosaicSpinner extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final SkotiqColors colors;

  const FramingMosaicSpinner({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              _SpinnerButton(
                icon: SkotiqIcons.remove,
                onTap: value > min ? () => onChanged(value - 1) : null,
                colors: colors,
              ),
              Expanded(
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              _SpinnerButton(
                icon: SkotiqIcons.add,
                onTap: value < max ? () => onChanged(value + 1) : null,
                colors: colors,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SpinnerButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final SkotiqColors colors;

  const _SpinnerButton({
    required this.icon,
    this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: SkotiqTokens.borderRadiusInline4,
      child: Container(
        padding: const EdgeInsets.all(8),
        child: Icon(
          icon,
          size: 14,
          color: onTap != null ? colors.textPrimary : colors.textMuted,
        ),
      ),
    );
  }
}

/// Selectable pill button (icon + label) used for mosaic capture pattern
/// options (Serpentine, Numbers).
class FramingOptionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const FramingOptionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  State<FramingOptionButton> createState() => _FramingOptionButtonState();
}

class _FramingOptionButtonState extends State<FramingOptionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? widget.colors.primary.withValues(alpha: 0.15)
                : _isHovered
                    ? widget.colors.well
                    : widget.colors.background,
            borderRadius: SkotiqTokens.borderRadiusMd,
            border: Border.all(
              color: widget.isSelected
                  ? widget.colors.primary.withValues(alpha: 0.5)
                  : widget.colors.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 12,
                color: widget.isSelected
                    ? widget.colors.primary
                    : widget.colors.textSecondary,
              ),
              const SizedBox(width: 6),
              // Flexible + ellipsis so the label never overflows a narrow
              // Expanded cell (e.g. the mosaic Serpentine/Numbers pair in a
              // ~270px phone-landscape controls panel).
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.caption.copyWith(
                    fontWeight:
                        widget.isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: widget.isSelected
                        ? widget.colors.primary
                        : widget.colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four-cell start-corner selector for the mosaic capture pattern.
class FramingStartCornerSelector extends StatelessWidget {
  final MosaicStartCorner selected;
  final ValueChanged<MosaicStartCorner> onChanged;
  final SkotiqColors colors;

  const FramingStartCornerSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          _CornerOption(
            corner: MosaicStartCorner.topLeft,
            label: 'TL',
            icon: LucideIcons.arrowUpLeft,
            isSelected: selected == MosaicStartCorner.topLeft,
            onTap: () => onChanged(MosaicStartCorner.topLeft),
            colors: colors,
          ),
          _CornerOption(
            corner: MosaicStartCorner.topRight,
            label: 'TR',
            icon: LucideIcons.arrowUpRight,
            isSelected: selected == MosaicStartCorner.topRight,
            onTap: () => onChanged(MosaicStartCorner.topRight),
            colors: colors,
          ),
          _CornerOption(
            corner: MosaicStartCorner.bottomLeft,
            label: 'BL',
            icon: LucideIcons.arrowDownLeft,
            isSelected: selected == MosaicStartCorner.bottomLeft,
            onTap: () => onChanged(MosaicStartCorner.bottomLeft),
            colors: colors,
          ),
          _CornerOption(
            corner: MosaicStartCorner.bottomRight,
            label: 'BR',
            icon: LucideIcons.arrowDownRight,
            isSelected: selected == MosaicStartCorner.bottomRight,
            onTap: () => onChanged(MosaicStartCorner.bottomRight),
            colors: colors,
          ),
        ],
      ),
    );
  }
}

class _CornerOption extends StatelessWidget {
  final MosaicStartCorner corner;
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _CornerOption({
    required this.corner,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected
                ? colors.primary.withValues(alpha: 0.15)
                : Colors.transparent,
            borderRadius: SkotiqTokens.borderRadiusInline4,
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 14,
                color: isSelected ? colors.primary : colors.textMuted,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: SkotiqTypography.caption.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? colors.primary : colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Gradient button that persists the framed mosaic as a DURABLE mosaic
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
  bool _isHovered = false;
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
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final isRemote = ref.watch(backendProvider) is NetworkBackend;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: _createProject,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: _isHovered
                ? widget.colors.primary.withValues(alpha: 0.92)
                : widget.colors.primary,
            borderRadius: SkotiqTokens.borderRadiusInline8,
            border: Border.all(
              color: widget.colors.primary.withValues(alpha: 0.85),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_isExporting)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: onPrimary,
                  ),
                )
              else
                Icon(
                  SkotiqIcons.download,
                  size: 14,
                  color: onPrimary,
                ),
              const SizedBox(width: 8),
              Text(
                _isExporting
                    ? 'Creating project...'
                    : isRemote
                        ? 'Create Mosaic Project on imaging host'
                        : 'Create Mosaic Project '
                            '(${widget.panels.length} panels)',
                style:
                    SkotiqTypography.labelStrongSm.copyWith(color: onPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
