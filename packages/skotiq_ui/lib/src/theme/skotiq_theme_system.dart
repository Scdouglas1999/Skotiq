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

export 'annotation_type_colors.dart';
export 'backend_protocol_colors.dart';
export 'skotiq_chart_colors.dart';
export 'skotiq_colors.dart';
export 'skotiq_decorations.dart';
export 'skotiq_theme.dart';
export 'skotiq_tokens.dart';
export 'skotiq_typography.dart';
export '../tokens/shell_chrome_metrics.dart';

export 'skotiq_data_colors.dart';
export 'filter_colors.dart';
export 'skotiq_slider_style.dart';
