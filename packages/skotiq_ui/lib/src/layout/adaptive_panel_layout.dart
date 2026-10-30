import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../tokens/breakpoint_tokens.dart';
import '../utils/responsive_utils.dart';
import '../utils/shell_back_dispatcher.dart';

/// How [AdaptivePanelLayout] collapses its secondary panel(s) on a phone.
enum PhonePanelStrategy {
  /// Secondary content lives in a bottom sheet toggled by a handle/button at
  /// the bottom edge. While COLLAPSED the handle reserves its own height, so
  /// the primary region ends where the handle begins and bottom-anchored
  /// primary chrome is never painted over. While OPEN the sheet overlays the
  /// (then full-height) primary region.
  bottomSheet,

  /// A segmented control switches the whole region between the primary view
  /// and the secondary view (controls).
  segmented,
}

/// Side that the secondary panel sits on in the desktop / tablet split.
enum PanelSide { start, end }

/// One collapsible secondary panel.
@immutable
class AdaptivePanel {
  /// Short title shown on the segmented control / sheet handle / tab.
  final String title;

  /// The panel body.
  final Widget child;

  /// Optional icon for the segmented control / sheet handle.
  final IconData? icon;

  const AdaptivePanel({required this.title, required this.child, this.icon});
}

/// The desktop-resizable / tablet-fixed / phone-collapsing panel split.
///
/// * **Desktop** (`w >= 768`, i.e. [BreakpointTokens.isAtLeastDesktop]):
///   [primary] beside the [secondary] panel(s) with a draggable divider,
///   matching `ResizablePanel`'s geometry.
/// * **Tablet** (`600 <= w < 768`): fixed-ratio columns (no drag handle).
/// * **Phone portrait** (`w < 600`): the secondary panel(s) collapse per
///   [phoneStrategy] — a toggled bottom sheet, or a segmented switch between
///   primary and secondary.
/// * **Phone landscape**: if width allows ([landscapeSplitMinWidth]) it shows a
///   fixed side-by-side split (image/canvas left, controls right); otherwise it
///   falls back to the phone-portrait collapse.
///
/// Pass one or two panels in [secondary]. With two panels on desktop they
/// stack vertically inside the side column; on phone they become two segments /
/// two sheet sections.
///
/// ```dart
/// AdaptivePanelLayout(
///   primary: ImageViewer(),
///   secondary: [AdaptivePanel(title: 'Controls', icon: Icons.tune, child: Controls())],
///   phoneStrategy: PhonePanelStrategy.bottomSheet,
///   initialPanelWidth: 320,
/// )
/// ```
class AdaptivePanelLayout extends StatefulWidget {
  /// The dominant region (image / canvas / main content).
  final Widget primary;

  /// One or two collapsible side panels.
  final List<AdaptivePanel> secondary;

  /// A strip drawn ONCE above whichever secondary panels are on screen, or null
  /// when the panels need no shared heading.
  ///
  /// It exists because "above the panels" is a different number of places on
  /// each layout, and only this widget knows which. The Darkroom's compare
  /// banner — the strip that names which of the two branches the Recipe and
  /// History stacks belong to — was built into each panel's body instead, so on
  /// desktop, where [_secondaryColumn] stacks both panels in ONE visible
  /// column, the same sentence was drawn twice, one above the other, and
  /// published twice to assistive tech. On a phone the segments show one panel
  /// at a time and it read correctly, which is why it survived: the duplicate
  /// exists only on the layout the editor is actually used on.
  ///
  /// Rendered above the stacked column on desktop and tablet, above the
  /// SELECTED panel on the segmented phone layout (never above the primary
  /// segment, which is not a secondary surface), and once at the top of the
  /// phone bottom sheet. One header per surface the operator can see.
  final Widget? secondaryHeader;

  /// Phone collapse strategy (default: [PhonePanelStrategy.bottomSheet]).
  final PhonePanelStrategy phoneStrategy;

  /// Which side the secondary column sits on for the desktop/tablet split.
  final PanelSide panelSide;

  /// Initial / desktop width of the secondary column in logical pixels.
  final double initialPanelWidth;

  /// Minimum drag width (desktop).
  final double minPanelWidth;

  /// Maximum drag width (desktop).
  final double maxPanelWidth;

  /// Fraction of width given to the secondary column on tablet (fixed).
  final double tabletPanelFraction;

  /// Minimum total width before phone *landscape* uses a side-by-side split
  /// instead of collapsing. Defaults to 560.
  final double landscapeSplitMinWidth;

  /// Label for the primary segment in [PhonePanelStrategy.segmented].
  final String primarySegmentLabel;

  /// Optional icon for the primary segment.
  final IconData? primarySegmentIcon;

  /// Called when the panel is resized on desktop (final width).
  final ValueChanged<double>? onPanelWidthChanged;

  const AdaptivePanelLayout({
    super.key,
    required this.primary,
    required this.secondary,
    this.secondaryHeader,
    this.phoneStrategy = PhonePanelStrategy.bottomSheet,
    this.panelSide = PanelSide.end,
    this.initialPanelWidth = 320,
    this.minPanelWidth = 240,
    this.maxPanelWidth = 560,
    this.tabletPanelFraction = 0.38,
    this.landscapeSplitMinWidth = 560,
    this.primarySegmentLabel = 'View',
    this.primarySegmentIcon,
    this.onPanelWidthChanged,
  }) : assert(
         secondary.length >= 1 && secondary.length <= 2,
         'AdaptivePanelLayout takes one or two secondary panels',
       );

  @override
  State<AdaptivePanelLayout> createState() => _AdaptivePanelLayoutState();
}

/// Minimum region height before the collapsed sheet handle is allowed to
/// RESERVE its own row instead of floating over the primary region.
const double _sheetHandleReserveFloor = 160.0;

class _AdaptivePanelLayoutState extends State<AdaptivePanelLayout> {
  late double _panelWidth = widget.initialPanelWidth;

  // Phone state.
  bool _sheetOpen = false;
  int _segment = 0; // 0 = primary, 1.. = secondary panels.

  @override
  void initState() {
    super.initState();
    ShellBackDispatcher.register(_handleSystemBack);
  }

  @override
  void dispose() {
    ShellBackDispatcher.unregister(_handleSystemBack);
    super.dispose();
  }

  /// System back closes an open phone bottom sheet instead of leaving the
  /// screen. Guarded on route currency: shell tabs keep their state alive
  /// while hidden, and a background tab's open sheet must not swallow back.
  bool _handleSystemBack() {
    if (!_sheetOpen || !mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    setState(() => _sheetOpen = false);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // A phone DEVICE must use a phone strategy in BOTH orientations — never
    // desktop chrome. In landscape the region is wide (e.g. 900 px), so a
    // width-only check would wrongly take the desktop split. We also keep the
    // width check so a narrow embedded region on desktop still collapses.
    final isPhoneDevice = Responsive.isPhone(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final isLandscape = w > h;

        if (isPhoneDevice || BreakpointTokens.isPhone(w)) {
          // Phone landscape with enough width: a fixed side-by-side split
          // (image/canvas beside its controls) instead of a wasteful single
          // wide column.
          if (isLandscape && w >= widget.landscapeSplitMinWidth) {
            return _buildFixedSplit(
              context,
              panelWidth: (w * 0.42).clamp(220.0, 360.0),
            );
          }
          return _buildPhoneCollapsed(context);
        }

        if (BreakpointTokens.isAtLeastDesktop(w)) {
          // Desktop: resizable split.
          return _buildResizableSplit(context, available: w);
        }

        // Tablet: fixed-ratio split.
        final panelWidth = (w * widget.tabletPanelFraction).clamp(220.0, 420.0);
        return _buildFixedSplit(context, panelWidth: panelWidth);
      },
    );
  }

  // Desktop / tablet splits

  Widget _secondaryColumn() {
    final children = <Widget>[];
    // One header over the whole column: this is the single surface both panels
    // are stacked on, so one is what the operator sees and one is what
    // assistive tech reads.
    final header = widget.secondaryHeader;
    if (header != null) children.add(header);
    for (var i = 0; i < widget.secondary.length; i++) {
      if (i > 0) {
        children.add(const SizedBox(height: SkotiqTokens.spaceSm));
      }
      children.add(Expanded(child: widget.secondary[i].child));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _buildFixedSplit(BuildContext context, {required double panelWidth}) {
    final colors = context.skotiqColors;
    final divider = Container(width: 1, color: colors.border);
    final panel = SizedBox(width: panelWidth, child: _secondaryColumn());
    final primary = Expanded(child: widget.primary);

    return Row(
      children: widget.panelSide == PanelSide.start
          ? [panel, divider, primary]
          : [primary, divider, panel],
    );
  }

  Widget _buildResizableSplit(
    BuildContext context, {
    required double available,
  }) {
    final colors = context.skotiqColors;
    // Clamp the live width to what fits, leaving room for the primary region.
    final maxForPanel = (available - 240).clamp(
      widget.minPanelWidth,
      widget.maxPanelWidth,
    );
    final width = _panelWidth.clamp(widget.minPanelWidth, maxForPanel);

    final handle = _ResizeHandle(
      side: widget.panelSide,
      color: colors.border.withValues(alpha: 0.35),
      activeColor: colors.borderHighlight,
      onDelta: (dx) {
        setState(() {
          // Dragging the divider toward the panel shrinks it.
          final delta = widget.panelSide == PanelSide.end ? -dx : dx;
          _panelWidth = (width + delta).clamp(
            widget.minPanelWidth,
            maxForPanel,
          );
        });
        widget.onPanelWidthChanged?.call(_panelWidth);
      },
    );

    final panel = SizedBox(width: width, child: _secondaryColumn());
    final primary = Expanded(child: widget.primary);

    return Row(
      children: widget.panelSide == PanelSide.start
          ? [panel, handle, primary]
          : [primary, handle, panel],
    );
  }

  // Phone collapse

  Widget _buildPhoneCollapsed(BuildContext context) {
    switch (widget.phoneStrategy) {
      case PhonePanelStrategy.bottomSheet:
        return _buildPhoneSheet(context);
      case PhonePanelStrategy.segmented:
        return _buildPhoneSegmented(context);
    }
  }

  Widget _buildPhoneSheet(BuildContext context) {
    final colors = context.skotiqColors;
    // The collapsed handle RESERVES its height in a Column rather than floating
    // over the primary region on a Stack. Floating it meant `primary` was laid
    // out at the full viewport height while the handle painted across its last
    // ~56dp — so anything the primary anchors to its OWN bottom edge was sliced
    // in half. On the Imaging screen that cut straight through the bottom-left
    // histogram and the bottom-right HFR/Mean stats readout (both
    // `Positioned(bottom: 16)`), rendering half a row of live frame statistics
    // under an opaque bar. Reserving the space is also what a peeking Material
    // bottom sheet does, so the primary now ends exactly where the handle
    // begins and no consumer has to guess an inset.
    final handle = _SheetHandleButton(
      label: widget.secondary.first.title,
      icon: widget.secondary.first.icon,
      onTap: () => setState(() => _sheetOpen = true),
    );

    final body = LayoutBuilder(
      builder: (context, constraints) {
        // Reserving only works while the region can actually SEAT the handle:
        // the shell hands this layout a degenerate height on transient frames
        // (a keyboard inset landing before the sibling capture bar has
        // resized), and a Column asked to fit a ~56dp handle into less than
        // that overflows. Under the floor, overlay the handle instead so a
        // transient frame degrades rather than throwing.
        final canReserve =
            !constraints.hasBoundedHeight ||
            constraints.maxHeight >= _sheetHandleReserveFloor;

        if (_sheetOpen) {
          return SizedBox.expand(child: widget.primary);
        }
        if (!canReserve) {
          return Stack(
            children: [
              Positioned.fill(child: widget.primary),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(top: false, child: handle),
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: widget.primary),
            SafeArea(top: false, child: handle),
          ],
        );
      },
    );

    if (!_sheetOpen) return body;

    // Open: the sheet overlays the (now full-height) primary region.
    return Stack(
      children: [
        Positioned.fill(child: body),
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _sheetOpen = false),
            child: ColoredBox(
              color: colors.background.withValues(alpha: 0.55),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  onTap: _keepPhoneSheetOpen,
                  child: _PhoneSheet(
                    panels: widget.secondary,
                    header: widget.secondaryHeader,
                    onClose: () => setState(() => _sheetOpen = false),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Claims taps on non-interactive sheet chrome so the backdrop recognizer
  /// cannot close the sheet through its child. Interactive controls inside
  /// the sheet still win the gesture arena and run their own callbacks.
  void _keepPhoneSheetOpen() {
    if (!_sheetOpen) {
      setState(() => _sheetOpen = true);
    }
  }

  Widget _buildPhoneSegmented(BuildContext context) {
    final segments = <_SegmentSpec>[
      _SegmentSpec(
        label: widget.primarySegmentLabel,
        icon: widget.primarySegmentIcon,
      ),
      for (final p in widget.secondary)
        _SegmentSpec(label: p.title, icon: p.icon),
    ];
    final selected = _segment.clamp(0, segments.length - 1);

    final header = widget.secondaryHeader;
    // Above the SELECTED secondary panel and nothing else. The primary segment
    // is not a secondary surface, and only one secondary segment is ever on
    // screen, so this is one header per visible surface here too.
    final Widget body = selected == 0
        ? widget.primary
        : (header == null
              ? widget.secondary[selected - 1].child
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header,
                    Expanded(child: widget.secondary[selected - 1].child),
                  ],
                ));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
          child: _SegmentedControl(
            segments: segments,
            selectedIndex: selected,
            onSelected: (i) => setState(() => _segment = i),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

// Resize handle (desktop)

class _ResizeHandle extends StatefulWidget {
  final PanelSide side;
  final Color color;
  final Color activeColor;
  final ValueChanged<double> onDelta;

  const _ResizeHandle({
    required this.side,
    required this.color,
    required this.activeColor,
    required this.onDelta,
  });

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onHorizontalDragStart: (_) => setState(() => _drag = true),
        onHorizontalDragEnd: (_) => setState(() => _drag = false),
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        child: Container(
          width: 10,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 2,
              height: double.infinity,
              color: _drag || _hover ? widget.activeColor : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}

// Phone bottom sheet

class _SheetHandleButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _SheetHandleButton({
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      // The InkWell publishes a tap and nothing else, so the only way into the
      // phone sheet announced itself as a disabled panel.
      button: true,
      enabled: true,
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Material(
          color: colors.surfaceElevated,
          borderRadius: SkotiqTokens.borderRadiusLg,
          elevation: 0,
          child: InkWell(
            onTap: onTap,
            borderRadius: SkotiqTokens.borderRadiusLg,
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                borderRadius: SkotiqTokens.borderRadiusLg,
                border: Border.all(color: colors.border),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceLg,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon ?? Icons.keyboard_arrow_up,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.labelLg.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PhoneSheet extends StatelessWidget {
  final List<AdaptivePanel> panels;

  /// The strip drawn once at the top of the sheet — the sheet IS one visible
  /// surface, however many panels it stacks inside it.
  final Widget? header;
  final VoidCallback onClose;

  const _PhoneSheet({
    required this.panels,
    required this.header,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(SkotiqTokens.radiusXl),
        ),
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grab handle.
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(
                  vertical: SkotiqTokens.spaceSm,
                ),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.border,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.spaceLg,
                  0,
                  SkotiqTokens.spaceLg,
                  SkotiqTokens.spaceLg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (header != null) ...[
                      header!,
                      const SizedBox(height: SkotiqTokens.spaceSm),
                    ],
                    for (var i = 0; i < panels.length; i++) ...[
                      if (i > 0) const SizedBox(height: SkotiqTokens.spaceLg),
                      if (panels.length > 1)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: SkotiqTokens.spaceSm,
                          ),
                          child: Text(
                            panels[i].title.toUpperCase(),
                            style: SkotiqTypography.overline.copyWith(
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                      panels[i].child,
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Segmented control (phone)

class _SegmentSpec {
  final String label;
  final IconData? icon;
  const _SegmentSpec({required this.label, this.icon});
}

class _SegmentedControl extends StatelessWidget {
  final List<_SegmentSpec> segments;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _SegmentedControl({
    required this.segments,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (var i = 0; i < segments.length; i++)
            Expanded(
              child: _SegmentButton(
                spec: segments[i],
                isSelected: i == selectedIndex,
                onTap: () => onSelected(i),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  final _SegmentSpec spec;
  final bool isSelected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.spec,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final fg = isSelected ? colors.onPrimary : colors.textSecondary;
    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      selected: isSelected,
      label: spec.label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: SkotiqTokens.borderRadiusSm,
          child: AnimatedContainer(
            duration: SkotiqTokens.durationQuick,
            curve: SkotiqTokens.curveSnappy,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isSelected ? colors.primary : Colors.transparent,
              borderRadius: SkotiqTokens.borderRadiusSm,
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceSm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (spec.icon != null) ...[
                  Icon(spec.icon, size: 15, color: fg),
                  const SizedBox(width: SkotiqTokens.spaceXs + 2),
                ],
                Flexible(
                  child: Text(
                    spec.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.labelSm.copyWith(
                      color: fg,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
