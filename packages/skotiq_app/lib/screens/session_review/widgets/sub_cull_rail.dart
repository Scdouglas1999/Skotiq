import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide ConnectionState;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../session_review_controller.dart';
import '../../../services/image_download_service.dart';
import '../../../utils/filter_label.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../utils/image_decode_size.dart';
import '../../../widgets/frame_exclusion_badge.dart';

part 'sub_cull_rail_parts/_toolbar.dart';
part 'sub_cull_rail_parts/_tiles.dart';
part 'sub_cull_rail_parts/_thumbnails.dart';

/// The session-review sub grid: grade-badged thumbnails of the night's lights
/// with **blink**, **bulk-reject below threshold**, per-sub accept/reject, a
/// per-sub "download to this device", plus two power-user culling affordances:
///
///  * **Multi-select / lasso cull** — tap to toggle a selection, or drag a
///    rubber-band rectangle over the grid to select every sub it touches, then
///    reject the whole selection in one action.
///  * **"Drop to recommended keepN"** — wired to the improvement curve's
///    [SubsetRecommendation]: rejects every accepted sub the optimizer does not
///    recommend keeping (down to `keepN`), in one click, with the predicted
///    SNR gain surfaced on the action chip.
///
/// This is the ONLY sub grid the app ships. It is mounted by the workbench
/// rendering of [SessionReviewController]; the narrative rendering is the
/// read-first story of the night (hero master, verdict, curves, findings) and
/// deliberately hosts no per-sub culling — the screen's one-tap
/// Narrative ↔ Workbench toggle is how an operator gets here.
class SubCullRail extends ConsumerStatefulWidget {
  /// The light subs to review (accepted + rejected), capture-time ascending.
  final List<DbCapturedImage> subs;

  /// The controller — read for the improvement curve and driven for the
  /// "drop to recommended" cull. Per-sub accept/reject and bulk-cull still flow
  /// through the explicit callbacks below so this rail composes with either
  /// scope without re-reading the provider family.
  final SessionReviewController controller;

  /// Open the per-sub detail dialog.
  final void Function(DbCapturedImage) onTapSub;

  /// Flip a single sub's accept flag.
  final void Function(int imageId, bool accepted) onSetAccepted;

  /// Reject every accepted sub above [hfrThreshold] (the threshold-bulk cull).
  final void Function({double? hfrThreshold, double? qualityThreshold})
      onBulkCull;

  const SubCullRail({
    super.key,
    required this.subs,
    required this.controller,
    required this.onTapSub,
    required this.onSetAccepted,
    required this.onBulkCull,
  });

  /// The grid's max cross-axis cell extent — mirrors the [SliverGridDelegate]
  /// `maxCrossAxisExtent` the grid lays out with. Exposed so the boundary-width
  /// regression test can build the same delegate.
  @visibleForTesting
  static const double lassoCellExtent = 200;

  /// The grid's cross-axis spacing — mirrors the delegate `crossAxisSpacing`.
  @visibleForTesting
  static const double lassoCellSpacing = SkotiqTokens.spaceMd;

  /// Column count the lasso hit-test uses for [innerWidth] (content width inside
  /// the grid padding). Matches Flutter's
  /// `SliverGridDelegateWithMaxCrossAxisExtent.getLayout` exactly:
  ///   `crossAxisCount = (crossAxisExtent / (maxCrossAxisExtent + spacing)).ceil()`
  /// with NO `+ spacing` added to the numerator. Adding it yields one extra
  /// column at widths near a multiple of (maxExtent + spacing), which throws off
  /// every per-cell rect and mis-selects subs at the lasso boundary.
  static int lassoGridColumns(double innerWidth) {
    final cols = (innerWidth / (lassoCellExtent + lassoCellSpacing)).ceil();
    return cols < 1 ? 1 : cols;
  }

  @override
  ConsumerState<SubCullRail> createState() => _SubCullRailState();
}

class _SubCullRailState extends ConsumerState<SubCullRail> {
  // blink
  bool _blink = false;
  int _blinkIndex = 0;
  Timer? _blinkTimer;

  // threshold bulk-cull
  double _hfrCull = 3.5;

  // multi-select / lasso
  bool _selectMode = false;
  final Set<int> _selected = <int>{};

  // Lasso drag state, in the grid's local coordinate space.
  Offset? _lassoStart;
  Offset? _lassoEnd;
  // Cell rects captured during layout so the lasso can hit-test them.
  final Map<int, Rect> _cellRects = <int, Rect>{};

  // Whether the curve-driven cull is offerable right now, kept in sync by
  // listening to the controller directly so the rail tracks the live state
  // without re-deriving the provider scope (the workbench passes the
  // controller, not the scope). This tracks the *offer*, not the curve, because
  // accepting/rejecting a sub can stale the curve without replacing it — the
  // toolbar has to re-render on that too or it would keep advertising a cull
  // the controller has already started refusing.
  CullRecommendationOffer _offer = CullRecommendationOffer.none;
  RemoveListener? _removeControllerListener;
  void _onControllerChanged(SessionReviewState _) {
    if (!mounted) return;
    final next = widget.controller.cullRecommendationOffer;
    if (next != _offer) setState(() => _offer = next);
  }

  @override
  void initState() {
    super.initState();
    // Seed before subscribing: addListener fires immediately, and a setState
    // out of initState is pointless churn.
    _offer = widget.controller.cullRecommendationOffer;
    _removeControllerListener =
        widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant SubCullRail oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!identical(oldWidget.controller, widget.controller)) {
      _removeControllerListener?.call();
      _offer = widget.controller.cullRecommendationOffer;
      _removeControllerListener =
          widget.controller.addListener(_onControllerChanged);
    }

    final currentIds = widget.subs.map((sub) => sub.id).toSet();
    _selected.removeWhere((id) => !currentIds.contains(id));
    _cellRects.removeWhere((id, _) => !currentIds.contains(id));

    if (widget.subs.isEmpty) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _blink = false;
      _blinkIndex = 0;
      _lassoStart = null;
      _lassoEnd = null;
    } else if (_blinkIndex >= widget.subs.length) {
      _blinkIndex = 0;
    }
  }

  @override
  void dispose() {
    _removeControllerListener?.call();
    _blinkTimer?.cancel();
    super.dispose();
  }

  void _toggleBlink() {
    setState(() {
      _blink = !_blink;
      _blinkIndex = 0;
    });
    _blinkTimer?.cancel();
    if (_blink && widget.subs.isNotEmpty) {
      _blinkTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
        if (!mounted || widget.subs.isEmpty) {
          _blinkTimer?.cancel();
          _blinkTimer = null;
          if (mounted) {
            setState(() {
              _blink = false;
              _blinkIndex = 0;
            });
          }
          return;
        }
        setState(() => _blinkIndex = (_blinkIndex + 1) % widget.subs.length);
      });
    }
  }

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      if (!_selectMode) {
        _selected.clear();
        _lassoStart = null;
        _lassoEnd = null;
      }
    });
  }

  void _toggleSelected(int imageId) {
    setState(() {
      if (!_selected.add(imageId)) _selected.remove(imageId);
    });
  }

  Future<void> _rejectSelected() async {
    final ids = _selected.toList();
    final currentSubs = {for (final sub in widget.subs) sub.id: sub};
    for (final id in ids) {
      final sub = currentSubs[id];
      if (sub == null) continue;
      if (sub.isAccepted) widget.onSetAccepted(id, false);
    }
    setState(() {
      _selected.clear();
      _lassoStart = null;
      _lassoEnd = null;
    });
  }

  Future<void> _cullToRecommended(CullRecommendationOffer offer) async {
    final result = await widget.controller.cullToRecommended();
    if (!mounted) return;
    final keepN = offer.keepN;
    final String message;
    switch (result.outcome) {
      case CullOutcome.culled:
        message = 'Culled to best $keepN subs (${result.rejected} rejected, '
            '+${offer.gainPct.toStringAsFixed(0)}% SNR)';
        break;
      case CullOutcome.alreadyOptimal:
        message = 'Already at the recommended $keepN subs';
        break;
      case CullOutcome.staleCurve:
        message =
            'Curve is out of date — re-integrate to refresh before culling';
        break;
    }
    SkotiqToastHelper.show(
      context: context,
      message: message,
      severity: SkotiqAlertSeverity.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (widget.subs.isEmpty) {
      return const EmptyState(
        icon: SkotiqIcons.imageOff,
        title: 'No light subs',
        body: 'This session captured no light frames to review.',
      );
    }

    const assessor = FrameQualityAssessmentService();
    final assessments = assessor.assessBatch(widget.subs);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceMd,
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceSm,
          ),
          child: _CullToolbar(
            blink: _blink,
            selectMode: _selectMode,
            selectedCount: _selected.length,
            hfrThreshold: _hfrCull,
            offer: _offer,
            acceptedCount: widget.subs.where((sub) => sub.isAccepted).length,
            rejectedCount: widget.subs.where((sub) => !sub.isAccepted).length,
            onToggleBlink: _toggleBlink,
            onToggleSelect: _toggleSelectMode,
            onHfrChanged: (v) => setState(() => _hfrCull = v),
            onBulkCull: () => widget.onBulkCull(hfrThreshold: _hfrCull),
            onRejectSelected: _selected.isEmpty ? null : _rejectSelected,
            onClearSelection: _selected.isEmpty
                ? null
                : () => setState(() => _selected.clear()),
            // Only an offerable cull gets a pressable action. Stale /
            // already-optimal render an explanatory status chip instead — the
            // controller would refuse the press in both cases.
            onCullToRecommended:
                _offer.isOfferable ? () => _cullToRecommended(_offer) : null,
          ),
        ),
        if (_blink)
          Expanded(child: _BlinkView(sub: widget.subs[_blinkIndex]))
        else
          Expanded(child: _buildGrid(assessments, colors)),
      ],
    );
  }

  // Fixed grid geometry — kept in lock-step with the SliverGridDelegate below
  // so the lasso can hit-test cell rects analytically (a GridView gives no
  // per-cell rect, and reporting them from render objects is brittle under
  // scrolling). Padding + spacing + aspect ratio fully determine the layout.
  static const double _gridPad = SkotiqTokens.spaceLg;
  static const double _maxCellExtent = SubCullRail.lassoCellExtent;
  static const double _cellSpacing = SubCullRail.lassoCellSpacing;
  static const double _cellAspect = 0.82; // width / height

  /// Resolve column count, cell width and cell height for [innerWidth] (the
  /// content width inside the grid padding), matching Flutter's
  /// max-cross-axis-extent packing.
  ({int cols, double cellW, double cellH}) _gridMetrics(double innerWidth) {
    final cols = SubCullRail.lassoGridColumns(innerWidth);
    final cellW = (innerWidth - (cols - 1) * _cellSpacing) / cols;
    final cellH = cellW / _cellAspect;
    return (cols: cols, cellW: cellW, cellH: cellH);
  }

  /// Recompute every cell's rect (relative to the gesture surface origin) and
  /// select those the [marquee] overlaps.
  void _applyLasso(Rect marquee, double innerWidth) {
    final m = _gridMetrics(innerWidth);
    _cellRects.clear();
    for (var i = 0; i < widget.subs.length; i++) {
      final col = i % m.cols;
      final row = i ~/ m.cols;
      final left = _gridPad + col * (m.cellW + _cellSpacing);
      final top = _gridPad + row * (m.cellH + _cellSpacing);
      final rect = Rect.fromLTWH(left, top, m.cellW, m.cellH);
      _cellRects[widget.subs[i].id] = rect;
      if (rect.overlaps(marquee)) _selected.add(widget.subs[i].id);
    }
  }

  Widget _buildGrid(
    Map<int, FrameQualityAssessment> assessments,
    SkotiqColors colors,
  ) {
    final grid = GridView.builder(
      padding: const EdgeInsets.all(_gridPad),
      physics: _selectMode
          ? const NeverScrollableScrollPhysics()
          : const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _maxCellExtent,
        mainAxisSpacing: _cellSpacing,
        crossAxisSpacing: _cellSpacing,
        childAspectRatio: _cellAspect,
      ),
      itemCount: widget.subs.length,
      itemBuilder: (context, index) {
        final sub = widget.subs[index];
        return _SubTile(
          sub: sub,
          assessment: assessments[sub.id],
          selectMode: _selectMode,
          selected: _selected.contains(sub.id),
          onTap: _selectMode
              ? () => _toggleSelected(sub.id)
              : () => widget.onTapSub(sub),
          onToggleAccept: () => widget.onSetAccepted(sub.id, !sub.isAccepted),
          colors: colors,
        );
      },
    );

    if (!_selectMode) return grid;

    // In select mode the grid stops scrolling; a GestureDetector captures the
    // rubber-band lasso and a CustomPaint draws the marquee. Cell hit-testing
    // is analytic against the grid geometry resolved from this width.
    return LayoutBuilder(
      builder: (context, constraints) {
        final innerWidth = constraints.maxWidth - 2 * _gridPad;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (d) =>
              setState(() => _lassoStart = _lassoEnd = d.localPosition),
          onPanUpdate: (d) {
            if (_lassoStart == null) return;
            setState(() => _lassoEnd = d.localPosition);
          },
          onPanEnd: (_) {
            final s = _lassoStart, e = _lassoEnd;
            if (s != null && e != null) {
              setState(() => _applyLasso(Rect.fromPoints(s, e), innerWidth));
            }
            setState(() => _lassoStart = _lassoEnd = null);
          },
          child: Stack(
            children: [
              grid,
              if (_lassoStart != null && _lassoEnd != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _LassoPainter(
                        rect: Rect.fromPoints(_lassoStart!, _lassoEnd!),
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
