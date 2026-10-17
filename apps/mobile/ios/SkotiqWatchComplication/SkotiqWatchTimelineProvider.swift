// SkotiqWatchTimelineProvider.swift
//
// WidgetKit TimelineProvider for the Skotiq watch
// complication.
//
// Data path:
//   1. The iOS host app (Flutter side) writes a JSON snapshot to the App
//      Group container (`group.com.skotiq.app`) under the key
//      `watch_complication_snapshot` every time material sequence /
//      weather state changes. See
//      `apps/mobile/lib/services/watch_complication_service.dart`.
//   2. The host then calls `WidgetCenter.shared.reloadAllTimelines()` via
//      the `skotiq/watch_complication` MethodChannel. WidgetKit calls
//      `getTimeline(...)` on this provider.
//   3. We read the snapshot, decode it, and emit a single-entry timeline.
//      The timeline ends with `policy = .after(now + 60s)` so the system
//      still polls us in the background even if the app is suspended and
//      cannot call `reloadAllTimelines()` — without that fallback a
//      sequence that runs unattended for hours would leave a stale face.
//
// Why a single-entry timeline (rather than projecting future entries):
// progress is event-driven by the imaging rig. We have no way to predict
// when the next frame will land — exposure time, dithering, autofocus
// runs, weather pauses all warp it. Emitting projected entries would
// invariably be wrong. The 60s `.after(...)` policy gives WidgetKit a
// floor to come back and check the snapshot ourselves; the host's
// reload trigger is the fast path.

import Foundation
import WidgetKit

/// Suite name for the shared `UserDefaults` between the host app and the
/// watch complication extension. MUST match the App Group entitlement on
/// both targets (see `SETUP.md`).
public let skotiqWatchAppGroupSuite = "group.com.skotiq.app"

/// Key under which the host writes the JSON snapshot. MUST match the
/// Dart side in `watch_complication_service.dart`.
public let skotiqWatchSnapshotKey = "watch_complication_snapshot"

/// JSON payload pushed from the Dart host. Mirrors
/// `WatchComplicationSnapshot` in `watch_complication_service.dart` 1:1.
private struct SnapshotPayload: Decodable {
    let targetName: String
    let framesCompleted: Int
    let framesTotal: Int
    let currentFilter: String
    let jobState: String
    let weatherSafe: Bool
    let weatherLabel: String
}

public struct SkotiqWatchTimelineProvider: TimelineProvider {
    public typealias Entry = SkotiqWatchComplicationEntry

    public init() {}

    /// Synchronous placeholder shown while WidgetKit is loading the real
    /// timeline (e.g., the first time a user adds the complication to a
    /// watch face). We explicitly return the `empty` entry so the view
    /// layer renders its "No sequence" branch — sample-looking data here
    /// would let an operator believe a sequence was running when none is.
    public func placeholder(in context: Context) -> SkotiqWatchComplicationEntry {
        return .empty
    }

    /// Snapshot for the widget gallery preview. We use the real shared
    /// defaults so the gallery preview shows live data when there is some,
    /// otherwise the empty placeholder. This matches Apple's guidance for
    /// widget galleries — show live data when available.
    public func getSnapshot(
        in context: Context,
        completion: @escaping (SkotiqWatchComplicationEntry) -> Void
    ) {
        let entry = readEntry() ?? .empty
        completion(entry)
    }

    /// Build the timeline. Single entry now, refresh in 60s either way so
    /// a host-app suspension does not freeze the face on stale state.
    public func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SkotiqWatchComplicationEntry>) -> Void
    ) {
        let entry = readEntry() ?? .empty
        let nextRefresh = Date().addingTimeInterval(60)
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    // MARK: - Shared defaults read

    /// Read the latest snapshot from the App Group container and decode.
    /// Returns nil when:
    ///   * the App Group is not configured (entitlement missing — surface
    ///     loudly via NSLog so the developer sees it during setup),
    ///   * no snapshot has ever been written,
    ///   * the snapshot fails to decode (host/extension contract drift —
    ///     also surfaced via NSLog).
    private func readEntry() -> SkotiqWatchComplicationEntry? {
        guard let defaults = UserDefaults(suiteName: skotiqWatchAppGroupSuite) else {
            // Loud failure: the App Group entitlement is missing on the
            // extension target. The user must add it in Xcode (see
            // SETUP.md). We log and return nil so the placeholder shows
            // instead of crashing the widget process.
            NSLog(
                "[SkotiqWatchComplication] App Group %@ unavailable — entitlement missing on extension target?",
                skotiqWatchAppGroupSuite
            )
            return nil
        }
        guard let raw = defaults.string(forKey: skotiqWatchSnapshotKey) else {
            return nil
        }
        guard let data = raw.data(using: .utf8) else {
            NSLog(
                "[SkotiqWatchComplication] snapshot string is not valid UTF-8"
            )
            return nil
        }
        do {
            let payload = try JSONDecoder().decode(SnapshotPayload.self, from: data)
            return SkotiqWatchComplicationEntry(
                date: Date(),
                hasData: true,
                targetName: payload.targetName,
                framesCompleted: payload.framesCompleted,
                framesTotal: payload.framesTotal,
                currentFilter: payload.currentFilter,
                jobState: payload.jobState,
                weatherSafe: payload.weatherSafe,
                weatherLabel: payload.weatherLabel
            )
        } catch {
            NSLog(
                "[SkotiqWatchComplication] failed to decode snapshot: %@",
                String(describing: error)
            )
            return nil
        }
    }
}
