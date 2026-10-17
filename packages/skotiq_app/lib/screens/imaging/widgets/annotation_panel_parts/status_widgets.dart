part of '../annotation_panel.dart';

/// The ONE place the "annotations need a catalog" problem is stated on this
/// screen (02 rule 5, 05 §11).
///
/// It used to be three: a full-width info bar above the viewer, a box floating
/// over the frame, and a modal on the first snapshot. The same problem is also
/// step 4 of the Tonight checklist; here it is a single inline banner inside
/// the section it blocks, and it self-hides when a catalog is installed or
/// annotations are off.
class AnnotationCatalogBanner extends ConsumerWidget {
  const AnnotationCatalogBanner({super.key, required this.onSetup});

  /// Opens the catalog settings.
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(annotationSettingsProvider).valueOrNull;
    final status = ref.watch(annotationStateProvider).status;
    final missing = status == AnnotationStatus.catalogsNotInstalled;
    if (settings?.enabled != true || !missing) return const SizedBox.shrink();

    return SkotiqBanner(
      title: 'No object catalog installed',
      message: 'Download it to name the galaxies and nebulae in your frames.',
      tone: BannerTone.warning,
      action: SkotiqButton(
        label: 'Download',
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: onSetup,
      ),
    );
  }
}

/// Copy for the "no annotated objects" empty state, named for the blocker that
/// is actually in the way.
///
/// Branching on `annotation == null` alone reads "Capture an image to see
/// detected objects", which is false the moment a frame lands with no plate
/// solver installed — and contradicts the status card directly above it.
/// Branch on the real blocker so the two cannot disagree.
///
/// Returns the headline plus an optional second line; a null [hint] means the
/// headline says everything there is to say.
({String title, String? hint}) _annotationEmptyStateCopy({
  required bool hasImage,
  required bool annotationsEnabled,
  required AnnotationState state,
}) {
  if (!annotationsEnabled) {
    return (
      title: 'Annotations are off',
      hint: 'Turn annotations on to identify objects in your frames.',
    );
  }
  if (!hasImage) {
    return (
      title: 'No image annotated',
      hint: 'Capture an image to see detected objects',
    );
  }
  if (AnnotationStatusIndicator._isSolverMissing(state)) {
    return (
      title: 'Cannot annotate: no plate solver',
      hint: 'Install ASTAP or set its path in Settings to label objects.',
    );
  }
  switch (state.status) {
    case AnnotationStatus.catalogsNotInstalled:
      return (
        title: 'Cannot annotate: no catalog',
        hint: 'Download the annotation catalog in Settings to label objects.',
      );
    case AnnotationStatus.plateSolveFailed:
      return (
        title: 'Plate solve failed',
        hint: state.errorDetails ??
            state.message ??
            'This frame could not be solved, so no objects could be matched.',
      );
    case AnnotationStatus.error:
      return (
        title: 'Annotation failed',
        hint: state.errorDetails ?? state.message,
      );
    case AnnotationStatus.checkingCatalogs:
    case AnnotationStatus.plateSolving:
    case AnnotationStatus.searchingCatalogs:
      return (
        title: 'Annotating…',
        hint: 'Identifying objects in the current frame.',
      );
    case AnnotationStatus.idle:
    case AnnotationStatus.complete:
      return (
        title: 'This frame is not annotated',
        hint: 'Run Re-annotate to identify objects in it.',
      );
  }
}

/// The "nothing to list" state shared by both annotation object lists.
///
/// One widget for both panels so the copy cannot drift between them, and so
/// the blocker naming lives next to the status card that reports the same
/// blocker.
class AnnotationEmptyState extends ConsumerWidget {
  final SkotiqColors colors;

  /// The annotation result for the current frame, or null when this frame has
  /// no annotation at all.
  final ImageAnnotation? annotation;

  /// Whether the operator has typed a search term (changes the "filtered
  /// everything away" wording only).
  final bool hasSearchQuery;

  const AnnotationEmptyState({
    super.key,
    required this.colors,
    required this.annotation,
    required this.hasSearchQuery,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String title;
    final String? hint;
    final IconData icon;
    if (annotation != null) {
      // The frame IS annotated — the list is empty because of the filters, not
      // because anything is blocked.
      icon = SkotiqIcons.searchEmpty;
      title =
          hasSearchQuery ? 'No matching objects' : 'No objects match filters';
      hint = null;
    } else {
      icon = LucideIcons.sparkle;
      final copy = _annotationEmptyStateCopy(
        hasImage: ref.watch(currentImageProvider) != null,
        annotationsEnabled:
            ref.watch(annotationSettingsProvider).valueOrNull?.enabled ?? true,
        state: ref.watch(annotationStateProvider),
      );
      title = copy.title;
      hint = copy.hint;
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 32,
              color: colors.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
            if (hint != null) ...[
              const SizedBox(height: 8),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted.withValues(alpha: 0.7)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Status indicator for the live annotation pipeline
class AnnotationStatusIndicator extends ConsumerWidget {
  final SkotiqColors colors;

  const AnnotationStatusIndicator({super.key, required this.colors});

  /// True when the "plate solve failed" state is really just "no solver is
  /// installed on this machine".
  ///
  /// Annotations are enabled by default and no plate solver ships with the app,
  /// so a fresh install showed a RED "Plate solve failed" error pinned over the
  /// imaging viewport after every single capture — even a plain manual snapshot
  /// (observed on the desktop build with the simulator camera). Nothing had
  /// failed: an optional external tool simply is not set up, which the
  /// Equipment readiness panel already reports as an advisory. This is the same
  /// distinction the pipeline already draws for `catalogsNotInstalled`, which is
  /// presented as a warning with a "go install it" hint rather than an error.
  static bool _isSolverMissing(AnnotationState state) {
    if (state.status != AnnotationStatus.plateSolveFailed) return false;
    final text =
        '${state.message ?? ''} ${state.errorDetails ?? ''}'.toLowerCase();
    return text.contains('no supported external plate solver') ||
        text.contains('plate solver is configured') ||
        text.contains('no usable plate solver') ||
        text.contains('astap');
  }

  /// True for a run that finished having matched nothing.
  ///
  /// "Found 0 objects" in the same green tick treatment as "Found 47 objects"
  /// would present a frame the app could not place on the sky as a successful
  /// identification of an empty field — a statement about the sky from a run
  /// that has no position. Zero matches is a real outcome but not a success, so
  /// it gets the neutral treatment and copy that names it.
  static bool _isEmptyResult(AnnotationState state) =>
      state.status == AnnotationStatus.complete &&
      (state.objectsFound ?? 0) == 0;

  /// Headline for a completed run that matched nothing.
  static const String emptyResultHeadline = 'No catalog objects in this frame';

  /// Second line for a completed run that matched nothing.
  static const String emptyResultHint =
      'The frame was solved but nothing in the installed catalogs falls '
      'inside it. If this looks wrong, check the plate-solve result and the '
      'installed catalogs.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationState = ref.watch(annotationStateProvider);
    final annotationSettings =
        ref.watch(annotationSettingsProvider).valueOrNull;
    final solverMissing = _isSolverMissing(annotationState);
    final emptyResult = _isEmptyResult(annotationState);
    // Borrow the "prerequisite not installed" presentation (warning tone, not
    // error) while keeping solver-specific wording below. A completed run that
    // matched nothing borrows the same neutral treatment: it is an outcome to
    // read, not a success to celebrate.
    final presentationStatus = solverMissing || emptyResult
        ? AnnotationStatus.catalogsNotInstalled
        : annotationState.status;
    final secondaryMessage = solverMissing
        ? 'Optional: install ASTAP or set its path in Settings to label objects'
        : emptyResult
            ? emptyResultHint
            : (annotationState.errorDetails ??
                _getActionHint(annotationState.status));

    // Don't show anything if annotations are disabled
    if (annotationSettings != null && !annotationSettings.enabled) {
      return const SizedBox.shrink();
    }

    // Don't show idle state (reduces visual clutter)
    if (annotationState.status == AnnotationStatus.idle) {
      return const SizedBox.shrink();
    }

    return AnimatedOpacity(
      opacity: 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: _getBackgroundColor(presentationStatus),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(
            color: _getBorderColor(presentationStatus),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _getStatusIcon(presentationStatus),
            const SizedBox(width: 8),
            // Flexible, so the text column is laid out against the panel's
            // width instead of its own unconstrained intrinsic width. Without
            // it the Row happily overflowed the annotation panel and the
            // secondary line was hard-clipped mid-word at the panel edge —
            // "…in Settings to label ob" — because maxLines/ellipsis can never
            // fire on text that was never asked to wrap.
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    solverMissing
                        ? 'No plate solver installed'
                        : emptyResult
                            ? emptyResultHeadline
                            : (annotationState.message ??
                                _getStatusText(annotationState.status)),
                    style: SkotiqTypography.caption.copyWith(
                        fontWeight: FontWeight.w500,
                        color: _getTextColor(presentationStatus)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondaryMessage != null)
                    Text(
                      secondaryMessage,
                      style: SkotiqTypography.caption.copyWith(
                          color: _getTextColor(presentationStatus)
                              .withValues(alpha: 0.7)),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getBackgroundColor(AnnotationStatus status) {
    return AnnotationStatusColors.background(status, colors);
  }

  Color _getBorderColor(AnnotationStatus status) {
    return AnnotationStatusColors.border(status, colors);
  }

  Color _getTextColor(AnnotationStatus status) {
    return AnnotationStatusColors.text(status, colors);
  }

  Widget _getStatusIcon(AnnotationStatus status) {
    switch (status) {
      case AnnotationStatus.checkingCatalogs:
      case AnnotationStatus.plateSolving:
      case AnnotationStatus.searchingCatalogs:
        return SizedBox(
          width: 14,
          height: 14,
          child: SkotiqSpinner(size: 14, color: _getTextColor(status)),
        );
      case AnnotationStatus.complete:
        return Icon(SkotiqIcons.success,
            size: 14, color: _getTextColor(status));
      case AnnotationStatus.error:
      case AnnotationStatus.plateSolveFailed:
        return Icon(LucideIcons.alertCircle,
            size: 14, color: _getTextColor(status));
      case AnnotationStatus.catalogsNotInstalled:
        return Icon(SkotiqIcons.warning,
            size: 14, color: _getTextColor(status));
      case AnnotationStatus.idle:
        return const SizedBox.shrink();
    }
  }

  String _getStatusText(AnnotationStatus status) {
    switch (status) {
      case AnnotationStatus.checkingCatalogs:
        return 'Checking catalogs...';
      case AnnotationStatus.plateSolving:
        return 'Plate solving...';
      case AnnotationStatus.searchingCatalogs:
        return 'Searching catalogs...';
      case AnnotationStatus.complete:
        return 'Annotation complete';
      case AnnotationStatus.error:
        return 'Annotation error';
      case AnnotationStatus.plateSolveFailed:
        return 'Plate solve failed';
      case AnnotationStatus.catalogsNotInstalled:
        return 'No catalogs installed';
      case AnnotationStatus.idle:
        return '';
    }
  }

  String? _getActionHint(AnnotationStatus status) {
    switch (status) {
      case AnnotationStatus.catalogsNotInstalled:
        return 'Install catalogs in Settings > Catalogs';
      case AnnotationStatus.plateSolveFailed:
        return 'Check solver config, focus, and star signal';
      case AnnotationStatus.error:
        return 'Capture a fresh frame to retry';
      case AnnotationStatus.checkingCatalogs:
      case AnnotationStatus.plateSolving:
      case AnnotationStatus.searchingCatalogs:
      case AnnotationStatus.complete:
      case AnnotationStatus.idle:
        return null;
    }
  }
}

/// Sidebar panel showing list of detected celestial objects
