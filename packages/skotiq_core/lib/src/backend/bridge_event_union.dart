/// The typed event union and its two classifiers, as flutter_rust_bridge
/// generates them.
///
/// The wire/JSON event model (`src/models/backend/event_types.dart`) has
/// types of the same three names, so a file that needs both imports this
/// library with a prefix.
library;

export 'package:skotiq_bridge/skotiq_bridge.dart'
    show SkotiqEvent, EventCategory, EventSeverity;
