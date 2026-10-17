part of '../photometric_calibration_wizard.dart';

extension _PhotometricWizardFrameSelection
    on _PhotometricCalibrationWizardState {
  Widget _buildStep1SelectFrame(SkotiqColors colors) {
    final sessionsAsync = ref.watch(allSessionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select plate-solved frames from a standard star field',
          style:
              SkotiqTypography.bodyMedium.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'Choose one or more plate-solved frames captured in a field with '
          'known standard stars (e.g., Landolt fields, Stetson standards). '
          'One frame fits the zero point and color term; selecting frames of '
          'the same field at different altitudes adds airmass spread, which '
          'lets the fit also recover the atmospheric extinction coefficient.',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        sessionsAsync.when(
          loading: () => const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          error: (error, _) => Container(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusLg,
              border: Border.all(color: colors.error.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.alertTriangle,
                    size: SkotiqTokens.iconSm, color: colors.error),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    'Could not load imaging sessions: $error',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style:
                        SkotiqTypography.caption.copyWith(color: colors.error),
                  ),
                ),
                TextButton(
                  onPressed: () => ref.invalidate(allSessionsProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (sessions) => _buildFrameSourceControls(colors, sessions),
        ),
      ],
    );
  }

  Widget _buildFrameSourceControls(
    SkotiqColors colors,
    List<ImagingSession> sessions,
  ) {
    if (sessions.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        decoration: BoxDecoration(
          color: colors.well,
          borderRadius: SkotiqTokens.borderRadiusLg,
          border: Border.all(color: colors.border.withValues(alpha: 0.3)),
        ),
        child: Text(
          'No imaging sessions found. Capture frames with a standard '
          'star field first.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      );
    }

    final selectedSessionExists =
        sessions.any((session) => session.id == _selectedSessionId);
    final sessionId =
        selectedSessionExists ? _selectedSessionId! : sessions.first.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: SkotiqTokens.spaceLg,
          runSpacing: SkotiqTokens.spaceMd,
          children: [
            SizedBox(
              width: 220,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Session',
                      style: SkotiqTypography.labelSm
                          .copyWith(color: colors.textSecondary)),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  SkotiqDropdown(
                    isExpanded: true,
                    isDense: true,
                    value: sessionId.toString(),
                    hint: 'Select session',
                    items: sessions.map((s) => s.id.toString()).toList(),
                    itemLabels: sessions
                        .map((s) => s.name ?? 'Session ${s.id}')
                        .toList(),
                    onChanged: (value) {
                      final id = value == null ? null : int.tryParse(value);
                      if (id == null || id == sessionId) {
                        return;
                      }
                      _update(() {
                        _retireAsyncWork();
                        _selectedSessionId = id;
                        _selectedImageIds.clear();
                        _starMatches = const [];
                        _computedCoefficients = null;
                        _fitAttempted = false;
                      });
                    },
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 140,
              child: SkotiqTextField(
                label: 'Filter',
                controller: _filterController,
                hint: 'e.g., V, B, R',
                onChanged: _changeFilter,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _buildFrameSelector(colors, sessionId),
      ],
    );
  }

  void _changeFilter(String value) {
    final changed =
        value.trim().toLowerCase() != _filterName.trim().toLowerCase();
    _update(() {
      _filterName = value;
      if (changed && _selectedImageIds.isNotEmpty) {
        _selectedImageIds.clear();
      }
      if (changed) {
        _retireAsyncWork();
        _starMatches = const [];
        _computedCoefficients = null;
        _fitAttempted = false;
      }
    });
  }

  Widget _buildFrameSelector(SkotiqColors colors, int sessionId) {
    final images = ref.watch(calibrationSessionImagesProvider(sessionId));

    return images.when(
      // Shimmer thumbnail strip matches the frame selector height so the
      // wizard doesn't reflow when the image list resolves.
      loading: () => AdaptiveChartContainer.fixed(
        height:
            _PhotometricCalibrationWizardState._frameSelectorPreferredHeight,
        child: ShimmerLoading(
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 5,
            separatorBuilder: (_, __) =>
                const SizedBox(width: SkotiqTokens.spaceSm),
            itemBuilder: (_, __) => SizedBox(
              width: 140,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius: SkotiqTokens.borderRadiusMd,
                ),
              ),
            ),
          ),
        ),
      ),
      error: (error, _) => Row(
        children: [
          Expanded(
            child: Text(
              'Error loading images: $error',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.body.copyWith(color: colors.error),
            ),
          ),
          TextButton(
            onPressed: () =>
                ref.invalidate(calibrationSessionImagesProvider(sessionId)),
            child: const Text('Retry'),
          ),
        ],
      ),
      data: (imageList) {
        final solvedImages = imageList
            .where((img) =>
                img.isPlateSolved && img.frameType.toLowerCase() == 'light')
            .toList(growable: false);

        if (solvedImages.isEmpty) {
          return Text(
            'No plate-solved light frames found in the selected session.',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          );
        }

        // Frames this wizard can actually fit: the right filter, and a recorded
        // above-horizon altitude (star matching refuses a frame whose airmass
        // is unknown rather than inventing X = 1.0).
        final usable = solvedImages
            .where((img) =>
                !_filterMismatches(img) &&
                airmassForFrame(img.mountAltitude) != null)
            .toList(growable: false);
        final skipped = solvedImages.length - usable.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Bulk selection. The step's own instructions ask for frames "of
            // the same field at different altitudes", and a night of 120 solved
            // frames made that a 120-click job through rows that did not even
            // show altitude.
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_selectedImageIds.length} of ${solvedImages.length} '
                    'selected'
                    '${skipped > 0 ? ' · $skipped unusable' : ''}',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: usable.isEmpty
                      ? null
                      : () => _update(() {
                            _retireAsyncWork();
                            _selectedSessionId = sessionId;
                            // Tapping a frame anchors the calibration on that
                            // frame's filter, after which the tap path refuses
                            // every other filter. A bulk select has to anchor
                            // the same way: on a fresh wizard the filter field
                            // is empty, so without this one click would hand
                            // the extinction fit a B+V+R selection and the
                            // saved transform would carry a k fitted across
                            // filters.
                            if (_filterName.trim().isEmpty) {
                              final anchor = usable
                                  .map((img) => img.filter?.trim())
                                  .firstWhere(
                                    (f) => f != null && f.isNotEmpty,
                                    orElse: () => null,
                                  );
                              if (anchor != null) {
                                _filterName = anchor;
                                _filterController.text = anchor;
                              }
                            }
                            _selectedImageIds
                              ..clear()
                              ..addAll(usable
                                  .where((img) => !_filterMismatches(img))
                                  .map((img) => img.id));
                            _starMatches = const [];
                            _computedCoefficients = null;
                            _fitAttempted = false;
                          }),
                  child: const Text('Select all usable'),
                ),
                TextButton(
                  onPressed: _selectedImageIds.isEmpty
                      ? null
                      : () => _update(() {
                            _retireAsyncWork();
                            _selectedImageIds.clear();
                            _starMatches = const [];
                            _computedCoefficients = null;
                            _fitAttempted = false;
                          }),
                  child: const Text('Clear'),
                ),
              ],
            ),
            // Not Expanded: this Column sits in an unbounded scroll view, and
            // the list already sizes itself through AdaptiveChartContainer.
            _buildFrameList(colors, sessionId, solvedImages),
          ],
        );
      },
    );
  }

  /// Whether [img] carries a different filter from the one being calibrated.
  bool _filterMismatches(DbCapturedImage img) {
    final frameFilter = img.filter?.trim();
    return _filterName.trim().isNotEmpty &&
        frameFilter != null &&
        frameFilter.isNotEmpty &&
        frameFilter.toLowerCase() != _filterName.trim().toLowerCase();
  }

  Widget _buildFrameList(
    SkotiqColors colors,
    int sessionId,
    List<DbCapturedImage> solvedImages,
  ) {
    return AdaptiveChartContainer(
      preferredHeight:
          _PhotometricCalibrationWizardState._frameSelectorPreferredHeight,
      minHeight: 140,
      child: ListView.builder(
        itemCount: solvedImages.length,
        itemBuilder: (context, index) {
          final img = solvedImages[index];
          final isSelected = _selectedImageIds.contains(img.id);
          final frameFilter = img.filter?.trim();
          final filterMismatch = !isSelected && _filterMismatches(img);
          return Material(
            type: MaterialType.transparency,
            child: ListTile(
              dense: true,
              selected: isSelected,
              selectedColor: colors.primary,
              selectedTileColor:
                  SkotiqDecorations.chip(colors, tone: colors.primary).color,
              title: Text(
                img.fileName,
                style: SkotiqTypography.bodySm.copyWith(
                  color: isSelected ? colors.primary : colors.textPrimary,
                ),
              ),
              subtitle: Text(
                '${img.filter ?? "No filter"} | '
                '${img.exposureDuration.toStringAsFixed(1)}s | '
                'Stars: ${img.starCount ?? "?"} | '
                // Altitude and airmass, because this step's own
                // instructions ask the user to build an airmass spread and
                // the rows gave them nothing to build it from.
                '${_altitudeLabel(img.mountAltitude)} | '
                // solvedRa is HOURS, not degrees (the ASCOM convention this
                // app carries internally), so a bare "RA: 5.5000" was both
                // unitless and easy to read as degrees.
                'RA ${img.solvedRa == null ? "?" : CoordinateParser.formatRaHms(img.solvedRa!)} '
                'Dec ${img.solvedDec == null ? "?" : CoordinateParser.formatDecDms(img.solvedDec!)}',
                style: SkotiqTypography.captionSm.copyWith(
                  color: airmassForFrame(img.mountAltitude) == null
                      ? colors.warning
                      : colors.textMuted,
                ),
              ),
              leading: Icon(
                isSelected ? LucideIcons.checkCircle2 : LucideIcons.image,
                color: isSelected ? colors.primary : colors.textMuted,
                size: SkotiqTokens.iconSm,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: SkotiqTokens.borderRadiusLg,
              ),
              onTap: () {
                if (filterMismatch) {
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(
                      content: Text(
                        '${img.fileName} uses filter $frameFilter; this '
                        'calibration is for ${_filterName.trim()}.',
                      ),
                    ),
                  );
                  return;
                }
                _update(() {
                  _retireAsyncWork();
                  // Anchor the implicit default session as soon as the user
                  // selects a frame. A newly-started session may then move
                  // to the front of the history stream without hiding this
                  // selection under a different session.
                  _selectedSessionId = sessionId;
                  if (!_selectedImageIds.remove(img.id)) {
                    _selectedImageIds.add(img.id);
                  }
                  if (_filterName.isEmpty && img.filter != null) {
                    _filterName = img.filter!;
                    _filterController.text = img.filter!;
                  }
                  // New frame selection invalidates downstream products.
                  _starMatches = const [];
                  _computedCoefficients = null;
                  _fitAttempted = false;
                });
              },
            ),
          );
        },
      ),
    );
  }

  /// `Alt 52.3° · X 1.26`, or a statement that the frame cannot be fitted.
  String _altitudeLabel(double? altitudeDeg) {
    final airmass = airmassForFrame(altitudeDeg);
    if (airmass == null) return 'no recorded altitude — cannot fit';
    return 'Alt ${altitudeDeg!.toStringAsFixed(1)}° · X '
        '${airmass.toStringAsFixed(2)}';
  }

  // Step 2: auto-match detected stars to catalog
}

/// The airmass the extinction fit will use for a frame, or null when the frame
/// has no usable altitude.
///
/// Wraps the product's one airmass model so the frame list and the fit agree
/// about which frames are usable.
double? airmassForFrame(double? altitudeDeg) =>
    altitudeDeg == null ? null : airmassForTrueAltitude(altitudeDeg);
