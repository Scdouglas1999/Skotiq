part of '../mosaic_wizard_dialog.dart';

class _VisualMosaicPlanner extends StatefulWidget {
  final SkotiqColors colors;
  final double centerRa;
  final double centerDec;
  final List<_PanelPosition> panels;
  final double panelWidthArcmin;
  final double panelHeightArcmin;
  final double rotation;
  final ValueChanged<_PanelPosition> onPanelToggle;

  /// Drag callback: (deltaRaHours, deltaDecDegrees).
  final void Function(double dRaHours, double dDecDeg) onDragCenter;

  const _VisualMosaicPlanner({
    super.key,
    required this.colors,
    required this.centerRa,
    required this.centerDec,
    required this.panels,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    required this.rotation,
    required this.onPanelToggle,
    required this.onDragCenter,
  });

  @override
  State<_VisualMosaicPlanner> createState() => _VisualMosaicPlannerState();
}

class _VisualMosaicPlannerState extends State<_VisualMosaicPlanner> {
  double _zoom = 1.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final basePxPerDeg = math.min(
              constraints.maxWidth,
              constraints.maxHeight,
            ) /
            8.0;
        final pxPerDeg = basePxPerDeg * _zoom;

        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _StarFieldPainter(),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _RaDecGridPainter(
                  pxPerDeg: pxPerDeg,
                ),
              ),
            ),
            Positioned.fill(
              child: _PanelLayer(
                colors: widget.colors,
                centerRa: widget.centerRa,
                centerDec: widget.centerDec,
                panels: widget.panels,
                panelWidthArcmin: widget.panelWidthArcmin,
                panelHeightArcmin: widget.panelHeightArcmin,
                rotation: widget.rotation,
                pxPerDeg: pxPerDeg,
                onPanelToggle: widget.onPanelToggle,
                onDragCenter: widget.onDragCenter,
              ),
            ),
            Positioned(
              left: 10,
              top: 10,
              child: _CoordHud(
                ra: widget.centerRa,
                dec: widget.centerDec,
                rotation: widget.rotation,
              ),
            ),
            Positioned(
              right: 10,
              bottom: 10,
              child: _ZoomControls(
                zoom: _zoom,
                onZoomIn: () =>
                    setState(() => _zoom = (_zoom * 1.4).clamp(0.25, 4.0)),
                onZoomOut: () =>
                    setState(() => _zoom = (_zoom / 1.4).clamp(0.25, 4.0)),
                onReset: () => setState(() => _zoom = 1.0),
              ),
            ),
            Positioned(
              left: 10,
              bottom: 10,
              child: _Legend(colors: widget.colors),
            ),
          ],
        );
      },
    );
  }
}

class _CoordHud extends StatelessWidget {
  final double ra;
  final double dec;
  final double rotation;

  const _CoordHud({
    required this.ra,
    required this.dec,
    required this.rotation,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // absolute: HUD scrim over the dark sky planner canvas
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Text(
        'RA ${ra.toStringAsFixed(3)}h   Dec ${dec.toStringAsFixed(2)}°   '
        'Rot ${rotation.toStringAsFixed(0)}°',
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: SkotiqTypography.fontSize11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final SkotiqColors colors;
  const _Legend({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        // absolute: HUD scrim over the dark sky planner canvas
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.move, size: 11, color: colors.primary),
          const SizedBox(width: 4),
          // absolute: HUD label over the dark sky planner canvas
          const Text('Drag centre',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: SkotiqTypography.fontSize10)),
          const SizedBox(width: 12),
          Icon(LucideIcons.mousePointerClick, size: 11, color: colors.accent),
          const SizedBox(width: 4),
          // absolute: HUD label over the dark sky planner canvas
          const Text('Tap panel to toggle',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: SkotiqTypography.fontSize10)),
        ],
      ),
    );
  }
}

class _ZoomControls extends StatelessWidget {
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomControls({
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        // absolute: HUD scrim over the dark sky planner canvas
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(SkotiqIcons.add, size: 14),
            onPressed: onZoomIn,
            tooltip: 'Zoom in',
            // absolute: HUD control over the dark sky planner canvas
            color: Colors.white70,
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          ),
          Text('${(zoom * 100).round()}%',
              // absolute: HUD label over the dark sky planner canvas
              style: const TextStyle(
                  color: Colors.white54, fontSize: SkotiqTypography.fontSize9)),
          IconButton(
            icon: const Icon(SkotiqIcons.remove, size: 14),
            onPressed: onZoomOut,
            tooltip: 'Zoom out',
            // absolute: HUD control over the dark sky planner canvas
            color: Colors.white70,
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          ),
          IconButton(
            icon: const Icon(SkotiqIcons.crosshair, size: 14),
            onPressed: onReset,
            tooltip: 'Reset zoom',
            // absolute: HUD control over the dark sky planner canvas
            color: Colors.white70,
            padding: const EdgeInsets.all(2),
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          ),
        ],
      ),
    );
  }
}

/// The shortest signed separation for a circular angle, in (-180, 180].
double _wrapDegreesSigned(double degrees) {
  final wrapped = degrees % 360.0;
  if (wrapped > 180.0) return wrapped - 360.0;
  if (wrapped <= -180.0) return wrapped + 360.0;
  return wrapped;
}

class _PanelLayer extends StatelessWidget {
  final SkotiqColors colors;
  final double centerRa;
  final double centerDec;
  final List<_PanelPosition> panels;
  final double panelWidthArcmin;
  final double panelHeightArcmin;
  final double rotation;
  final double pxPerDeg;
  final ValueChanged<_PanelPosition> onPanelToggle;
  final void Function(double dRaHours, double dDecDeg) onDragCenter;

  const _PanelLayer({
    required this.colors,
    required this.centerRa,
    required this.centerDec,
    required this.panels,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    required this.rotation,
    required this.pxPerDeg,
    required this.onPanelToggle,
    required this.onDragCenter,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final centerPx = Offset(
        constraints.maxWidth / 2,
        constraints.maxHeight / 2,
      );

      return GestureDetector(
        onPanUpdate: (details) {
          final dxDeg = details.delta.dx / pxPerDeg;
          final dyDeg = details.delta.dy / pxPerDeg;
          final decRad = centerDec * math.pi / 180.0;
          final cosDec =
              math.cos(decRad).abs() < 0.001 ? 0.001 : math.cos(decRad);
          // Dragging right moves the visible sky right, i.e. the
          // mosaic centre shifts to lower RA. dy follows screen
          // coordinates (down = negative dec).
          final dRaHours = -dxDeg / 15.0 / cosDec;
          final dDecDeg = dyDeg;
          onDragCenter(dRaHours, dDecDeg);
        },
        child: Stack(
          children: [
            for (final p in panels) _panelWidget(p, centerPx),
            Positioned(
              left: centerPx.dx - 6,
              top: centerPx.dy - 6,
              child: IgnorePointer(
                child: Container(
                  key: const ValueKey('mosaic_center_handle'),
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: colors.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.textPrimary, width: 1.5),
                  ),
                ),
              ),
            ),
            // The numbers are their own layer, drawn AFTER the centre handle.
            // Moving them from each cell's centre to its top-left corner
            // cleared the handle for ODD grids, where the handle sits in the
            // middle of a cell — but an even grid puts the handle on the
            // shared CORNER of four cells, which is exactly where a top-left
            // badge lives, so the collision came back on 2x2 / 4x4 (and gets
            // worse as overlap % grows, which pulls the corner further in).
            // No placement clears the handle for every grid parity, so the
            // number wins the z-order instead: the digit is the information
            // the operator needs to map the picture onto the plan, and the
            // handle stays readable as a dot behind it.
            for (final p in panels) _panelNumber(p, centerPx),
          ],
        ),
      );
    });
  }

  /// Where a panel's cell lands on the planner canvas, in pixels.
  ///
  /// Shared by the panel body and its number badge so the two layers cannot
  /// drift apart.
  ({Offset topLeft, Size size}) _panelGeometry(
    _PanelPosition p,
    Offset centerPx,
  ) {
    // RA is circular: a mosaic centred at 0.0h puts its western column near
    // 23.9h, and a plain subtraction reads that as +358.5 degrees instead of
    // -1.5, positioning the whole column a sky away and off the canvas. Wrap
    // the separation into (-180, 180] so panels either side of the 0h seam land
    // where the operator is looking — and can therefore be tapped off.
    final dRaDeg = _wrapDegreesSigned((p.ra - centerRa) * 15);
    final dDecDeg = p.dec - centerDec;
    final decRad = centerDec * math.pi / 180.0;
    final cosDec = math.cos(decRad);
    final dxDeg = dRaDeg * cosDec;
    final dyDeg = -dDecDeg;

    final panelCenterPx = centerPx +
        Offset(
          dxDeg * pxPerDeg,
          dyDeg * pxPerDeg,
        );
    final pxWidth = (panelWidthArcmin / 60.0) * pxPerDeg;
    final pxHeight = (panelHeightArcmin / 60.0) * pxPerDeg;

    return (
      topLeft: Offset(
        panelCenterPx.dx - pxWidth / 2,
        panelCenterPx.dy - pxHeight / 2,
      ),
      size: Size(pxWidth, pxHeight),
    );
  }

  Widget _panelWidget(_PanelPosition p, Offset centerPx) {
    final g = _panelGeometry(p, centerPx);

    return Positioned(
      left: g.topLeft.dx,
      top: g.topLeft.dy,
      child: Transform.rotate(
        angle: rotation * math.pi / 180.0,
        child: GestureDetector(
          key: ValueKey('mosaic_panel_${p.row}_${p.col}'),
          onTap: () => onPanelToggle(p),
          child: Container(
            width: g.size.width,
            height: g.size.height,
            decoration: BoxDecoration(
              color: p.enabled
                  ? colors.primary.withValues(alpha: 0.18)
                  // absolute: disabled panel over the dark sky planner canvas
                  : Colors.grey.withValues(alpha: 0.05),
              border: Border.all(
                color: p.enabled
                    ? colors.primary
                    // absolute: disabled panel over the dark sky planner canvas
                    : Colors.grey.withValues(alpha: 0.5),
                width: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The panel number, drawn in its own top-most layer.
  ///
  /// It sits in the cell's top-left corner rather than its centre: centred,
  /// the middle panel of any odd grid hides under the drag-centre handle.
  /// It is pointer-transparent so a tap still toggles the panel
  /// underneath, and it is the last thing painted so neither the handle nor
  /// a neighbouring panel's overlap fill can sit on top of a digit.
  Widget _panelNumber(_PanelPosition p, Offset centerPx) {
    final g = _panelGeometry(p, centerPx);

    return Positioned(
      left: g.topLeft.dx,
      top: g.topLeft.dy,
      child: IgnorePointer(
        child: Transform.rotate(
          angle: rotation * math.pi / 180.0,
          child: SizedBox(
            width: g.size.width,
            height: g.size.height,
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Container(
                  key: ValueKey('mosaic_panel_number_${p.row}_${p.col}'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    // absolute: label scrim over the dark sky planner canvas
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    '${p.index + 1}',
                    style: TextStyle(
                      fontSize: math.max(10, g.size.width * 0.12),
                      // absolute: disabled panel index over the dark sky canvas
                      color: p.enabled ? colors.textPrimary : Colors.white24,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Painters
