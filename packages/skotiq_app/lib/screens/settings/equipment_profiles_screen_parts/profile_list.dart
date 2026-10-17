part of '../equipment_profiles_screen.dart';

class _ProfileList extends StatelessWidget {
  final List<EquipmentProfileModel> profiles;
  final EquipmentProfileModel? selectedProfile;
  final EquipmentProfileModel? activeProfile;
  final ValueChanged<EquipmentProfileModel> onProfileSelected;
  final VoidCallback onCreateProfile;
  final VoidCallback? onImportProfiles;
  final bool isImportingProfiles;
  final bool isMobile;

  const _ProfileList({
    required this.profiles,
    required this.selectedProfile,
    required this.activeProfile,
    required this.onProfileSelected,
    required this.onCreateProfile,
    required this.onImportProfiles,
    required this.isImportingProfiles,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final padding = isMobile ? 16.0 : 20.0;

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header - hide on mobile since parent shows it
        if (!isMobile)
          Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Equipment profiles',
                  style: SkotiqTypography.pageTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Manage your imaging rigs and configurations',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),

        // Actions
        Padding(
          padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 16),
          child: Row(
            children: [
              Expanded(
                child: SkotiqButton(
                  label: 'New profile',
                  icon: LucideIcons.plus,
                  variant: ButtonVariant.primary,
                  onPressed: onCreateProfile,
                ),
              ),
              const SizedBox(width: 8),
              // The spinner keeps the button's footprint while the import runs,
              // so the row beside "New profile" does not reflow.
              if (isImportingProfiles)
                SizedBox.square(
                  dimension: SkotiqTokens.iconButtonSize,
                  child: Tooltip(
                    message: 'Importing profiles…',
                    child: Padding(
                      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.primary,
                      ),
                    ),
                  ),
                )
              else
                SkotiqIconButton(
                  icon: LucideIcons.download,
                  tooltip: 'Import profiles',
                  onPressed: onImportProfiles,
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Profile list
        Expanded(
          child: profiles.isEmpty
              ? Center(
                  child: Text(
                    'No profiles yet',
                    style: SkotiqTypography.body.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 12),
                  itemCount: profiles.length,
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    final isSelected =
                        !isMobile && profile.id == selectedProfile?.id;
                    final isActive = profile.id == activeProfile?.id;

                    return _ProfileListItem(
                      profile: profile,
                      isSelected: isSelected,
                      isActive: isActive,
                      isMobile: isMobile,
                      onTap: () => onProfileSelected(profile),
                    );
                  },
                ),
        ),
      ],
    );

    // On mobile, just return the content without fixed width
    if (isMobile) {
      return content;
    }

    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(right: BorderSide(color: colors.border)),
      ),
      child: content,
    );
  }
}

class _ProfileListItem extends StatefulWidget {
  final EquipmentProfileModel profile;
  final bool isSelected;
  final bool isActive;
  final VoidCallback onTap;
  final bool isMobile;

  const _ProfileListItem({
    required this.profile,
    required this.isSelected,
    required this.isActive,
    required this.onTap,
    this.isMobile = false,
  });

  @override
  State<_ProfileListItem> createState() => _ProfileListItemState();
}

class _ProfileListItemState extends State<_ProfileListItem> {
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
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? SkotiqColors.of(context).primary.withValues(alpha: 0.1)
                : _isHovered
                    ? SkotiqColors.of(context).well
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            border: widget.isSelected
                ? Border.all(
                    color:
                        SkotiqColors.of(context).primary.withValues(alpha: 0.3))
                : null,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.isActive
                      ? SkotiqColors.of(context).primary.withValues(alpha: 0.2)
                      : SkotiqColors.of(context).well,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
                child: Icon(
                  LucideIcons.aperture,
                  size: 18,
                  color: widget.isActive
                      ? SkotiqColors.of(context).primary
                      : SkotiqColors.of(context).textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.profile.name,
                            style: SkotiqTypography.labelStrong.copyWith(
                                color: SkotiqColors.of(context).textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.isActive) ...[
                          const SizedBox(width: 8),
                          // Flexible, not fixed: the badge label is an 11 px
                          // eyebrow now, and two of them beside a long profile
                          // name overflowed the row by 5 px. The name shrinks
                          // first (it is Expanded); these give way after it.
                          Flexible(
                            child: _ProfileBadge(
                              label: 'Active',
                              color: SkotiqColors.of(context).primary,
                            ),
                          ),
                        ],
                        // "Active" and "startup default" are different flags —
                        // auto-connect reads the default, so the operator has
                        // to be able to see which row that is.
                        if (widget.profile.isDefault) ...[
                          const SizedBox(width: 4),
                          Flexible(
                            child: _ProfileBadge(
                              label: 'Default',
                              color: SkotiqColors.of(context).textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (widget.profile.description != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.profile.description!,
                        style: SkotiqTypography.captionSm.copyWith(
                          color: SkotiqColors.of(context).textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _ProfileBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: SkotiqTypography.eyebrow.copyWith(
          color: color,
        ),
      ),
    );
  }
}

// Profile details
