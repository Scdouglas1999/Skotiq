/// Recognizes the event that reports one dither a sequencer run performed.
///
/// The native executor sends `ExecutorEvent::DitherPerformed` once per
/// dither that moved the mount and settled, whoever asked for it: a Dither
/// node, a Smart Exposure plan's cadence, a burst's dither-every, or the
/// Dither Interval trigger. The bridge carries it as a sequencer
/// `InstructionProgressStructured` event with its own `detail_kind`
/// (`event_bridge.rs`, `DITHER_PERFORMED_DETAIL_KIND`), so it needs no wire
/// type of its own.
library;

import '../../backend/skotiq_backend.dart';

/// `detail_kind` the bridge gives a performed dither. Must stay equal to
/// `DITHER_PERFORMED_DETAIL_KIND` in the native bridge.
const String ditherPerformedDetailKind = 'DitherPerformed';

/// Whether [event] reports one dither the run performed.
bool isRunDitherEvent(SkotiqEvent event) =>
    event.category == EventCategory.sequencer &&
    event.eventType == 'InstructionProgressStructured' &&
    event.data['detail_kind'] == ditherPerformedDetailKind;
