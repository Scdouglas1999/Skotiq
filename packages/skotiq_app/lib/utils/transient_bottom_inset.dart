import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Height, in logical pixels, that transient bottom-anchored overlays
/// (floating snackbars) must clear on the current screen.
///
/// The app theme puts snackbars in [SnackBarBehavior.floating], which anchors
/// them to the bottom of the enclosing [Scaffold]. On a screen whose own
/// primary controls live in a bottom bar — the Imaging screen's Snapshot / Loop
/// / Duration strip — that puts an opaque bar over the two most important
/// buttons on the screen, unreadable and partly un-tappable, for as long as the
/// snackbar is up.
///
/// A screen that owns a bottom bar wraps its content in [TransientBottomInset]
/// declaring how far the snackbar must be lifted (see
/// [MeasuredBottomInsetReporter] for measuring it), and the snackbar helpers in
/// `snackbar_helper.dart` add it to the snackbar's margin. Screens that declare
/// nothing keep the default position.
///
/// ## Why the value is read from a notifier and not just from the tree
///
/// A pure [InheritedWidget] cannot serve every raiser.
/// `dependOnInheritedWidgetOfExactType` only searches ANCESTORS, and
/// `_ImagingScreenActions` is an extension on `_ImagingScreenState`, so the
/// `context` it raises "Capture failed: …" from is the ImagingScreen element —
/// an ancestor of the `TransientBottomInset` that screen's own `build()`
/// creates beneath it. The lookup returns null and the inset is silently not
/// applied.
///
/// Inheriting downward is still the right model for descendants, so the widget
/// stays and keeps working that way. It additionally publishes to
/// [currentInset], which any context can read regardless of direction, and that
/// notifier is the authority the snackbar helper uses.
class TransientBottomInset extends InheritedWidget {
  final double inset;

  const TransientBottomInset({
    super.key,
    required this.inset,
    required super.child,
  });

  /// The inset currently declared by the visible screen, readable from ANY
  /// context — including one above the declaring widget.
  ///
  /// Kept as a plain notifier rather than a provider so `snackbar_helper.dart`
  /// (a `BuildContext` extension with no `Ref`) can read it without every call
  /// site acquiring one, and so it still works in a widget test that pumps no
  /// `ProviderScope`.
  static final ValueNotifier<double> currentInset = ValueNotifier<double>(0);

  /// The inset for `context`: the nearest enclosing declaration if there is one,
  /// otherwise whatever the visible screen has published.
  ///
  /// Prefers the tree so a nested declaration still wins for its own subtree.
  static double of(BuildContext context) {
    final widget =
        context.dependOnInheritedWidgetOfExactType<TransientBottomInset>();
    if (widget != null) return widget.inset;
    return currentInset.value;
  }

  @override
  bool updateShouldNotify(TransientBottomInset oldWidget) =>
      oldWidget.inset != inset;
}

/// Publishes [TransientBottomInset.currentInset] for as long as it is mounted,
/// and resets it on dispose so a screen without a bottom bar does not inherit
/// the previous screen's lift.
///
/// Separate from [TransientBottomInset] because an [InheritedWidget] has no
/// lifecycle of its own to hang the reset on.
class TransientBottomInsetPublisher extends StatefulWidget {
  final double inset;
  final Widget child;

  const TransientBottomInsetPublisher({
    super.key,
    required this.inset,
    required this.child,
  });

  @override
  State<TransientBottomInsetPublisher> createState() =>
      _TransientBottomInsetPublisherState();
}

class _TransientBottomInsetPublisherState
    extends State<TransientBottomInsetPublisher> {
  @override
  void initState() {
    super.initState();
    TransientBottomInset.currentInset.value = widget.inset;
  }

  @override
  void didUpdateWidget(TransientBottomInsetPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inset != widget.inset) {
      TransientBottomInset.currentInset.value = widget.inset;
    }
  }

  @override
  void dispose() {
    TransientBottomInset.currentInset.value = 0;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TransientBottomInset(
        inset: widget.inset,
        child: widget.child,
      );
}

/// Reports, after every layout, how far a floating snackbar must be lifted to
/// clear its child completely.
///
/// That distance is **from the child's top edge to the bottom of the window** —
/// NOT the child's own height. A floating snackbar anchors to the enclosing
/// [Scaffold]'s bottom, and on desktop the shell pins a 36 dp `StatusBar` BELOW
/// the routed screen inside that same Scaffold. Reporting only the bar's height
/// therefore under-lifted the toast by exactly whatever sits beneath the bar:
/// with a 47 dp bar the toast still covered the top ~26 px of a 46 px button.
/// Measuring to the window edge absorbs anything below the bar without having to
/// know what it is.
///
/// Measured rather than hardcoded because the bar's height genuinely moves — it
/// wraps to a second run on narrow widths and grows by the device's bottom
/// safe-area inset.
class MeasuredBottomInsetReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onHeight;

  const MeasuredBottomInsetReporter({
    super.key,
    required this.onHeight,
    required Widget child,
  }) : super(child: child);

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      _RenderHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderProxyBox renderObject,
  ) {
    (renderObject as _RenderHeightReporter).onHeight = onHeight;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    // EVERYTHING is deferred to the post-frame callback, including the
    // measurement itself.
    //
    // `localToGlobal` walks ancestors and asserts each has been laid out, so
    // calling it here — while those ancestors are still mid-layout — threw
    // "RenderBox was not laid out ... hasSize" and took the whole imaging screen
    // down with it. Reporting from here would also mutate the tree mid-pass.
    // After the frame, both the geometry and the tree are settled.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndReport());
  }

  /// Distance from this box's TOP edge to the bottom of the window, so the lift
  /// clears both this bar and anything the shell pins below it.
  void _measureAndReport() {
    if (!attached || !hasSize) return;
    final windowHeight = _windowHeight();
    // No view to measure against (a bare render test): the child's own height is
    // the honest best answer.
    final lift = windowHeight == null
        ? size.height
        : windowHeight - localToGlobal(Offset.zero).dy;
    final reported = lift.isFinite && lift > 0 ? lift : size.height;
    if (_reported == reported) return;
    _reported = reported;
    onHeight(reported);
  }

  /// Logical height of the view this box is painted into, or null when it cannot
  /// be determined.
  double? _windowHeight() {
    if (!attached) return null;
    final view = owner?.rootNode;
    if (view is RenderView) {
      final ratio = view.flutterView.devicePixelRatio;
      if (ratio > 0) return view.flutterView.physicalSize.height / ratio;
    }
    return null;
  }
}
