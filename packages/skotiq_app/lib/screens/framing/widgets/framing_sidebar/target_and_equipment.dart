part of '../framing_sidebar.dart';

/// The pinned search block: SIMBAD-backed name search with its results and
/// error line, and one row of manual RA / Dec entry. The controllers are owned
/// by the parent screen so navigating away and back preserves the input.
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

  /// Height of one search result row.
  static const double resultExtent = 36;

  /// The results list shows at most this many rows before it scrolls.
  static const int visibleResults = 5;

  /// Below this width RA and Dec stack instead of sharing a row.
  static const double stackCoordinatesBelow = 270;

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
    final Widget? suffix = searchState.isSearching
        ? Padding(
            padding: const EdgeInsets.only(left: SkotiqTokens.spaceXs),
            child:
                SkotiqSpinner(size: SkotiqTokens.iconSm, color: colors.primary),
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
            : null;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SkotiqTextField(
              key: FramingTutorialKeys.targetSearch,
              controller: searchController,
              focusNode: searchFocusNode,
              hint: 'Search M42, NGC 7000, Orion',
              prefixIcon: SkotiqIcons.search,
              suffixWidget: suffix,
              textInputAction: TextInputAction.search,
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
            if (searchState.errorMessage != null) ...[
              const SizedBox(height: SkotiqTokens.spaceXs),
              Row(
                children: [
                  Expanded(
                    child: FramingNote(
                      searchState.errorMessage!,
                      color: colors.error,
                      icon: SkotiqIcons.warning,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SizedBox(
                    width: 64,
                    child: NightPanelButton(
                      label: 'Retry',
                      onPressed: searchState.isSearching
                          ? null
                          : () =>
                              ref.read(targetSearchProvider.notifier).retry(),
                    ),
                  ),
                ],
              ),
            ],
            if (searchState.results.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceXs),
              _results(),
            ],
            const SizedBox(height: SkotiqTokens.spaceSm),
            _coordinateEntry(),
          ],
        ),
      ),
    );
  }

  /// Manual RA / Dec entry and its Go button. Side by side when the column
  /// has room for a whole sexagesimal value in each field; one above the
  /// other when it does not, because a coordinate cut short reads as a
  /// different coordinate.
  Widget _coordinateEntry() {
    final ra = SkotiqTextField(
      controller: raController,
      label: 'RA',
      hint: '05h 35m 17s',
      mono: true,
      dense: true,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => onGoToManualCoordinates(),
    );
    final dec = SkotiqTextField(
      controller: decController,
      label: 'Dec',
      hint: '-05° 23\' 28"',
      mono: true,
      dense: true,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => onGoToManualCoordinates(),
    );
    final go = SkotiqIconButton(
      icon: SkotiqIcons.arrowRight,
      tooltip: 'Go to coordinates',
      size: IconButtonSize.sm,
      onPressed: onGoToManualCoordinates,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= stackCoordinatesBelow) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: ra),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Expanded(child: dec),
              const SizedBox(width: SkotiqTokens.spaceXs),
              go,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ra,
            const SizedBox(height: SkotiqTokens.spaceXs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: dec),
                const SizedBox(width: SkotiqTokens.spaceXs),
                go,
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _results() {
    final results = searchState.results;
    return Container(
      constraints: const BoxConstraints(
        maxHeight: resultExtent * visibleResults,
      ),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: Border.all(color: colors.border),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemExtent: resultExtent,
        itemCount: results.length,
        itemBuilder: (context, index) {
          final target = results[index];
          final catalog =
              target.catalogId != null && target.catalogId != target.name
                  ? target.catalogId
                  : null;
          return InkWell(
            onTap: () => onTargetSelected(target),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
              ),
              child: Row(
                children: [
                  Icon(
                    _iconForType(target.type),
                    size: SkotiqTokens.iconXs,
                    color: colors.textMuted,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: SkotiqTypography.labelSm
                              .copyWith(color: colors.textPrimary),
                        ),
                        if (catalog != null)
                          Text(
                            catalog,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.captionSm
                                .copyWith(color: colors.textMuted),
                          ),
                      ],
                    ),
                  ),
                  if (target.magnitude != null) ...[
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Text(
                      'mag ${target.magnitude!.toStringAsFixed(1)}',
                      style: SkotiqTypography.monoXs
                          .copyWith(color: colors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The Target section: the picked object's name and catalog facts, where the
/// frame center sits right now (RA / Dec / rotation, altitude, azimuth,
/// airmass), and tonight's altitude curve. Copy and Save sit on the title row.
///
/// The numbers are the frame center - the reticle's effective aim, which is
/// where the telescope will point - not the view center once the box has been
/// dragged.
class FramingTargetSection extends StatelessWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final (double, double)? currentAltAz;
  final VoidCallback onSaveTarget;

  const FramingTargetSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.currentAltAz,
    required this.onSaveTarget,
  });

  /// "NGC 1976 · nebula · mag 4.0"; null when the catalog said nothing.
  static String? facts(FramingTarget target) {
    final parts = <String>[
      if (target.catalogId case final id?
          when id.isNotEmpty && id != target.name)
        id,
      if (target.magnitude case final mag?) 'mag ${mag.toStringAsFixed(1)}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final picked = framingState.target;
    final aim = framingState.effectiveAimTarget;
    if (picked == null || aim == null) {
      return const FramingPanelSection(
        title: 'Target',
        children: [
          EmptyState.compact(
            icon: SkotiqIcons.target,
            title: 'No target selected',
            body: 'Search for an object or enter coordinates to begin '
                'framing.',
          ),
        ],
      );
    }

    final altAz = currentAltAz;
    final alt = altAz?.$1;
    final airmass =
        alt != null && alt > 0 ? AstronomyCalculations.airmass(alt) : null;
    // The reticle was dragged: the frame center is no longer the object.
    final offset =
        framingState.aimRaHours != null && framingState.aimDecDegrees != null;

    return FramingPanelSection(
      title: picked.name.isEmpty ? 'Target' : picked.name,
      note: facts(picked),
      actions: [
        SkotiqIconButton(
          icon: SkotiqIcons.copy,
          tooltip: 'Copy coordinates',
          size: IconButtonSize.sm,
          onPressed: () {
            Clipboard.setData(ClipboardData(
              text: '${aim.raFormatted}, ${aim.decFormatted}',
            ));
            context.showInfoSnackBar('Coordinates copied');
          },
        ),
        SkotiqIconButton(
          icon: LucideIcons.bookmark,
          tooltip: 'Save target',
          size: IconButtonSize.sm,
          onPressed: onSaveTarget,
        ),
      ],
      children: [
        KeyedSubtree(
          key: FramingTutorialKeys.coordinates,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              MetricGrid(
                columns: 2,
                semanticLabel: 'Frame center',
                items: [
                  MetricGridItem(label: 'RA', value: aim.raFormatted),
                  MetricGridItem(label: 'Dec', value: aim.decFormatted),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              MetricGrid(
                columns: 4,
                semanticLabel: 'Frame center now',
                items: [
                  MetricGridItem(
                    label: 'Alt',
                    value: alt == null ? null : '${alt.toStringAsFixed(1)}°',
                    valueTone: alt == null
                        ? MetricGridTone.neutral
                        : alt < 0
                            ? MetricGridTone.bad
                            : alt < 15
                                ? MetricGridTone.warning
                                : alt > 30
                                    ? MetricGridTone.good
                                    : MetricGridTone.neutral,
                  ),
                  MetricGridItem(
                    label: 'Az',
                    value: altAz == null
                        ? null
                        : '${altAz.$2.toStringAsFixed(1)}°',
                  ),
                  MetricGridItem(
                    label: 'Airmass',
                    value: airmass?.toStringAsFixed(2),
                  ),
                  MetricGridItem(
                    label: 'Rotation',
                    value: '${framingState.rotation.round()}°',
                  ),
                ],
              ),
            ],
          ),
        ),
        if (offset)
          FramingNote(
            'The frame center has been moved off ${picked.name}. Slew and '
            'solve use the frame center.',
          ),
        if (alt != null && alt < 0)
          FramingNote(
            'Below the horizon now',
            color: colors.warning,
            icon: SkotiqIcons.warning,
          ),
        if (altAz == null)
          const FramingNote(
            'Set your observing site in Settings to see altitude.',
          ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        AltitudeChart(
          key: FramingTutorialKeys.altitudeChart,
          raHours: aim.raHours,
          decDegrees: aim.decDegrees,
          targetName: aim.name,
          compact: true,
        ),
      ],
    );
  }
}

/// The Camera section: the active profile's field of view as readouts, the
/// camera and telescope, or the single [SkotiqBanner] for the current
/// `EquipmentStatus` (noProfile / noFocalLength / noCameraSpecs).
class FramingEquipmentSection extends StatelessWidget {
  final SkotiqColors colors;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingEquipmentSection({
    super.key,
    required this.colors,
    required this.equipmentAsync,
  });

  @override
  Widget build(BuildContext context) {
    // framingFOVProvider watches cameraStateProvider, so every telemetry
    // tick re-runs its async getCameraStatus round-trip. With the default
    // skipLoadingOnReload: false this threw away the equipment it had
    // already resolved and painted a bare spinner for the duration of
    // each round-trip - measured at 8 of 10 samples over 30 s, which is
    // what read as "spinning for twenty minutes". A genuine first load
    // still shows the loading state.
    return equipmentAsync.when(
      skipLoadingOnReload: true,
      data: (result) => _resolved(context, result),
      // An empty box here made a stuck first load look identical to "no
      // equipment". Name it.
      loading: () => FramingPanelSection(
        title: 'Camera',
        note: 'Loading…',
        children: [
          Row(
            children: [
              SkotiqSpinner(size: SkotiqTokens.iconSm, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              const Expanded(
                child: FramingNote('Reading the active equipment profile'),
              ),
            ],
          ),
        ],
      ),
      error: (e, _) => FramingPanelSection(
        title: 'Camera',
        note: 'Error',
        noteColor: colors.error,
        children: [
          SkotiqBanner(
            tone: BannerTone.error,
            title: 'Could not read your equipment',
            message: e.toString(),
          ),
        ],
      ),
    );
  }

  Widget _resolved(BuildContext context, FramingEquipmentResult result) {
    // ONE banner per problem (05 §11), same wording and same action as the
    // Tonight checklist's equipment step.
    Widget openSettings() => SkotiqButton(
          label: 'Open settings',
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: () => context.go('/equipment'),
        );

    final Widget body;
    switch (result.status) {
      case EquipmentStatus.noProfile:
        body = SkotiqBanner(
          tone: BannerTone.warning,
          title: 'No equipment profile',
          message: 'Create and activate one to preview your field of view.',
          action: openSettings(),
        );
      case EquipmentStatus.noFocalLength:
        body = SkotiqBanner(
          tone: BannerTone.warning,
          title: 'Optical specs missing',
          message: 'Set the focal length in "${result.profileName}" to '
              'preview your field of view.',
          action: openSettings(),
        );
      case EquipmentStatus.noCameraSpecs:
        body = const SkotiqBanner(
          tone: BannerTone.warning,
          title: 'Camera not configured',
          message: 'Connect a camera, or enter its sensor specs, for '
              'an accurate field of view.',
        );
      case EquipmentStatus.ready:
        final equipment = result.equipment!;
        body = LayoutBuilder(
          builder: (context, constraints) =>
              _readyBody(result, equipment, narrow: constraints.maxWidth < 260),
        );
    }

    return FramingPanelSection(
      title: 'Camera',
      note: result.isReady ? (result.profileName ?? 'Ready') : 'Not configured',
      noteColor: result.isReady ? null : colors.warning,
      children: [body],
    );
  }

  /// A resolved profile: field, scale and sensor as readouts (two columns
  /// in a narrow column so "2.54×1.70°" is never cut), then the camera and
  /// telescope, then the default-specs warning if it applies.
  Widget _readyBody(
    FramingEquipmentResult result,
    FramingEquipment equipment, {
    required bool narrow,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MetricGrid(
          columns: narrow ? 2 : 3,
          semanticLabel: 'Field of view',
          items: [
            MetricGridItem(
              label: 'Field',
              value: '${equipment.fovWidthDeg.toStringAsFixed(2)}×'
                  '${equipment.fovHeightDeg.toStringAsFixed(2)}°',
            ),
            MetricGridItem(
              label: 'Scale',
              value: '${equipment.imageScale.toStringAsFixed(2)}"/px',
            ),
            MetricGridItem(
              label: 'Sensor',
              value: '${equipment.pixelsX}×${equipment.pixelsY}',
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        NightPanelRow(label: 'Camera', value: equipment.cameraName),
        const SizedBox(height: kNightPanelRowGap),
        NightPanelRow(
          label: 'Telescope',
          value: '${equipment.effectiveFocalLength.round()} mm '
              'f/${equipment.focalRatio.toStringAsFixed(1)}',
        ),
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
}
