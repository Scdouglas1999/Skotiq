// SkotiqLiveActivityWidget.swift
//
// Widget definition for the Skotiq sequence Live Activity.
//
// Three layouts are provided per Apple's `ActivityConfiguration`:
//
//   * Lock-screen + banner — full presentation pinned to the lock
//     screen and shown as a banner when the device is unlocked.
//   * Dynamic Island compact / minimal — what the user sees when no
//     activity is currently focused.
//   * Dynamic Island expanded — what the user sees after long-pressing
//     the leading/trailing icons.
//
// All layouts read from `context.attributes` (static — `sequenceId`,
// `targetName`) and `context.state` (dynamic content state pushed by
// the host).

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Brand palette

/// Mirrors `packages/skotiq_ui/lib/src/colors.dart` for the dark
/// theme. SwiftUI cannot reach into the Dart design tokens at compile
/// time, so the values are duplicated here. Keep them in sync if the
/// brand palette shifts.
private enum SkotiqBrand {
    static let background = Color(red: 0.04, green: 0.06, blue: 0.11)   // #0A0F1C
    static let surface    = Color(red: 0.07, green: 0.10, blue: 0.17)   // #11192C
    static let primary    = Color(red: 0.49, green: 0.45, blue: 0.96)   // #7C73F5
    static let accent     = Color(red: 0.97, green: 0.62, blue: 0.31)   // #F89E50
    static let textPrim   = Color(red: 0.92, green: 0.94, blue: 0.97)   // #EBEFF7
    static let textSecn   = Color(red: 0.62, green: 0.66, blue: 0.76)   // #9DA8C2
    static let success    = Color(red: 0.43, green: 0.81, blue: 0.55)   // #6ECF8C
    static let warning    = Color(red: 0.97, green: 0.78, blue: 0.31)   // #F8C850
    static let danger     = Color(red: 0.94, green: 0.40, blue: 0.40)   // #F06666
}

// MARK: - Helpers

@available(iOS 16.2, *)
private extension SkotiqLiveActivityAttributes.ContentState {

    /// 2-character status code shown in the Dynamic Island minimal
    /// presentation. Operator-facing shorthand, intentionally short so
    /// it fits in the ~12-point bubble next to the time.
    var minimalStatusCode: String {
        switch jobState.lowercased() {
        case "exposing":   return "EX"
        case "guiding":    return "GD"
        case "focusing":   return "AF"
        case "centering":  return "CT"
        case "recovering": return "RV"
        case "paused":     return "PA"
        case "stopping":   return "ST"
        case "completed":  return "OK"
        case "failed":     return "ER"
        case "idle":       return "ID"
        default:           return "--"
        }
    }

    /// SF Symbol that best represents the current job state. Used in the
    /// compact-leading slot and the lock-screen header.
    var stateSymbolName: String {
        switch jobState.lowercased() {
        case "exposing":   return "camera.aperture"
        case "guiding":    return "scope"
        case "focusing":   return "circle.hexagongrid"
        case "centering":  return "scope"
        case "recovering": return "arrow.clockwise.circle"
        case "paused":     return "pause.circle"
        case "stopping":   return "stop.circle"
        case "completed":  return "checkmark.seal"
        case "failed":     return "exclamationmark.triangle.fill"
        default:           return "circle"
        }
    }

    /// Tint colour for the symbol/progress bar. Recovery and failure get
    /// warning/error colours so the operator's eye is drawn immediately.
    var stateTint: Color {
        switch jobState.lowercased() {
        case "recovering": return SkotiqBrand.warning
        case "failed":     return SkotiqBrand.danger
        case "completed":  return SkotiqBrand.success
        default:           return SkotiqBrand.primary
        }
    }

    /// Fractional progress 0..1 for use in progress views. Clamps to the
    /// inclusive [0, 1] range so a malformed (framesTotal == 0) payload
    /// renders as an empty bar rather than NaN.
    var progressFraction: Double {
        guard framesTotal > 0 else { return 0 }
        let raw = Double(framesCompleted) / Double(framesTotal)
        return min(max(raw, 0), 1)
    }

    /// Percentage string for compact displays — "10%". Returns "--" when
    /// the total is unknown so we never show "Infinity%" on a malformed
    /// payload.
    var percentString: String {
        guard framesTotal > 0 else { return "--" }
        let pct = Int((progressFraction * 100).rounded())
        return "\(pct)%"
    }

    /// "12/120" frame counter.
    var frameCounterString: String {
        return "\(framesCompleted)/\(framesTotal)"
    }

    /// Formatted ETA string ("1h 23m", "47m", "12s"). Returns nil when
    /// the host did not provide an estimate so callers can hide the row.
    var formattedEta: String? {
        guard let secs = estimatedRemainingSeconds, secs > 0 else { return nil }
        return Self.formatDuration(seconds: secs)
    }

    var formattedElapsed: String {
        return Self.formatDuration(seconds: elapsedSeconds)
    }

    private static func formatDuration(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let mins = seconds / 60
        if mins < 60 {
            return "\(mins)m"
        }
        let hours = mins / 60
        let remainingMins = mins % 60
        return "\(hours)h \(remainingMins)m"
    }
}

// MARK: - Lock-screen + banner layout

@available(iOS 16.2, *)
private struct LockScreenView: View {
    let context: ActivityViewContext<SkotiqLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: brand icon + target name + status pill.
            HStack(spacing: 8) {
                Image(systemName: context.state.stateSymbolName)
                    .foregroundColor(context.state.stateTint)
                    .imageScale(.large)
                Text(context.attributes.targetName)
                    .font(.headline)
                    .foregroundColor(SkotiqBrand.textPrim)
                    .lineLimit(1)
                Spacer()
                Text(context.state.jobState.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundColor(SkotiqBrand.background)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(context.state.stateTint)
                    )
            }

            // Progress bar + frame counter.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: context.state.progressFraction)
                    .progressViewStyle(.linear)
                    .tint(context.state.stateTint)
                HStack {
                    Text("\(context.state.frameCounterString) frames")
                        .font(.caption)
                        .foregroundColor(SkotiqBrand.textSecn)
                    Spacer()
                    Text(context.state.percentString)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(SkotiqBrand.textPrim)
                }
            }

            // Detail row: filter, HFR, ETA.
            HStack(spacing: 16) {
                if !context.state.currentFilter.isEmpty {
                    DetailCell(
                        symbol: "camera.filters",
                        label: "Filter",
                        value: context.state.currentFilter
                    )
                }
                if let hfr = context.state.currentHfr {
                    DetailCell(
                        symbol: "circle.dotted",
                        label: "HFR",
                        value: String(format: "%.2f", hfr)
                    )
                }
                if let eta = context.state.formattedEta {
                    DetailCell(
                        symbol: "clock",
                        label: "ETA",
                        value: eta
                    )
                } else {
                    DetailCell(
                        symbol: "clock",
                        label: "Elapsed",
                        value: context.state.formattedElapsed
                    )
                }
            }

            // Current node line — wraps to two lines so longer
            // descriptions ("Centering on NGC 7000 (iteration 2)") are
            // readable.
            if !context.state.currentNodeName.isEmpty {
                Text(context.state.currentNodeName)
                    .font(.caption2)
                    .foregroundColor(SkotiqBrand.textSecn)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(SkotiqBrand.background)
    }
}

@available(iOS 16.2, *)
private struct DetailCell: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundColor(SkotiqBrand.textSecn)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(SkotiqBrand.textSecn)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(SkotiqBrand.textPrim)
            }
        }
    }
}

// MARK: - Dynamic Island

@available(iOS 16.2, *)
private struct ExpandedLeadingView: View {
    let context: ActivityViewContext<SkotiqLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: context.state.stateSymbolName)
                    .foregroundColor(context.state.stateTint)
                Text(context.attributes.targetName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(SkotiqBrand.textPrim)
                    .lineLimit(1)
            }
            if !context.state.currentFilter.isEmpty {
                Text("Filter \(context.state.currentFilter)")
                    .font(.caption2)
                    .foregroundColor(SkotiqBrand.textSecn)
            }
        }
        .padding(.leading, 4)
    }
}

@available(iOS 16.2, *)
private struct ExpandedTrailingView: View {
    let context: ActivityViewContext<SkotiqLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(context.state.frameCounterString)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(SkotiqBrand.textPrim)
            if let hfr = context.state.currentHfr {
                Text(String(format: "HFR %.2f", hfr))
                    .font(.caption2)
                    .foregroundColor(SkotiqBrand.textSecn)
            }
        }
        .padding(.trailing, 4)
    }
}

@available(iOS 16.2, *)
private struct ExpandedBottomView: View {
    let context: ActivityViewContext<SkotiqLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: context.state.progressFraction)
                .progressViewStyle(.linear)
                .tint(context.state.stateTint)
            HStack {
                Text(context.state.currentNodeName)
                    .font(.caption2)
                    .foregroundColor(SkotiqBrand.textSecn)
                    .lineLimit(1)
                Spacer()
                if let eta = context.state.formattedEta {
                    Text("ETA \(eta)")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(SkotiqBrand.textPrim)
                } else {
                    Text(context.state.formattedElapsed)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(SkotiqBrand.textPrim)
                }
            }
        }
    }
}

// MARK: - Widget

@available(iOS 16.2, *)
public struct SkotiqLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: SkotiqLiveActivityAttributes.self) {
            context in
            LockScreenView(context: context)
                .activityBackgroundTint(SkotiqBrand.background)
                .activitySystemActionForegroundColor(SkotiqBrand.textPrim)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(context: context)
                }
            } compactLeading: {
                Image(systemName: context.state.stateSymbolName)
                    .foregroundColor(context.state.stateTint)
            } compactTrailing: {
                Text("\(context.state.frameCounterString) \(context.state.percentString)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(SkotiqBrand.textPrim)
            } minimal: {
                Text(context.state.minimalStatusCode)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(context.state.stateTint)
            }
            .widgetURL(URL(string: "skotiq://sequence/\(context.attributes.sequenceId)"))
            .keylineTint(context.state.stateTint)
        }
    }
}
