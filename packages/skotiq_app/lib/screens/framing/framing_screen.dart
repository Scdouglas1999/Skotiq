import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'add_target_to_sequence_flow.dart';
import 'framing_altaz.dart';
import 'framing_hips_layer_wiring.dart';
import 'framing_search_provider.dart';
import '../../widgets/tutorial_keys/framing_keys.dart';
import 'widgets/optical_config_panel.dart';
import 'widgets/framing_canvas.dart';
import 'widgets/framing_sidebar.dart';

/// Scaffold-less framing body: composing and framing astrophotography targets
/// on a survey-backed canvas with an equipment FOV reticle.
///
/// Hosted both inside Plan Tonight's "Sky" tab and by [FramingScreen] (the thin
/// wrapper kept for the redirected `/framing` standalone route). Browsing and
/// acting on tonight's target suggestions lives entirely in the Planner — this
/// view carries no Suggestions tab. Targets are adopted into the canvas via
/// [FramingNotifier.setTargetSuggestion] + `goNamed('framing')` or via
/// `?ra=&dec=&name=` query params.
class FramingView extends ConsumerStatefulWidget {
  const FramingView({super.key});

  @override
  ConsumerState<FramingView> createState() => _FramingViewState();
}

class _FramingViewState extends ConsumerState<FramingView> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _raController = TextEditingController();
  final _decController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Alt/Az is recomputed lazily in build() from target + settings; no need
    // for a periodic poll that fires while the screen is off-tab/off-focus.
    // Load the most recent target if no target is currently set
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPersistedTarget();
    });
  }

  Future<void> _loadPersistedTarget() async {
    // Honor inbound query params first: /framing?ra=<hours>&dec=<deg>&name=<n>.
    // The planning workspace uses this to hand off a chosen target to framing.
    final applied = _applyQueryParamsTarget();

    final framingState = ref.read(framingProvider);
    if (!applied && framingState.target == null) {
      // No target in provider, try to load from database
      await ref.read(framingProvider.notifier).loadMostRecentTarget();
    }
    // Always sync controllers with provider state (handles navigation back to tab)
    final currentState = ref.read(framingProvider);
    if (currentState.target != null) {
      _searchController.text = currentState.target!.name;
      _raController.text = currentState.target!.raFormatted;
      _decController.text = currentState.target!.decFormatted;
    }
  }

  /// Parses `?ra=&dec=&name=` from the current GoRouter location and, when
  /// valid, hands the target to the framing provider. Returns true if a
  /// target was applied. RA is in decimal hours, Dec is in decimal degrees.
  bool _applyQueryParamsTarget() {
    if (!mounted) return false;
    final Uri uri;
    try {
      uri = GoRouterState.of(context).uri;
    } catch (_) {
      // Why: framing screen is reachable outside the GoRouter tree in tests.
      return false;
    }
    final params = uri.queryParameters;
    final raStr = params['ra'];
    final decStr = params['dec'];
    if (raStr == null || decStr == null) return false;

    final raHours = double.tryParse(raStr);
    final decDegrees = double.tryParse(decStr);
    if (raHours == null || decDegrees == null) return false;
    if (raHours < 0 || raHours >= 24) return false;
    if (decDegrees < -90 || decDegrees > 90) return false;

    final name = params['name']?.trim();
    ref.read(framingProvider.notifier).setTargetCoordinates(
          raHours,
          decDegrees,
          name: (name == null || name.isEmpty) ? null : name,
        );
    return true;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _raController.dispose();
    _decController.dispose();
    super.dispose();
  }

  /// Compute current alt/az from target + location lazily during build.
  /// Returns null when no target or no usable location is available.
  (double, double)? _computeCurrentAltAz(
    FramingTarget? target,
    AppSettingsState? settings,
  ) {
    if (target == null || settings == null) return null;
    final lat = settings.latitude;
    final lon = settings.longitude;
    // (0,0) is the sentinel for "no location set"; avoid reporting nonsense.
    if (!settings.hasObserverLocation) return null;
    return calculateCurrentAltAz(
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      latitudeDeg: lat,
      longitudeDeg: lon,
      time: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final framingState = ref.watch(framingProvider);
    final searchState = ref.watch(targetSearchProvider);
    final equipmentResult = ref.watch(framingFOVProvider);
    // Recompute alt/az lazily on each build (cheap trig, no IO). This naturally
    // refreshes whenever the framing target or location settings change; the
    // previous 10-second periodic timer fired even when off-tab/off-focus.
    // Computed for the effective AIM — the point the telescope will slew to —
    // which differs from the view-center target once the box is dragged.
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final currentAltAz =
        _computeCurrentAltAz(framingState.effectiveAimTarget, settings);

    return _buildFramingContent(
      colors,
      framingState,
      searchState,
      equipmentResult,
      currentAltAz,
    );
  }

  Widget _buildFramingContent(
    SkotiqColors colors,
    FramingState framingState,
    TargetSearchState searchState,
    AsyncValue<FramingEquipmentResult> equipmentResult,
    (double, double)? currentAltAz,
  ) {
    // Canvas (dominant) + survey-overlay chrome. This is the [primary] region
    // for the adaptive split: full-screen on desktop minus the controls panel,
    // and the dominant region on a phone (controls collapse to a sheet /
    // side-by-side split per AdaptivePanelLayout).
    final canvas = _buildCanvas(colors, framingState, equipmentResult);

    // The controls / target sidebar content. Identical on every tier — only its
    // container changes (a fixed side column on desktop/tablet, a bottom sheet
    // or landscape side panel on a phone).
    final controls = _buildControlsColumn(
      colors,
      framingState,
      searchState,
      equipmentResult,
      currentAltAz,
    );

    return SafeArea(
      child: AdaptivePanelLayout(
        primary: canvas,
        panelSide: PanelSide.end,
        // Desktop/tablet keep the familiar right-hand sidebar.
        initialPanelWidth: 320,
        minPanelWidth: 250,
        maxPanelWidth: 500,
        // Phone portrait: the sidebar collapses to a bottom sheet so the
        // canvas keeps the full screen. Phone landscape: a side-by-side split
        // (canvas left, controls right) once there is room.
        phoneStrategy: PhonePanelStrategy.bottomSheet,
        secondary: [
          AdaptivePanel(
            title: 'Framing controls',
            icon: SkotiqIcons.sliders,
            // The side panel's surface and left hairline, matching
            // [SidePanel]. The widget itself is not used here because
            // AdaptivePanelLayout owns this panel's width (resizable 250-500,
            // bottom sheet on a phone) and SidePanel would pin it to 320.
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(left: BorderSide(color: colors.border)),
              ),
              child: controls,
            ),
          ),
        ],
      ),
    );
  }

  /// The dominant survey/HiPS canvas plus its overlay chrome (optical-config
  /// panel toggle and survey attribution badge).
  Widget _buildCanvas(
    SkotiqColors colors,
    FramingState framingState,
    AsyncValue<FramingEquipmentResult> equipmentResult,
  ) {
    return Stack(
      children: [
        Positioned.fill(
          child: FramingCanvas(
            key: FramingTutorialKeys.canvas,
            colors: colors,
            framingState: framingState,
            equipmentResult: equipmentResult.valueOrNull,
            onPan: (dx, dy, canvasSize) {
              ref
                  .read(framingProvider.notifier)
                  .pan(dx, dy, canvasSize: canvasSize);
            },
            onRotate: (angle) {
              ref.read(framingProvider.notifier).setRotation(angle);
            },
            onAimChanged: (raHours, decDegrees) {
              ref.read(framingProvider.notifier).setAim(raHours, decDegrees);
            },
            onCanvasResized: (canvasSize) {
              ref.read(framingProvider.notifier).onCanvasResized(canvasSize);
            },
          ),
        ),
        // GPU HiPS framing attribution chrome. The streamed tile
        // mosaic itself is composed INSIDE FramingCanvas's Stack — above
        // the single-cutout survey snapshot and UNDER the grid / FOV /
        // equipment overlays — so the imagery never hides the FOV
        // reticle. This wiring only adds the survey attribution credit
        // badge as top chrome (a licence requirement), self-positioning
        // in the canvas's bottom band and gated internally by
        // hipsFramingActiveProvider, so it contributes nothing when the
        // feature is off or the survey has no verified HiPS pyramid.
        const Positioned.fill(child: FramingHipsLayerWiring()),
        if (framingState.showOpticalConfigPanel)
          const Positioned(
            top: 16,
            left: 16,
            child: OpticalConfigPanel(),
          )
        else
          Positioned(
            top: 16,
            left: 16,
            child: Tooltip(
              message: 'Show optical config panel',
              child: Material(
                color: colors.surface,
                borderRadius: SkotiqTokens.borderRadiusInline8,
                child: InkWell(
                  borderRadius: SkotiqTokens.borderRadiusInline8,
                  onTap: () {
                    ref
                        .read(framingProvider.notifier)
                        .setOpticalConfigPanelVisible(true);
                  },
                  child: Container(
                    // ≥48px touch target so the show-config affordance is
                    // tappable on a phone (the inner icon stays 16px).
                    constraints: const BoxConstraints(
                      minWidth: SkotiqTokens.minTouchTarget,
                      minHeight: SkotiqTokens.minTouchTarget,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.border),
                      borderRadius: SkotiqTokens.borderRadiusInline8,
                    ),
                    child: Icon(
                      SkotiqIcons.aperture,
                      size: 16,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The full controls/target column. The search header is pinned and the
  /// remaining panels scroll, so the column fits any phone height without
  /// clipping.
  ///
  /// Reused verbatim by the desktop sidebar, the phone-landscape side panel
  /// (both bounded height → search pinned, body scrolls) and the phone bottom
  /// sheet (unbounded height → the whole column shrink-wraps, the surrounding
  /// sheet owns the scroll). [LayoutBuilder] picks the right mode so an
  /// `Expanded` is never placed in an unbounded parent.
  Widget _buildControlsColumn(
    SkotiqColors colors,
    FramingState framingState,
    TargetSearchState searchState,
    AsyncValue<FramingEquipmentResult> equipmentResult,
    (double, double)? currentAltAz,
  ) {
    final search = FramingTargetSearch(
      colors: colors,
      searchState: searchState,
      searchController: _searchController,
      searchFocusNode: _searchFocusNode,
      raController: _raController,
      decController: _decController,
      onTargetSelected: _selectTarget,
      onResolveByName: _resolveAndSelectTarget,
      onGoToManualCoordinates: _goToManualCoordinates,
    );

    // Phone (device-class) tightens the section rhythm: the controls live in a
    // short bottom sheet / narrow landscape side panel where the desktop 20 px
    // gaps + 16 px gutter waste scarce vertical/horizontal space. Tablet/desktop
    // keep the roomier spacing.
    final isPhone = Responsive.isPhone(context);
    final sectionGap =
        isPhone ? SkotiqTokens.spaceMd : SidePanel.sectionGap;
    final bodyPadding = isPhone
        ? const EdgeInsets.all(SkotiqTokens.spaceMd)
        : SidePanel.contentPadding;

    final panels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FramingActionsPanel(
          colors: colors,
          framingState: framingState,
          // Both add-to-sequence paths capture a POINTING: the emitted target
          // headers must carry the aim (the dragged reticle position), not the
          // view-center target. effectiveAimTarget is non-null here because
          // the buttons are gated on framingState.target != null.
          onAddToSequence: () => _addToSequence(
            framingState.effectiveAimTarget!,
            framingState.rotation,
          ),
          onAddToExistingSequence: () => _addToExistingSequence(
            framingState.effectiveAimTarget!,
            framingState.rotation,
          ),
          onSaveTarget: _saveTarget,
          onCacheImage: _cacheImage,
        ),
        SizedBox(height: sectionGap),
        FramingEquipmentSection(
          colors: colors,
          equipmentAsync: equipmentResult,
        ),
        SizedBox(height: sectionGap),
        FramingControlsSection(
          colors: colors,
          framingState: framingState,
          equipmentAsync: equipmentResult,
        ),
        SizedBox(height: sectionGap),
        FramingCoordinatesPanel(
          colors: colors,
          framingState: framingState,
          currentAltAz: currentAltAz,
        ),
        SizedBox(height: sectionGap),
        FramingAltitudePanel(
          colors: colors,
          framingState: framingState,
        ),
        SizedBox(height: sectionGap),
        FramingMosaicSection(
          colors: colors,
          framingState: framingState,
          equipmentAsync: equipmentResult,
        ),
        SizedBox(height: sectionGap),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Unbounded height (inside the phone bottom sheet, which scrolls):
        // shrink-wrap so we never put an Expanded in an unbounded parent.
        if (!constraints.hasBoundedHeight) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              search,
              Padding(
                padding: bodyPadding,
                child: panels,
              ),
            ],
          );
        }
        // Bounded height (desktop/tablet sidebar, phone-landscape side panel):
        // pin the search, scroll the body.
        return Column(
          children: [
            search,
            Expanded(
              child: SingleChildScrollView(
                padding: bodyPadding,
                child: panels,
              ),
            ),
          ],
        );
      },
    );
  }

  void _selectTarget(FramingTarget target) {
    final notifier = ref.read(framingProvider.notifier);
    // setTarget records this as the last framed target (single settings key)
    // so it restores across app restarts WITHOUT writing a row into the
    // targets library, which would pollute Analytics → Projects.
    notifier.setTarget(target);
    ref.read(targetSearchProvider.notifier).clear();
    _searchController.text = target.name;
    _raController.text = target.raFormatted;
    _decController.text = target.decFormatted;
    _searchFocusNode.unfocus();
    // Alt/Az auto-refreshes on the next build (framingProvider watch triggers it).
  }

  Future<void> _resolveAndSelectTarget(String name) async {
    final result = await SimbadResolver.resolve(name);
    if (!mounted) return;
    if (result == null) {
      context.showErrorSnackBar('Could not resolve "$name"');
      return;
    }
    final target = FramingTarget(
      name: result.mainId,
      catalogId: result.mainId,
      raHours: result.raHours,
      decDegrees: result.decDegrees,
      magnitude: result.magnitude,
    );
    _selectTarget(target);
  }

  void _goToManualCoordinates() {
    final ra = CoordinateUtils.parseRA(_raController.text);
    final dec = CoordinateUtils.parseDec(_decController.text);

    if (ra != null && dec != null) {
      ref
          .read(framingProvider.notifier)
          .setTargetCoordinates(ra, dec, name: 'Custom Location');
      // Alt/Az auto-refreshes on the next build (framingProvider watch triggers it).
    } else {
      context.showInfoSnackBar('Invalid coordinates');
    }
  }

  Future<void> _addToSequence(FramingTarget target, double rotation) async {
    final framingState = ref.read(framingProvider);
    final added = await addFramedTargetToSequencer(
      context: context,
      ref: ref,
      target: target,
      replaceSequence: true,
      sourceSuggestion: framingState.sourceSuggestion,
      rotationDegrees: rotation,
    );
    if (added && mounted) {
      context.go('/sequencer');
    }
  }

  /// Insert the framed target as a bare target header (no auto-generated
  /// instruction tree) into a sequence the user picks. Complements
  /// [_addToSequence], which auto-builds a full Smart Night sequence.
  Future<void> _addToExistingSequence(
    FramingTarget target,
    double rotation,
  ) async {
    // Carry the DRAWN mosaic through: inserting a single header at the grid
    // centre would drop the canvas panels with nothing in the dialog or the
    // confirmation to say the mosaic had been discarded.
    final framingState = ref.read(framingProvider);
    final panels = framingState.mosaicEnabled
        ? framingState.mosaicPanels
        : const <FramingMosaicPanel>[];

    final added = await addFramedTargetToExistingSequence(
      context: context,
      ref: ref,
      target: target,
      rotationDegrees: rotation,
      mosaicPanels: panels,
    );
    if (added && mounted) {
      context.showInfoSnackBar(
        panels.length >= 2
            ? 'Added ${panels.length} mosaic panels to sequence'
            : 'Added ${target.name} to sequence',
      );
    }
  }

  Future<void> _saveTarget() async {
    try {
      await ref.read(framingProvider.notifier).saveTarget();
      if (!mounted) return;
      context.showSuccessSnackBar('Target saved');
    } catch (e) {
      context.showErrorSnackBar('Failed to save: $e');
      if (!mounted) return;
    }
  }

  Future<void> _cacheImage() async {
    final framingState = ref.read(framingProvider);
    final bytes = framingState.surveyImageBytes;
    final target = framingState.target;

    if (target == null) {
      context.showInfoSnackBar('No target framed — pick a target first.');
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      context.showInfoSnackBar(
        'No survey image loaded yet — wait for the preview to finish loading.',
      );
      return;
    }

    final service = ref.read(framingImageCacheServiceProvider);
    try {
      final entry = await service.saveSurveyImage(
        bytes: bytes,
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        source: framingState.surveySource,
        targetName: target.name,
        catalogId: target.catalogId,
      );
      if (!mounted) return;
      context.showSuccessSnackBar('Cached at ${entry.filePath}');
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Failed to cache survey image: $e');
    }
  }
}

/// Thin Scaffold wrapper kept for the redirected standalone `/framing` route.
/// The reusable body lives in [FramingView], also hosted by Plan Tonight's
/// "Sky" tab.
class FramingScreen extends StatelessWidget {
  const FramingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SkotiqColors.of(context).background,
      body: const FramingView(),
    );
  }
}
