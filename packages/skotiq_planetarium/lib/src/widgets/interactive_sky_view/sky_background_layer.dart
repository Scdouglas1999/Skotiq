part of '../interactive_sky_view.dart';

/// A caller-supplied layer composited *beneath* the star field.
///
/// The planetarium package is a leaf: it knows how to draw a star chart and
/// nothing about survey imagery, tile pyramids or the network. But at the
/// narrow fields an astrophotographer actually frames at, a star chart is
/// mostly empty sky — the HYG catalogue carries about three stars per square
/// degree, so a 1.5 degree field around M42 contains roughly a dozen of them.
/// Real imagery behind the chart fills it, and the imagery stack lives above
/// this package (it needs HTTP, HEALPix and a tile cache).
///
/// So [InteractiveSkyView] exposes this *slot* instead of taking a dependency
/// it must not have: the host hands in a widget to paint underneath the stars,
/// and the sky view is responsible only for putting it in the right place in
/// the layer stack and for getting out of its way.
///
/// ## Getting out of its way
///
/// `SkyCanvasPainter` normally opens every base-layer paint by filling the
/// canvas with an opaque twilight gradient, which would bury [child]
/// completely. Setting [occludesSkyGradient] suppresses that fill (see
/// [SkyCanvasPainterBackgroundControl.suppressOpaqueBackground]) so [child]
/// becomes the background the stars are drawn over.
///
/// That makes [occludesSkyGradient] a promise, and the host owns it: while it
/// is true, [child] MUST be covering the canvas. Set it true only when the
/// layer really has something opaque to show — not merely because it is
/// mounted and hoping to load something — or the sky view will show through to
/// whatever is behind it. When it is false the sky view paints its usual
/// gradient and [child] is simply hidden behind it, which is the correct
/// never-blank fallback while imagery is loading, unavailable or offline.
@immutable
class SkyBackgroundLayer {
  /// The widget painted at the very bottom of the sky view's layer stack,
  /// beneath the star field and every overlay.
  ///
  /// It is sized to the sky view (the stack is `StackFit.expand`) and receives
  /// no gestures: the sky view's own pan/zoom/tap handling sits above it.
  final Widget child;

  /// Whether [child] is currently covering the canvas with opaque content.
  ///
  /// True suppresses the sky painter's opaque background gradient so [child]
  /// is visible. False keeps the gradient, hiding [child] — the safe default
  /// while the layer has nothing to show.
  final bool occludesSkyGradient;

  /// Creates a background slot value.
  const SkyBackgroundLayer({
    required this.child,
    this.occludesSkyGradient = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkyBackgroundLayer &&
          runtimeType == other.runtimeType &&
          child == other.child &&
          occludesSkyGradient == other.occludesSkyGradient;

  @override
  int get hashCode => Object.hash(child, occludesSkyGradient);
}
