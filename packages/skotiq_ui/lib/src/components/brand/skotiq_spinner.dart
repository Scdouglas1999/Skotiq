import 'package:flutter/widgets.dart';

import 'skotiq_mark.dart';
import 'trails_geometry.dart';

/// Inline indeterminate spinner — the mark's `loading` motion at the `mid`
/// or `flat` level, in one color.
///
/// The swap-in replacement for indeterminate [CircularProgressIndicator]
/// call sites: same size/color/semantics surface, no determinate variant —
/// progress with a known end stays a [SkotiqProgressBar].
class SkotiqSpinner extends StatelessWidget {
  const SkotiqSpinner({
    super.key,
    this.size = 16,
    this.color,
    this.semanticLabel,
  });

  /// Width and height in logical pixels. The default, 16, matches the
  /// inline spinners the reference spec shows inside status rows; 24 and up
  /// renders the three-lane `mid` level.
  final double size;

  /// Lane color. Defaults to the ambient [IconTheme]/[DefaultTextStyle]
  /// color, so a spinner inside a button or a tinted status row inherits
  /// the context's ink.
  final Color? color;

  /// Accessibility label, e.g. `'Loading'`. When null the spinner is
  /// decorative — the same default [CircularProgressIndicator] ships with.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return SkotiqMark(
      size: size,
      motion: SkotiqMarkMotion.loading,
      tone: SkotiqMarkTone.mono,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}
