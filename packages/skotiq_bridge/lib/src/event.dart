/// Compatibility shim: the Rust `event.rs` monolith became the `event/`
/// module tree (C3 splits), and FRB now generates one Dart file per module.
/// Hand-written consumers keep importing `src/event.dart`; the canonical
/// generated types live in `event/*.dart` and are re-exported here so there
/// is exactly ONE `SkotiqEvent` type in the program.
library;

export 'event/bus.dart';
export 'event/depthlock_events.dart';
export 'event/equipment.dart';
export 'event/guiding.dart';
export 'event/imaging.dart';
export 'event/sequencer.dart';
export 'event/system.dart';
