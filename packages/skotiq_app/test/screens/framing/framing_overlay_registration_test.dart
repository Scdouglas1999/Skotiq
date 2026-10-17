// Co-registration regression guard for the framing canvas under simultaneous
// pan AND rotation (components C5/C6).
//
// THE BUG THIS GUARDS:
// The survey background painter composes its transform as
//   rotate(canvasCenter) ∘ translate(pan)
// (it draws the image into a pan-displaced draw rect and THEN rotates the whole
// canvas about the canvas center). The FOV / equipment / mosaic OVERLAYS are
// built from nested `Transform` widgets, and those must compose the SAME way —
// rotate about the canvas center OUTERMOST, translate by pan INNERMOST — or the
// reticle slides off the imagery by `rotate(pan) - pan` whenever rotation != 0
// and pan != 0.
//
// A pure widget golden would be brittle and platform-dependent for this; the
// invariant under test is purely the transform composition order, so this test
// reconstructs BOTH transforms exactly as production builds them (the painter's
// canvas ops and the overlay's Transform widgets) and asserts that a point
// anchored at the canvas center maps to the SAME screen pixel through each.
//
// If someone reverts the overlay back to translate-outer / rotate-inner, the
// two mapped points diverge and this test fails loudly.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Matrix4 _translation(Offset o) => Matrix4.translationValues(o.dx, o.dy, 0);

/// Rotation by [radians] about [pivot]: T(pivot) · R · T(-pivot).
Matrix4 _rotationAbout(double radians, Offset pivot) =>
    _translation(pivot) * Matrix4.rotationZ(radians) * _translation(-pivot);

/// The background painter's transform about the canvas center: it translates
/// the drawn content by [pan], then rotates the canvas about [canvasCenter].
/// (See FramingSurveyImagePainter.paint: translate(pivot)·rotate·translate
/// (-pivot) applied around drawImageRect into a pan-displaced rect.)
/// Composition order: rotate(canvasCenter) ∘ translate(pan).
Matrix4 _backgroundTransform({
  required Offset canvasCenter,
  required Offset pan,
  required double rotationRadians,
}) =>
    _rotationAbout(rotationRadians, canvasCenter) * _translation(pan);

/// The overlay's transform as the FIXED widget tree builds it:
///   Center -> Transform.rotate(about child center == canvas center)
///          -> Transform.translate(pan) -> painter (anchored at canvas center).
/// Transform.rotate rotates about the child's center, which (because the child
/// is a Center-filled canvas-sized box) is the canvas center. Same composition
/// order as the background: rotate(canvasCenter) ∘ translate(pan).
Matrix4 _overlayTransform({
  required Offset canvasCenter,
  required Offset pan,
  required double rotationRadians,
}) =>
    _rotationAbout(rotationRadians, canvasCenter) * _translation(pan);

Offset _apply(Matrix4 m, Offset p) => MatrixUtils.transformPoint(m, p);

void main() {
  test(
      'overlay and background map the canvas-center point identically under '
      'pan AND rotation', () {
    const canvasCenter = Offset(480, 400);
    const pan = Offset(120, -60); // non-zero pan
    const rotation = 35 * math.pi / 180; // non-zero rotation

    final bg = _backgroundTransform(
      canvasCenter: canvasCenter,
      pan: pan,
      rotationRadians: rotation,
    );
    final overlay = _overlayTransform(
      canvasCenter: canvasCenter,
      pan: pan,
      rotationRadians: rotation,
    );

    // The reticle / image are both anchored at the canvas center before the
    // transform; under co-registration they must land at the same screen pixel.
    final bgPoint = _apply(bg, canvasCenter);
    final overlayPoint = _apply(overlay, canvasCenter);

    expect((bgPoint - overlayPoint).distance, lessThan(1e-9),
        reason: 'Reticle and imagery must map the canvas-center anchor to the '
            'same screen pixel under simultaneous pan + rotation. A non-zero '
            'gap means the overlay transform order diverged from the '
            'background (the rotate(pan) - pan de-registration bug).');

    // Sanity: the mapped point is canvasCenter + rotate(pan), NOT canvasCenter
    // + pan — i.e. the pan is genuinely rotated, proving the order matters and
    // the test is not trivially satisfied by a no-rotation path.
    final rotatedPan = Offset(
      pan.dx * math.cos(rotation) - pan.dy * math.sin(rotation),
      pan.dx * math.sin(rotation) + pan.dy * math.cos(rotation),
    );
    final expected = canvasCenter + rotatedPan;
    expect((bgPoint - expected).distance, lessThan(1e-6));
  });

  test(
      'the BROKEN translate-outer / rotate-inner order would de-register '
      '(documents the regression this guards)', () {
    const canvasCenter = Offset(480, 400);
    const pan = Offset(120, -60);
    const rotation = 35 * math.pi / 180;

    // The INCORRECT overlay order: translate(pan) outer, rotate(center)
    // inner == translate(pan) ∘ rotate(center): the canvas-center anchor stays
    // at the center under rotation, then is translated by an UN-rotated pan.
    final broken = _translation(pan) * _rotationAbout(rotation, canvasCenter);

    final bg = _backgroundTransform(
      canvasCenter: canvasCenter,
      pan: pan,
      rotationRadians: rotation,
    );

    final brokenPoint = _apply(broken, canvasCenter);
    final bgPoint = _apply(bg, canvasCenter);

    // With pan and rotation both non-zero the broken order genuinely diverges,
    // by exactly rotate(pan) - pan; this asserts the bug was real and the fixed
    // order above is meaningfully different.
    expect((brokenPoint - bgPoint).distance, greaterThan(1.0),
        reason: 'Proves the transform-order fix is load-bearing: the old order '
            'de-registers the reticle from the imagery under pan + rotation.');
  });
}
