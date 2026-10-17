import '../../services/live_stacking_service.dart';

/// Models for the **Stack-and-Share Loop** — the workflow that takes a set of
/// captured light frames, optionally calibrates them, live-stacks them into a
/// single integration, stretches the result, and exports a share-ready image
/// (PNG / JPEG / annotated share card) plus AstroBin-style acquisition metadata.
///
/// These are plain immutable value classes (const constructor + [copyWith] +
/// value equality), matching the style of [LiveStackingConfig] /
/// [LiveStackingStats] in `live_stacking_service.dart` — no freezed / codegen.
///
/// Helpers like [StackAndShareProgress.fraction] return a well-defined value
/// for degenerate inputs (e.g. zero total frames) rather than a NaN that would
/// reach a progress bar.

part 'stack_and_share/stack_and_share_config.dart';
part 'stack_and_share/stack_and_share_progress.dart';
part 'stack_and_share/stack_and_share_result.dart';
part 'stack_and_share/share_card_spec.dart';
part 'stack_and_share/astrobin_export_metadata.dart';
