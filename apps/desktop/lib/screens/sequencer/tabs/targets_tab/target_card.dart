part of '../targets_tab.dart';

class _TargetCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final dynamic
  target; // Using dynamic since Target is a database generated type

  const _TargetCard({required this.colors, required this.target});

  @override
  ConsumerState<_TargetCard> createState() => _TargetCardState();
}

class _TargetCardState extends ConsumerState<_TargetCard> {
  bool _isHovered = false;
  bool _isExpanded = false;

  IconData _getTypeIcon() {
    switch (widget.target.objectType) {
      case 'Galaxy':
        return LucideIcons.sparkles;
      case 'Nebula':
        return LucideIcons.cloud;
      case 'Cluster':
        return LucideIcons.sparkle;
      case 'Star':
        return LucideIcons.star;
      case 'Planet':
        return LucideIcons.globe;
      default:
        return LucideIcons.circle;
    }
  }

  Color _getTypeColor() {
    switch (widget.target.objectType) {
      case 'Galaxy':
        return widget.colors.accent;
      case 'Nebula':
        return widget.colors.info;
      case 'Cluster':
        return widget.colors.warning;
      case 'Star':
        return widget.colors.success;
      case 'Planet':
        return widget.colors.error;
      default:
        return widget.colors.textMuted;
    }
  }

  String _formatIntegration(double secs) {
    final hours = (secs / 3600).floor();
    final minutes = ((secs % 3600) / 60).floor();
    return '${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final typeColor = _getTypeColor();

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: widget.colors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _isHovered
                ? typeColor.withValues(alpha: 0.5)
                : widget.colors.border,
            width: _isHovered ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            // Main content
            InkWell(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Icon
                    Container(
                      width: 48,
                      height: 48,
                      decoration: SkotiqDecorations.iconChip(
                        typeColor,
                        borderRadius: BorderRadius.circular(8),
                        bordered: false,
                      ),
                      child: Icon(_getTypeIcon(), size: 24, color: typeColor),
                    ),
                    const SizedBox(width: 16),

                    // Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.target.catalogId ?? widget.target.name,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: widget.colors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                              if (widget.target.catalogId != null) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    widget.target.name,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: widget.colors.textSecondary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: typeColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  widget.target.objectType ?? 'Object',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: typeColor,
                                  ),
                                ),
                              ),
                              if (widget.target.isFavorite) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  LucideIcons.heart,
                                  size: 14,
                                  color: widget.colors.error,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 16,
                            runSpacing: 4,
                            children: [
                              _InfoChip(
                                colors: widget.colors,
                                label: 'RA',
                                value: CoordinateFormat.ra(
                                  widget.target.ra,
                                  seconds: SecondsPrecision.integerRounded,
                                ),
                              ),
                              _InfoChip(
                                colors: widget.colors,
                                label: 'Dec',
                                value: CoordinateFormat.dec(
                                  widget.target.dec,
                                  seconds: SecondsPrecision.integerRounded,
                                ),
                              ),
                              if (widget.target.magnitude != null)
                                _InfoChip(
                                  colors: widget.colors,
                                  label: 'Mag',
                                  value: widget.target.magnitude!
                                      .toStringAsFixed(1),
                                ),
                              if (widget.target.constellation != null)
                                _InfoChip(
                                  colors: widget.colors,
                                  label: 'Con',
                                  value: widget.target.constellation!,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // Stats
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            Icon(
                              LucideIcons.camera,
                              size: 12,
                              color: widget.colors.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${widget.target.capturedSubs ?? 0} subs',
                              style: TextStyle(
                                fontSize: 11,
                                color: widget.colors.textSecondary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              LucideIcons.timer,
                              size: 12,
                              color: widget.colors.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatIntegration(
                                widget.target.totalIntegrationSecs ?? 0,
                              ),
                              style: TextStyle(
                                fontSize: 11,
                                color: widget.colors.textSecondary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(width: 16),

                    // Actions
                    if (_isHovered) ...[
                      _IconButton(
                        colors: widget.colors,
                        icon: widget.target.isFavorite
                            ? LucideIcons.heart
                            : LucideIcons.heartHandshake,
                        tooltip: 'Toggle Favorite',
                        color: widget.colors.error,
                        onPressed: () {
                          ref
                              .read(targetsDaoProvider)
                              .toggleFavorite(widget.target.id);
                        },
                      ),
                      _IconButton(
                        colors: widget.colors,
                        icon: LucideIcons.crosshair,
                        tooltip: 'Add to Sequence',
                        onPressed: () {
                          // Add target to sequence
                          ref
                              .read(currentSequenceProvider.notifier)
                              .addNode(
                                TargetHeaderNode(
                                  targetName:
                                      widget.target.catalogId ??
                                      widget.target.name,
                                  raHours: widget.target.ra,
                                  decDegrees: widget.target.dec,
                                ),
                              );
                        },
                      ),
                      _IconButton(
                        colors: widget.colors,
                        icon: LucideIcons.pencil,
                        tooltip: 'Edit',
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) =>
                                EditTargetDialog(target: widget.target),
                          );
                        },
                      ),
                      _IconButton(
                        colors: widget.colors,
                        icon: LucideIcons.trash2,
                        tooltip: 'Delete',
                        color: widget.colors.error,
                        onPressed: () {
                          ref
                              .read(targetsDaoProvider)
                              .deleteTarget(widget.target.id);
                        },
                      ),
                    ],

                    Icon(
                      _isExpanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 16,
                      color: widget.colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),

            // Expanded content
            AnimatedCrossFade(
              firstChild: Container(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(color: widget.colors.border),
                    const SizedBox(height: 12),
                    if (widget.target.notes != null &&
                        widget.target.notes!.isNotEmpty) ...[
                      Text(
                        'Notes',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: widget.colors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.target.notes!,
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: SkotiqButton(
                            label: 'Add to Sequence',
                            icon: LucideIcons.plus,
                            onPressed: () {
                              ref
                                  .read(currentSequenceProvider.notifier)
                                  .addNode(
                                    TargetHeaderNode(
                                      targetName:
                                          widget.target.catalogId ??
                                          widget.target.name,
                                      raHours: widget.target.ra,
                                      decDegrees: widget.target.dec,
                                    ),
                                  );
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: SkotiqButton(
                            label: 'Slew to Target',
                            icon: LucideIcons.navigation,
                            variant: ButtonVariant.outline,
                            onPressed: () async {
                              try {
                                final deviceService = ref.read(
                                  deviceServiceProvider,
                                );
                                await deviceService.slewMountToCoordinates(
                                  widget.target.ra,
                                  widget.target.dec,
                                );

                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Slewing to ${widget.target.name}',
                                      ),
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Failed to slew: $e'),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              secondChild: const SizedBox.shrink(),
              crossFadeState: _isExpanded
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              duration: const Duration(milliseconds: 200),
            ),
          ],
        ),
      ),
    );
  }
}
