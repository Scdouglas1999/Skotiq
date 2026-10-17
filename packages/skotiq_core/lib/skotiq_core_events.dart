/// Skotiq Core - typed sequencer/run event seam.
///
/// This is the single Dart seam for the **typed** (flutter_rust_bridge)
/// sequencer/run event surface: the `SkotiqEvent` union with its
/// `EventPayload_*` variants, the per-family event variants (Imaging / Safety /
/// Sequencer / System / Equipment / Guiding / PolarAlignment), the photometry
/// Science variants, [SchedulerScoreEntry], [isCriticalEvent], and the display
/// helpers. App and headless UI import these types from here (or from the
/// aggregate `skotiq_core.dart` barrel) instead of reaching across to
/// `package:skotiq_bridge`.
///
/// Why a dedicated library in addition to the aggregate barrel: the typed
/// bridge `SkotiqEvent` / `EventCategory` / `EventSeverity` share their
/// names with the wire/JSON event model (`src/models/backend/event_types.dart`,
/// surfaced through the barrel via `skotiq_backend.dart`). The aggregate
/// barrel keeps the wire trio canonical (the headless API server and network
/// backend serialize it), so it re-exports this seam with the three colliding
/// names hidden. UI that needs the typed `SkotiqEvent` / `EventCategory` /
/// `EventSeverity` imports THIS library, conventionally with a prefix:
///
/// ```dart
/// import 'package:skotiq_core/skotiq_core_events.dart' as ns_events;
/// ...
/// String title = ns_events.skotiqEventDisplayTitle(event);
/// if (event.payload is ns_events.EventPayload_Sequencer) { ... }
/// ```
///
/// The non-colliding members (every `EventPayload_*` / per-family variant,
/// [SchedulerScoreEntry], [isCriticalEvent], the display helpers) are also
/// reachable unprefixed straight off `package:skotiq_core/skotiq_core.dart`.
library;

export 'src/backend/bridge_events.dart';
