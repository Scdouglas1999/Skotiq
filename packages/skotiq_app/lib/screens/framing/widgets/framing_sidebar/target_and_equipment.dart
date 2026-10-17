part of '../framing_sidebar.dart';

/// Target search section: SIMBAD-backed name search, results dropdown, and
/// manual RA/Dec entry fields. The controllers are owned by the parent screen
/// so navigating away and back preserves the input state.
class FramingTargetSearch extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetSearchState searchState;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final TextEditingController raController;
  final TextEditingController decController;
  final ValueChanged<FramingTarget> onTargetSelected;
  final ValueChanged<String> onResolveByName;
  final VoidCallback onGoToManualCoordinates;

  const FramingTargetSearch({
    super.key,
    required this.colors,
    required this.searchState,
    required this.searchController,
    required this.searchFocusNode,
    required this.raController,
    required this.decController,
    required this.onTargetSelected,
    required this.onResolveByName,
    required this.onGoToManualCoordinates,
  });

  IconData _iconForType(TargetType? type) {
    switch (type) {
      case TargetType.galaxy:
        return SkotiqIcons.circle;
      case TargetType.nebula:
        return SkotiqIcons.cloud;
      case TargetType.cluster:
        return SkotiqIcons.sparkle;
      case TargetType.star:
        return SkotiqIcons.star;
      case TargetType.planet:
        return SkotiqIcons.globe;
      default:
        return SkotiqIcons.target;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            icon: SkotiqIcons.target,
            title: 'Target',
          ),
          TextField(
            key: FramingTutorialKeys.targetSearch,
            controller: searchController,
            focusNode: searchFocusNode,
            style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: 'Search by name (M42, NGC7000, Orion)',
              hintStyle:
                  SkotiqTypography.caption.copyWith(color: colors.textMuted),
              prefixIcon:
                  Icon(SkotiqIcons.search, size: 14, color: colors.textMuted),
              suffixIcon: searchState.isSearching
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: SkotiqSpinner(size: 14, color: colors.primary),
                    )
                  : searchController.text.isNotEmpty
                      ? SkotiqIconButton(
                          icon: SkotiqIcons.close,
                          tooltip: 'Clear search',
                          size: IconButtonSize.sm,
                          onPressed: () {
                            searchController.clear();
                            ref.read(targetSearchProvider.notifier).clear();
                          },
                        )
                      : null,
              filled: true,
              fillColor: colors.well,
              border: OutlineInputBorder(
                borderRadius: SkotiqTokens.borderRadiusInline8,
                borderSide: BorderSide(color: colors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: SkotiqTokens.borderRadiusInline8,
                borderSide: BorderSide(color: colors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: SkotiqTokens.borderRadiusInline8,
                borderSide: BorderSide(color: colors.primary),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            onChanged: (value) {
              ref.read(targetSearchProvider.notifier).search(value);
            },
            onSubmitted: (value) {
              if (searchState.results.isNotEmpty) {
                onTargetSelected(searchState.results.first);
              } else if (value.isNotEmpty) {
                onResolveByName(value);
              }
            },
          ),

          if (searchState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      searchState.errorMessage!,
                      style: SkotiqTypography.labelQuiet.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: searchState.isSearching
                        ? null
                        : () => ref.read(targetSearchProvider.notifier).retry(),
                    icon: const Icon(SkotiqIcons.refresh, size: 13),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),

          // Search results dropdown
          if (searchState.results.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 4),
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: colors.well,
                borderRadius: SkotiqTokens.borderRadiusInline8,
                border: Border.all(color: colors.border),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: searchState.results.length,
                itemBuilder: (context, index) {
                  final target = searchState.results[index];
                  return InkWell(
                    onTap: () => onTargetSelected(target),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            _iconForType(target.type),
                            size: 14,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  target.name,
                                  style: SkotiqTypography.labelQuiet
                                      .copyWith(color: colors.textPrimary),
                                ),
                                if (target.catalogId != null &&
                                    target.catalogId != target.name)
                                  Text(
                                    target.catalogId!,
                                    style: SkotiqTypography.caption
                                        .copyWith(color: colors.textMuted),
                                  ),
                              ],
                            ),
                          ),
                          if (target.magnitude != null)
                            Text(
                              'mag ${target.magnitude!.toStringAsFixed(1)}',
                              style: SkotiqTypography.caption
                                  .copyWith(color: colors.textSecondary),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          // Manual coordinate entry
          const SizedBox(height: SkotiqTokens.spaceMd),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: raController,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'RA',
                    labelStyle: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                    hintText: '05h 35m 17s',
                    hintStyle: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                    filled: true,
                    fillColor: colors.well,
                    border: OutlineInputBorder(
                      borderRadius: SkotiqTokens.borderRadiusMd,
                      borderSide: BorderSide(color: colors.border),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: decController,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Dec',
                    labelStyle: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                    hintText: '-05° 23\' 28"',
                    hintStyle: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted),
                    filled: true,
                    fillColor: colors.well,
                    border: OutlineInputBorder(
                      borderRadius: SkotiqTokens.borderRadiusMd,
                      borderSide: BorderSide(color: colors.border),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FramingSmallIconButton(
                icon: SkotiqIcons.arrowRight,
                tooltip: 'Go to coordinates',
                colors: colors,
                onTap: onGoToManualCoordinates,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Equipment summary section in the side panel: a [SectionTitle] with a status
/// chip, then either the profile's key/value summary or the single
/// [SkotiqBanner] for the current `EquipmentStatus` (noProfile /
/// noFocalLength / noCameraSpecs).
class FramingEquipmentSection extends StatelessWidget {
  final SkotiqColors colors;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingEquipmentSection({
    super.key,
    required this.colors,
    required this.equipmentAsync,
  });

  /// The status badge that rides in the [SectionTitle]'s trailing slot.
  Widget _badge() {
    return equipmentAsync.when(
      // Keep the resolved badge on screen while framingFOVProvider re-runs,
      // instead of blanking on every camera-telemetry tick.
      skipLoadingOnReload: true,
      data: (result) {
        if (result.isReady) {
          return SkotiqChip(
            label: result.profileName ?? 'Ready',
            tone: ChipTone.success,
            dot: true,
          );
        }
        return const SkotiqChip(
          label: 'Not configured',
          tone: ChipTone.warning,
          dot: true,
        );
      },
      // An empty box here made a stuck first load look identical to "no badge
      // for this state". Name it.
      loading: () => const SkotiqChip(label: 'Loading…'),
      error: (error, _) => const SkotiqChip(
        label: 'Error',
        tone: ChipTone.error,
        dot: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(
          icon: SkotiqIcons.camera,
          title: 'Equipment',
          trailing: _badge(),
        ),
        equipmentAsync.when(
          // framingFOVProvider watches cameraStateProvider, so every telemetry
          // tick re-runs its async getCameraStatus round-trip. With the default
          // skipLoadingOnReload: false this threw away the equipment it had
          // already resolved and painted a bare spinner for the duration of
          // each round-trip — measured at 8 of 10 samples over 30 s, which is
          // what read as "spinning for twenty minutes". A genuine first load
          // still shows the spinner.
          skipLoadingOnReload: true,
          data: (result) {
            switch (result.status) {
              // ONE banner per problem (05 §11), same wording and same action
              // as the Tonight checklist's equipment step.
              case EquipmentStatus.noProfile:
                return SkotiqBanner(
                  tone: BannerTone.warning,
                  title: 'No equipment profile',
                  message:
                      'Create and activate one to preview your field of view.',
                  action: SkotiqButton(
                    label: 'Open settings',
                    size: ButtonSize.small,
                    variant: ButtonVariant.secondary,
                    onPressed: () => context.go('/equipment'),
                  ),
                );

              case EquipmentStatus.noFocalLength:
                return SkotiqBanner(
                  tone: BannerTone.warning,
                  title: 'Optical specs missing',
                  message: 'Set the focal length in "${result.profileName}" to '
                      'preview your field of view.',
                  action: SkotiqButton(
                    label: 'Open settings',
                    size: ButtonSize.small,
                    variant: ButtonVariant.secondary,
                    onPressed: () => context.go('/equipment'),
                  ),
                );

              case EquipmentStatus.noCameraSpecs:
                return const SkotiqBanner(
                  tone: BannerTone.warning,
                  title: 'Camera not configured',
                  message: 'Connect a camera, or enter its sensor specs, for '
                      'an accurate field of view.',
                );

              case EquipmentStatus.ready:
                final equipment = result.equipment!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    KeyValueList(rows: [
                      ('Camera', equipment.cameraName),
                      (
                        'Telescope',
                        '${equipment.effectiveFocalLength.round()} mm '
                            'f/${equipment.focalRatio.toStringAsFixed(1)}'
                      ),
                    ]),
                    if (result.message != null) ...[
                      const SizedBox(height: SkotiqTokens.spaceSm),
                      SkotiqBanner(
                        tone: BannerTone.warning,
                        title: 'Default sensor specs',
                        message: result.message!,
                      ),
                    ],
                  ],
                );
            }
          },
          loading: () => const SizedBox(
            height: 60,
            child: Center(
                child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          ),
          error: (e, _) => SkotiqBanner(
            tone: BannerTone.error,
            title: 'Could not read your equipment',
            message: e.toString(),
          ),
        ),
      ],
    );
  }
}
