import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Gives a field's well the width a field is supposed to have: the whole slot
/// when the parent bounds it, its own content when the parent does not.
///
/// A field handed a width fills it, so the value reads from the leading edge
/// and the unit or chevron sits at the trailing one; a field in a
/// content-sized `Row` — how a settings row hosts one — gets an UNBOUNDED
/// main-axis constraint, and filling is not a thing a box can do there.
///
/// The obvious spelling of that rule is a [LayoutBuilder] that picks
/// `MainAxisSize.max` + `FlexFit.tight` when `constraints.hasBoundedWidth`.
/// It is also wrong: a `LayoutBuilder` refuses every intrinsic query, so a
/// single field anywhere inside an [AlertDialog] — which measures its content
/// through [IntrinsicWidth] — threw "LayoutBuilder does not support returning
/// intrinsic dimensions" and took the whole dialog down.
///
/// Doing it in the render object instead keeps one widget tree, so intrinsics
/// pass straight through to the child: the box resolves the width itself and
/// hands the child a TIGHT one, which is what makes the child's
/// `MainAxisSize.max` and its tight [Flexible] behave the same in both cases.
class FieldWidthBox extends SingleChildRenderObjectWidget {
  const FieldWidthBox({super.key, required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFieldWidth();
}

class _RenderFieldWidth extends RenderProxyBox {
  /// The width to hand the child: the slot when it is bounded, else the
  /// child's own shrink-wrapped width.
  double _resolveWidth(BoxConstraints constraints, RenderBox child) {
    if (constraints.hasBoundedWidth) return constraints.maxWidth;
    return constraints.constrainWidth(
      child.getMaxIntrinsicWidth(constraints.maxHeight),
    );
  }

  @override
  void performLayout() {
    final RenderBox? child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      constraints.tighten(width: _resolveWidth(constraints, child)),
      parentUsesSize: true,
    );
    size = child.size;
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? child = this.child;
    if (child == null) return constraints.smallest;
    return child.getDryLayout(
      constraints.tighten(width: _resolveWidth(constraints, child)),
    );
  }

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final RenderBox? child = this.child;
    if (child == null) return null;
    return child.getDryBaseline(
      constraints.tighten(width: _resolveWidth(constraints, child)),
      baseline,
    );
  }
}
