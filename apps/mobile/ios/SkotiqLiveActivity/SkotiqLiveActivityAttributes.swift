// SkotiqLiveActivityAttributes.swift
//
// iOS Live Activities for unattended sequence progress.
//
// `ActivityAttributes` defines the static metadata (`sequenceId`,
// `targetName`, `totalFrames`) that is fixed for the duration of a single
// activity, together with the dynamic `ContentState` that the host app
// pushes via `Activity.update(...)` whenever progress changes.
//
// The host (Flutter) side serialises both halves as JSON over the
// `com.skotiq.live_activity` MethodChannel and the Swift channel
// handler reconstructs the typed values before requesting / updating an
// activity. Field names MUST be kept in sync with
// `apps/mobile/lib/services/live_activity_service.dart` — the JSON keys
// are the source of truth between the two layers.

import ActivityKit
import Foundation

@available(iOS 16.2, *)
public struct SkotiqLiveActivityAttributes: ActivityAttributes {

    // MARK: - Dynamic content state

    /// Updated by the host every time something material about the
    /// sequence changes — frame completion, filter swap, node transition,
    /// guiding RMS update, recovery start, etc. The host is responsible
    /// for throttling updates so we stay within Apple's frequent-update
    /// budget (see LiveActivityService._minUpdateInterval).
    public struct ContentState: Codable, Hashable {
        /// Number of frames the sequence has captured (and accepted) so
        /// far. Reported by `SequencerEvent.FrameAccepted`.
        public var framesCompleted: Int

        /// Sequence-wide total frame count from the plan. May change if
        /// the user edits the sequence mid-run; the host emits an update
        /// in that case.
        public var framesTotal: Int

        /// Wall-clock seconds since the host issued `start(...)`. This is
        /// host-clock time, not the rig's elapsed exposure time, so
        /// pausing the sequence does not freeze it.
        public var elapsedSeconds: Int

        /// Best-effort remaining seconds. `nil` when the scheduler can't
        /// compute one (e.g., open-ended trigger trees). The widget hides
        /// the ETA row in that case rather than show a placeholder.
        public var estimatedRemainingSeconds: Int?

        /// Active filter name ("Ha", "OIII", "L", ...). Empty when the
        /// rig has no filter wheel or the current node doesn't use one.
        public var currentFilter: String

        /// Latest HFR measurement from the most recent accepted frame.
        /// `nil` when no frame has been graded yet for this run.
        public var currentHfr: Double?

        /// Human-readable description of the current sequence node, e.g.
        /// "Exposing 300s Ha", "Autofocus on HFR drift", "Centering on
        /// NGC 7000". Used in the expanded layouts.
        public var currentNodeName: String

        /// Coarse state machine for the rig — drives both the icon
        /// selection and the minimal Dynamic Island 2-character status
        /// code. Allowed values: "exposing", "guiding", "focusing",
        /// "centering", "recovering", "idle", "paused", "stopping",
        /// "completed", "failed".
        public var jobState: String

        public init(
            framesCompleted: Int,
            framesTotal: Int,
            elapsedSeconds: Int,
            estimatedRemainingSeconds: Int?,
            currentFilter: String,
            currentHfr: Double?,
            currentNodeName: String,
            jobState: String
        ) {
            self.framesCompleted = framesCompleted
            self.framesTotal = framesTotal
            self.elapsedSeconds = elapsedSeconds
            self.estimatedRemainingSeconds = estimatedRemainingSeconds
            self.currentFilter = currentFilter
            self.currentHfr = currentHfr
            self.currentNodeName = currentNodeName
            self.jobState = jobState
        }
    }

    // MARK: - Static attributes

    /// Backend sequence identifier. The host uses this on cold-start to
    /// reconcile a recovered activity with the running sequence; an
    /// orphaned activity (no matching live sequence) is ended on launch.
    public var sequenceId: String

    /// Display name for the imaging target. Stays constant for the
    /// activity's lifetime — a mosaic that switches sub-targets ends the
    /// current activity and starts a fresh one for the new target so the
    /// lock-screen name is never stale.
    public var targetName: String

    public init(sequenceId: String, targetName: String) {
        self.sequenceId = sequenceId
        self.targetName = targetName
    }
}
