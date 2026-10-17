// SkotiqWatchComplicationEntry.swift
//
// Apple Watch complication for Skotiq.
//
// `SkotiqWatchComplicationEntry` is the `TimelineEntry` consumed by the
// WidgetKit timeline provider in `SkotiqWatchTimelineProvider.swift`.
// One entry is one point-in-time snapshot of the sequencer + weather state
// that will be rendered into a complication face.
//
// The host iOS app writes a JSON snapshot to the shared App Group container
// (`group.com.skotiq.app`) every time something material changes in the
// running sequence — sequence progress, filter swap, weather safety alert,
// etc. The provider here reads that snapshot and lifts it into a typed
// `Entry` so the SwiftUI views can branch off concrete properties rather
// than parse JSON in the body of a `View`.
//
// JSON keys MUST match the Dart side in
// `apps/mobile/lib/services/watch_complication_service.dart`. Touch them
// only in lockstep.

import Foundation
import WidgetKit

/// Snapshot of one moment of sequence + weather state.
///
/// Every field is a value type so `Entry` is `Equatable` for free, which
/// lets WidgetKit short-circuit re-renders when the snapshot hasn't moved.
public struct SkotiqWatchComplicationEntry: TimelineEntry {

    /// When this entry should be considered current. We do not project
    /// future entries because the data is event-driven from the host
    /// app — we always emit a single entry with `date = Date()` and let
    /// the host call `WidgetCenter.shared.reloadAllTimelines()` to push
    /// a new one when state changes.
    public let date: Date

    /// True when the host has never published a snapshot (fresh install,
    /// no sequence has ever run). The views render an explicit "No
    /// sequence" placeholder so the operator does not mistake stale data
    /// for live data.
    public let hasData: Bool

    // MARK: - Sequence fields

    /// Display name for the currently running target (or whatever the host
    /// surfaced as the most-relevant label — sequence name on cold start
    /// before a target node has fired). Empty when `hasData == false`.
    public let targetName: String

    /// Frames the sequencer has completed and accepted on the current run.
    public let framesCompleted: Int

    /// Total frames planned for the current run. Zero is treated as
    /// "unknown" by the view layer (renders "--" rather than dividing by
    /// zero).
    public let framesTotal: Int

    /// Active filter name ("Ha", "OIII", "L", ...). Empty when the rig
    /// has no filter wheel or no filter node is active.
    public let currentFilter: String

    /// Coarse state machine for the rig. Matches the same vocabulary as
    /// the iOS Live Activity (`exposing`, `guiding`, `focusing`,
    /// `centering`, `recovering`, `idle`, `paused`, `stopping`,
    /// `completed`, `failed`) so the Swift helpers can be shared across
    /// the two widget targets if Apple eventually reunifies them.
    public let jobState: String

    // MARK: - Weather fields

    /// True when the weather-safety subsystem says it is currently safe
    /// to image. Drives the inline / rectangular widget tint.
    public let weatherSafe: Bool

    /// Human-readable shorthand for the alert level — "Clear", "Watch",
    /// "Warning", "Critical". Empty when no weather sample is available.
    public let weatherLabel: String

    public init(
        date: Date,
        hasData: Bool,
        targetName: String,
        framesCompleted: Int,
        framesTotal: Int,
        currentFilter: String,
        jobState: String,
        weatherSafe: Bool,
        weatherLabel: String
    ) {
        self.date = date
        self.hasData = hasData
        self.targetName = targetName
        self.framesCompleted = framesCompleted
        self.framesTotal = framesTotal
        self.currentFilter = currentFilter
        self.jobState = jobState
        self.weatherSafe = weatherSafe
        self.weatherLabel = weatherLabel
    }

    /// Placeholder used by `placeholder(in:)` and as the fallback when the
    /// host has not yet written a snapshot to the App Group container.
    /// Deliberately renders empty strings (not "—" or sample data) so the
    /// view layer can branch on `hasData` and show its own explicit
    /// "No sequence" copy.
    public static let empty = SkotiqWatchComplicationEntry(
        date: Date(),
        hasData: false,
        targetName: "",
        framesCompleted: 0,
        framesTotal: 0,
        currentFilter: "",
        jobState: "idle",
        weatherSafe: true,
        weatherLabel: ""
    )

    /// Fractional progress 0..1 for use in ring / progress views. Clamped
    /// so a malformed (framesTotal == 0) payload renders as 0 rather
    /// than NaN.
    public var progressFraction: Double {
        guard framesTotal > 0 else { return 0 }
        let raw = Double(framesCompleted) / Double(framesTotal)
        return min(max(raw, 0), 1)
    }

    /// Integer percentage for compact displays — `42`. Returns 0 when
    /// total is unknown so the caller can guard with `hasData`.
    public var progressPercent: Int {
        return Int((progressFraction * 100).rounded())
    }

    /// "12/120" frame counter. Used in the rectangular layout.
    public var frameCounter: String {
        return "\(framesCompleted)/\(framesTotal)"
    }
}
