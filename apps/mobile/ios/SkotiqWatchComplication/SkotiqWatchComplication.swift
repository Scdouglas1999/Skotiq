// SkotiqWatchComplication.swift
//
// Apple Watch complication widget for Skotiq.
//
// Three complication families are implemented, matching the watchOS 10+
// WidgetKit families:
//
//   * `accessoryCircular` — small dial. Progress ring around the active
//     filter name. Used in the smart-stack circular slot and on watch
//     faces like Infograph / Modular.
//   * `accessoryRectangular` — three lines: target, frame counter,
//     weather safety. Used in the smart-stack rectangular slot and on
//     watch faces like Modular Large.
//   * `accessoryInline` — single line that lives in the watch face's
//     status bar. "Target · 42% · Clear".
//
// All three render from `SkotiqWatchComplicationEntry` so they stay
// in lockstep — a single snapshot drives every family.
//
// Brand palette is duplicated from the iOS Live Activity widget for the
// same reason as there: SwiftUI cannot reach into the Dart design tokens
// at compile time. Keep `SkotiqWatchBrand` and
// `SkotiqBrand` (in `SkotiqLiveActivityWidget.swift`) in sync if
// the palette shifts.

import SwiftUI
import WidgetKit

// MARK: - Brand palette

private enum SkotiqWatchBrand {
    static let primary = Color(red: 0.49, green: 0.45, blue: 0.96)   // #7C73F5
    static let accent  = Color(red: 0.97, green: 0.62, blue: 0.31)   // #F89E50
    static let success = Color(red: 0.43, green: 0.81, blue: 0.55)   // #6ECF8C
    static let warning = Color(red: 0.97, green: 0.78, blue: 0.31)   // #F8C850
    static let danger  = Color(red: 0.94, green: 0.40, blue: 0.40)   // #F06666
    static let textSecondary = Color(red: 0.62, green: 0.66, blue: 0.76) // #9DA8C2
}

// MARK: - Job-state helpers

private extension SkotiqWatchComplicationEntry {
    /// Tint colour for the progress ring / status text. Recovery and
    /// failure get warning / error colours so the operator's eye is
    /// drawn immediately.
    var stateTint: Color {
        switch jobState.lowercased() {
        case "recovering": return SkotiqWatchBrand.warning
        case "failed":     return SkotiqWatchBrand.danger
        case "completed":  return SkotiqWatchBrand.success
        case "paused", "stopping": return SkotiqWatchBrand.accent
        default:           return SkotiqWatchBrand.primary
        }
    }

    /// Tint colour for the weather badge. Unsafe weather is always
    /// danger-red regardless of the imaging state — the operator needs
    /// to see that even while the rig is mid-exposure.
    var weatherTint: Color {
        return weatherSafe ? SkotiqWatchBrand.success : SkotiqWatchBrand.danger
    }

    /// Short status string for the inline complication, e.g. "Clear" or
    /// "Unsafe". Empty when no weather sample is available.
    var weatherShort: String {
        if weatherLabel.isEmpty {
            return weatherSafe ? "Clear" : "Unsafe"
        }
        return weatherLabel
    }
}

// MARK: - Circular layout

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
private struct CircularComplicationView: View {
    let entry: SkotiqWatchComplicationEntry

    var body: some View {
        ZStack {
            // Background ring at low opacity so the unfilled portion is
            // legible against the watch face. Apple's recommendation for
            // accessory widgets is to lean on the `widgetAccentable()`
            // modifier; we still draw an explicit ring so the design
            // works on the dim "always-on" face state where accents are
            // muted to grayscale.
            Circle()
                .stroke(
                    Color.primary.opacity(0.2),
                    style: StrokeStyle(lineWidth: 4)
                )
            if entry.hasData {
                Circle()
                    .trim(from: 0, to: CGFloat(entry.progressFraction))
                    .stroke(
                        entry.stateTint,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
            VStack(spacing: 0) {
                if entry.hasData {
                    if !entry.currentFilter.isEmpty {
                        Text(entry.currentFilter)
                            .font(.system(size: 12, weight: .semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    } else {
                        Text("\(entry.progressPercent)%")
                            .font(.system(size: 12, weight: .semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "moon.stars")
                        .font(.system(size: 14))
                        .foregroundColor(SkotiqWatchBrand.textSecondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Rectangular layout

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
private struct RectangularComplicationView: View {
    let entry: SkotiqWatchComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.hasData {
                Text(entry.targetName.isEmpty ? "Skotiq" : entry.targetName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .widgetAccentable()
                HStack(spacing: 4) {
                    Text(entry.frameCounter)
                        .font(.system(size: 12, weight: .regular))
                    Text("·")
                        .foregroundColor(SkotiqWatchBrand.textSecondary)
                    Text("\(entry.progressPercent)%")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(entry.stateTint)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(entry.weatherTint)
                        .frame(width: 6, height: 6)
                    Text(entry.weatherShort)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(SkotiqWatchBrand.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Text("Skotiq")
                    .font(.system(size: 13, weight: .semibold))
                    .widgetAccentable()
                Text("No sequence")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(SkotiqWatchBrand.textSecondary)
                Text("Tap to open")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(SkotiqWatchBrand.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Inline layout

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
private struct InlineComplicationView: View {
    let entry: SkotiqWatchComplicationEntry

    var body: some View {
        // accessoryInline renders a single line of plain text. The OS
        // tints it; no colours / fonts apply. Build the densest legible
        // shorthand we can: target · pct · weather.
        Text(inlineText)
    }

    private var inlineText: String {
        if !entry.hasData {
            return "Skotiq: idle"
        }
        let target = entry.targetName.isEmpty ? "Sequence" : entry.targetName
        let pct = entry.framesTotal > 0 ? "\(entry.progressPercent)%" : "--"
        let weather = entry.weatherShort
        return "\(target) · \(pct) · \(weather)"
    }
}

// MARK: - Family router

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
private struct SkotiqWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SkotiqWatchComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            CircularComplicationView(entry: entry)
        case .accessoryRectangular:
            RectangularComplicationView(entry: entry)
        case .accessoryInline:
            InlineComplicationView(entry: entry)
        default:
            // We deliberately do not register additional families in the
            // `supportedFamilies` modifier below, but WidgetKit may still
            // probe the view with an unexpected family during preview.
            // Render the rectangular layout as a sensible fallback rather
            // than EmptyView so previews stay debuggable.
            RectangularComplicationView(entry: entry)
        }
    }
}

// MARK: - Widget

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
public struct SkotiqWatchComplication: Widget {
    public static let kind: String = "SkotiqWatchComplication"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: SkotiqWatchTimelineProvider()
        ) { entry in
            SkotiqWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Skotiq")
        .description("Current target, frame progress, and weather safety.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

// MARK: - WidgetBundle entry point

@available(watchOSApplicationExtension 10.0, iOS 17.0, *)
@main
public struct SkotiqWatchComplicationBundle: WidgetBundle {
    public init() {}
    public var body: some Widget {
        SkotiqWatchComplication()
    }
}
