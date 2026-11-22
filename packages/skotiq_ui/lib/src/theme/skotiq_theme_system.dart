/// Barrel export for the Skotiq design-system theme layer.
///
/// **Layer stack** (bottom → top):
/// - [SkotiqColors] — semantic palette (`ThemeExtension`, resolve with `.of`)
/// - [SkotiqTokens] — spacing, radii, motion, shadows
/// - [SkotiqTypography] — type scale
/// - [SkotiqTheme] — `ThemeData` assembly
/// - [SkotiqDecorations] — reusable `BoxDecoration` helpers
/// - Domain `*Colors` classes — chart, annotation, backend protocol hues
library;

export 'package:skotiq_design/skotiq_design.dart';
export 'skotiq_decorations.dart';
export 'skotiq_theme.dart';
export '../tokens/shell_chrome_metrics.dart';

export 'skotiq_slider_style.dart';
