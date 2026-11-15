import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Answers intrinsic-dimension queries so they never reach the
/// [LayoutBuilder] beneath it, which cannot answer them — measuring a
/// LayoutBuilder speculatively would run its build callback against the live
/// tree, so the framework throws instead. [AlertDialog] measures its content
/// with `IntrinsicWidth`, which makes every banner with an action inside a
/// dialog crash at layout.
///
/// Zero is the honest answer for a wrapping banner's WIDTH: the alert conforms
/// to whatever width its parent chooses and wraps its text there, so it has no
/// preferred width of its own to report, and letting it drive an
/// `IntrinsicWidth` parent wider would size a dialog to the alert's longest
/// unwrapped line. Inside a measuring parent the alert therefore defers to
/// its siblings for sizing; everywhere else these overrides are never called
/// and layout is untouched.
///
/// The HEIGHT overrides are a different case, and a shortcoming: zero there is
/// not honest, it is simply all this shield can answer, because the
/// LayoutBuilder beneath it cannot be measured speculatively at any width. An
/// alert wrapped in this — one WITH an action, the only kind that reads its own
/// width — therefore still collapses to nothing inside an `IntrinsicHeight`.
/// That is why a banner only reaches for this shield when it has an
/// action: a plain banner is laid out directly, is an ordinary `Row`, and
/// measures its own height like any other widget. No screen in this repo places
/// an alert WITH an action inside an `IntrinsicHeight`; making that case
/// measurable means replacing the LayoutBuilder with a render object that lays
/// out both arrangements, which is a larger change than this shield.
class IntrinsicSafeLayout extends SingleChildRenderObjectWidget {
  const IntrinsicSafeLayout({super.key, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderIntrinsicSafeLayout();
}

class RenderIntrinsicSafeLayout extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;
}
