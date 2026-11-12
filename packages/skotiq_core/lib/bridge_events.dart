/// The typed (flutter_rust_bridge) event surface of skotiq_core: the
/// `SkotiqEvent` union, its `EventPayload_*` variants, the per-family events
/// and the display helpers.
///
/// `backend.dart` exports all of it except `SkotiqEvent`, `EventCategory` and
/// `EventSeverity`, which share their names with the wire event model in
/// `models.dart`. A file that needs those three imports this library with a
/// prefix:
///
/// ```dart
/// import 'package:skotiq_core/bridge_events.dart' as sk_events;
/// ```
library;

export 'src/backend/bridge_event_union.dart';
export 'src/backend/bridge_events.dart';
