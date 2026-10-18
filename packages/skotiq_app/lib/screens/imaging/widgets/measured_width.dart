import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Reports its child's laid-out width, after the frame.
///
/// Same contract as `MeasuredBottomInsetReporter`: measuring during layout
/// walks ancestors that are still mid-pass, so both the measurement and the
/// report are deferred.
class MeasuredWidth extends SingleChildRenderObjectWidget {
  const MeasuredWidth({
    super.key,
    required this.onWidth,
    required Widget child,
  }) : super(child: child);

  final ValueChanged<double> onWidth;

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderWidthReporter(onWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _RenderWidthReporter).onWidth = onWidth;
  }
}

class _RenderWidthReporter extends RenderProxyBox {
  _RenderWidthReporter(this.onWidth);

  ValueChanged<double> onWidth;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!attached || !hasSize) return;
      final width = size.width;
      if (_reported == width) return;
      _reported = width;
      onWidth(width);
    });
  }
}
