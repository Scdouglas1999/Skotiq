import 'package:flutter/widgets.dart';

/// The width [text] occupies on one line in [style], in logical pixels.
///
/// Every label in this language is laid out with `maxLines: 1` and
/// `TextOverflow.ellipsis`, which means a control given less room than its
/// words need does not overflow, does not complain and does not grow — it
/// silently renders "St…" and the reader is left to guess what it does. A
/// layout that chooses between columns and a stack therefore has to ask how
/// much room the words need BEFORE it commits, and this is the question.
///
/// The text scale comes off [context], so a layout built on this measurement
/// follows the reader's font size instead of assuming the design one.
double measureTextWidth(
  BuildContext context, {
  required String text,
  required TextStyle style,
}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}
