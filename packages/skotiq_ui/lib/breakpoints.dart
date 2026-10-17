/// Responsive breakpoints and helpers.
///
/// Canonical values live in [BreakpointTokens]; layout classification for
/// screen content uses [Responsive] (768px tablet boundary aligns with shell
/// chrome in [ShellChrome] on desktop targets).
///
/// For fractional panel widths and viewport-capped dialogs, see
/// [panelWidthFromFraction] and [dialogMaxWidth] in `adaptive_layout.dart`.
library;

export 'src/tokens/breakpoint_tokens.dart';
export 'src/utils/responsive_utils.dart';
