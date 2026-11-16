import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The places on the framing canvas that hold chrome. Each holds one glass
/// group; there is no fifth place.
enum FramingChromeSlot {
  /// Top left: what is framed.
  target,

  /// Top right: the survey and the layer menu.
  toolbar,

  /// Bottom left: the scale bar, then the survey's credit or its notice.
  status,

  /// Bottom right: zoom.
  zoom,
}

/// Lays the framing canvas's glass groups out in its four corners so that no
/// two of them ever overlap, at any canvas size.
///
/// The toolbar and the zoom group take the width they need first. The status
/// group gets the bottom edge left of the zoom group. The target group sits
/// beside the toolbar when [targetMinWidth] fits there, and under the toolbar
/// across the full width when it does not (a phone), and it is never taller
/// than the space left above the bottom groups.
class FramingCanvasChrome extends StatelessWidget {
  const FramingCanvasChrome({
    super.key,
    required this.toolbar,
    required this.zoom,
    required this.status,
    this.target,
  });

  final Widget toolbar;
  final Widget zoom;
  final Widget status;
  final Widget? target;

  /// Distance from the canvas edge on a desktop canvas.
  static const double inset = SkotiqTokens.spaceLg;

  /// Distance from the canvas edge below [compactBelowWidth].
  static const double compactInset = SkotiqTokens.spaceMd;

  /// Canvases narrower than this use [compactInset].
  static const double compactBelowWidth = SkotiqTokens.breakpointMobile;

  /// Gap between two groups that share an edge.
  static const double gap = SkotiqTokens.spaceSm;

  /// The narrowest the target group may be beside the toolbar: one line of
  /// coordinates at the caption size.
  static const double targetMinWidth = 220;

  /// The widest the target group grows on a large canvas.
  static const double targetMaxWidth = 320;

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(
      delegate: _FramingChromeLayout(),
      children: [
        LayoutId(id: FramingChromeSlot.toolbar, child: toolbar),
        LayoutId(id: FramingChromeSlot.zoom, child: zoom),
        LayoutId(id: FramingChromeSlot.status, child: status),
        if (target case final target?)
          LayoutId(id: FramingChromeSlot.target, child: target),
      ],
    );
  }
}

class _FramingChromeLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final inset = size.width < FramingCanvasChrome.compactBelowWidth
        ? FramingCanvasChrome.compactInset
        : FramingCanvasChrome.inset;
    const gap = FramingCanvasChrome.gap;
    final innerWidth = math.max(0.0, size.width - 2 * inset);
    final innerHeight = math.max(0.0, size.height - 2 * inset);

    final toolbar = layoutChild(
      FramingChromeSlot.toolbar,
      BoxConstraints(maxWidth: innerWidth, maxHeight: innerHeight),
    );
    positionChild(
      FramingChromeSlot.toolbar,
      Offset(size.width - inset - toolbar.width, inset),
    );

    final zoom = layoutChild(
      FramingChromeSlot.zoom,
      BoxConstraints(
        maxWidth: innerWidth,
        maxHeight: math.max(0.0, innerHeight - toolbar.height - gap),
      ),
    );
    positionChild(
      FramingChromeSlot.zoom,
      Offset(
        size.width - inset - zoom.width,
        size.height - inset - zoom.height,
      ),
    );

    final status = layoutChild(
      FramingChromeSlot.status,
      BoxConstraints(
        maxWidth: math.max(0.0, innerWidth - zoom.width - gap),
        maxHeight: innerHeight,
      ),
    );
    positionChild(
      FramingChromeSlot.status,
      Offset(inset, size.height - inset - status.height),
    );

    if (!hasChild(FramingChromeSlot.target)) return;

    final besideWidth = innerWidth - toolbar.width - gap;
    final beside = besideWidth >= FramingCanvasChrome.targetMinWidth;
    final top = beside ? inset : inset + toolbar.height + gap;
    final bottomGroupTop =
        size.height - inset - math.max(status.height, zoom.height);
    final maxHeight = math.max(0.0, bottomGroupTop - gap - top);
    layoutChild(
      FramingChromeSlot.target,
      BoxConstraints(
        maxWidth: beside
            ? math.min(besideWidth, FramingCanvasChrome.targetMaxWidth)
            : innerWidth,
        maxHeight: maxHeight,
      ),
    );
    positionChild(FramingChromeSlot.target, Offset(inset, top));
  }

  @override
  bool shouldRelayout(covariant _FramingChromeLayout oldDelegate) => false;
}
