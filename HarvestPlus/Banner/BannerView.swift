//
//  BannerView.swift
//  HarvestPlus
//
//  Created by Razvan Politic on 14/04/2026.
//
//  The banner's SwiftUI content and its modes (nudge / idle / long-timer /
//  end-of-day / end-of-week summary), plus the `BannerActions` callbacks
//  each mode wires up.
//

import SwiftUI

// MARK: - Banner Mode

enum BannerMode {
    case nudge                          // No timer running during work hours
    case idle(taskName: String)         // Timer running but user idle
    case longTimer(taskName: String, hours: Double)  // Timer running too long
    case eodSummary(DaySummary)         // End-of-day summary
    case eowSummary(WeekSummary)        // End-of-week summary
}

// MARK: - Banner Actions

struct BannerActions {
    var onSnooze: () -> Void = {}
    var onSkipForToday: () -> Void = {}
    var onClose: () -> Void = {}
    var onStopTimer: () -> Void = {}
    var onStopAndSubtractIdle: () -> Void = {}
    var onKeepGoing: () -> Void = {}
    var onOpenHarvest: () -> Void = {}
}

// MARK: - Banner View
//
// Layout contract:
//   ┌────────────────────────────┐
//   │  Mode-specific body        │  ← header + actions
//   │                            │
//   ├────────────────────────────┤
//   │  Snooze 15m   Skip today   │  ← always-present footer
//   └────────────────────────────┘
//
// The footer holds the persistent "get this banner out of my face" controls;
// the body holds whatever is specific to the reason we're showing it.

struct BannerView: View {
    let mode: BannerMode
    let actions: BannerActions
    let snoozeDurationMinutes: Int

    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .padding(.horizontal, AppSpacing.xl)
                .padding(.top, isCompactNudge ? 22 : AppSpacing.lg)
                .padding(.bottom, AppSpacing.lg)
                .frame(maxWidth: .infinity, alignment: isCompactNudge ? .center : .leading)

            Divider()
                .padding(.horizontal, 14)

            footer
                .padding(.horizontal, AppSpacing.lg)
                .padding(.vertical, AppSpacing.sm + 2)
        }
        .harvestSurface(cornerRadius: AppRadius.lg, prominence: .prominent)
        .harvestFloatingShadow()
    }

    /// The nudge is the only mode not reacting to a live event – it earns
    /// a calmer, centered, near-square layout.
    private var isCompactNudge: Bool {
        if case .nudge = mode { return true }
        return false
    }

    // MARK: - Mode Dispatch

    @ViewBuilder
    private var mainContent: some View {
        switch mode {
        case .nudge:
            nudgeContent
        case .idle(let taskName):
            idleContent(taskName: taskName)
        case .longTimer(let taskName, let hours):
            longTimerContent(taskName: taskName, hours: hours)
        case .eodSummary(let day):
            summaryContent(
                title: "End of Day",
                subtitle: "Here's your day at a glance.",
                logged: day.actual,
                delta: day.delta
            )
        case .eowSummary(let week):
            summaryContent(
                title: "End of Week",
                subtitle: "Here's your week at a glance.",
                logged: week.actualTotal,
                delta: week.delta
            )
        }
    }

    // MARK: - Nudge (compact, vertical, centered)

    private var nudgeContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "timer")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(AppColor.harvestOrange)

            VStack(spacing: 4) {
                Text("What are you working on?")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                Text("Start a timer in Harvest to track it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button { actions.onOpenHarvest() } label: {
                Label("Open Harvest", systemImage: "arrow.up.forward.app.fill")
            }
            .buttonStyle(BannerPrimaryButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Idle

    private func idleContent(taskName: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            bannerHeader(
                icon: "hand.raised.fill",
                title: "Still working on \(taskName)?",
                subtitle: "No activity detected."
            )

            HStack(spacing: 8) {
                Button { actions.onKeepGoing() } label: {
                    Label("Yes, still working", systemImage: "checkmark")
                }
                .buttonStyle(BannerPrimaryButtonStyle())

                Button { actions.onStopTimer() } label: {
                    Label("Stop timer", systemImage: "stop.fill")
                }
                .buttonStyle(BannerSecondaryButtonStyle(color: AppColor.harvestRed))

                Button { actions.onStopAndSubtractIdle() } label: {
                    Label("Stop & subtract idle", systemImage: "minus.circle")
                }
                .buttonStyle(BannerSecondaryButtonStyle(color: AppColor.harvestRed))

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Long Timer

    private func longTimerContent(taskName: String, hours: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            bannerHeader(
                icon: "exclamationmark.triangle.fill",
                title: "\(taskName) running for \(String(format: "%.0f", hours))h",
                subtitle: "Forgot to switch tasks?"
            )

            HStack(spacing: 8) {
                Button { actions.onKeepGoing() } label: {
                    Label("Keep going", systemImage: "checkmark")
                }
                .buttonStyle(BannerPrimaryButtonStyle())

                Button { actions.onStopTimer() } label: {
                    Label("Switch task", systemImage: "arrow.triangle.swap")
                }
                .buttonStyle(BannerSecondaryButtonStyle())

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Summary (EOD / EOW)

    private func summaryContent(title: String, subtitle: String, logged: Double, delta: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            bannerHeader(
                icon: "chart.bar.fill",
                title: title,
                subtitle: subtitle
            )

            HStack(spacing: 28) {
                summaryStat(
                    value: formatSummaryHours(logged),
                    label: "Logged",
                    color: .primary
                )

                summaryStat(
                    value: formatSummaryDelta(delta),
                    label: delta >= 0 ? "Overtime" : "Remaining",
                    color: delta >= 0 ? AppColor.harvestRed : AppColor.harvestOrange
                )

                Spacer(minLength: 0)
            }
        }
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .monospacedDigit()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared Header (idle / longTimer / summary)

    private func bannerHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(AppColor.harvestOrange)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                // Allow up to 2 lines + a small scale so longer project names or
                // accessibility text sizes don't get truncated aggressively. The
                // banner is width-constrained but not height-critical.
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Footer (always present)

    private var footer: some View {
        HStack(spacing: 10) {
            if isSummary {
                // End-of-day / end-of-week reports are one-time; there's nothing
                // to snooze or skip, so offer a single dismiss.
                Spacer()
                Button(action: actions.onClose) {
                    Label("Close", systemImage: "xmark")
                }
                .buttonStyle(BannerFooterButtonStyle())
            } else {
                // Two "come back later" actions for the recurring nudges: a short
                // snooze on the left, skip-for-today on the right. Both have a
                // defined duration and are guaranteed to reappear, so the nudge
                // can never be silenced for an open-ended stretch (the reason the
                // old open-ended "Dismiss" button was removed).
                Button(action: actions.onSnooze) {
                    Label("Snooze \(snoozeDurationMinutes) min", systemImage: "clock.badge.xmark")
                }
                .buttonStyle(BannerFooterButtonStyle())

                Spacer()

                Button(action: actions.onSkipForToday) {
                    Label("Skip for today", systemImage: "calendar.badge.minus")
                }
                .buttonStyle(BannerFooterButtonStyle())
            }
        }
    }

    /// End-of-day / end-of-week summaries are one-time reports, not recurring
    /// nudges, so their footer is a plain Close rather than snooze / skip.
    private var isSummary: Bool {
        switch mode {
        case .eodSummary, .eowSummary: return true
        default: return false
        }
    }

    // MARK: - Formatting

    private func formatSummaryHours(_ hours: Double) -> String {
        let (h, m) = TimeFormat.hoursAndMinutes(hours)
        return String(format: "%d:%02d", h, m)
    }

    private func formatSummaryDelta(_ hours: Double) -> String {
        let sign = hours >= 0 ? "+" : "-"
        let (h, m) = TimeFormat.hoursAndMinutes(hours)
        return String(format: "%@%d:%02d", sign, h, m)
    }
}

// MARK: - Button Styles

/// Filled pill – the primary, affirmative action in any mode.
struct BannerPrimaryButtonStyle: ButtonStyle {
    var color: Color = AppColor.harvestOrange

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // `.contentShape` before the fill guarantees the whole padded
            // rect is hittable – without it, clicks in the gap between the
            // Label's icon and text fell through.
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .fill(color)
            )
            .brightness(configuration.isPressed ? -0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .fixedSize()
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .harvestHover(style: .filled, cornerRadius: AppRadius.sm)
    }
}

/// Outlined pill – secondary actions like Stop / Switch task. Colored text
/// and border, no fill, so it sits visibly lower in the hierarchy than primary.
struct BannerSecondaryButtonStyle: ButtonStyle {
    var color: Color = AppColor.harvestOrange

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.sm))
            .background(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .strokeBorder(
                        color.opacity(configuration.isPressed ? 0.9 : 0.5),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .fixedSize()
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .harvestHover(style: .outlined(tint: color), cornerRadius: AppRadius.sm)
    }
}

/// Footer controls (Snooze / Skip for today). Ghost text-link style – they're
/// always available but never the thing the user came here to click.
struct BannerFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FooterLabel(label: configuration.label, isPressed: configuration.isPressed)
    }

    /// Nested so we can own `@State private var isHovered` (ButtonStyle is a
    /// value type, so it can't hold state directly). The hover state drives
    /// both the background and the text color transition.
    private struct FooterLabel: View {
        let label: ButtonStyleConfiguration.Label
        let isPressed: Bool
        @State private var isHovered = false

        var body: some View {
            label
                .font(.callout)
                .fontWeight(.medium)
                // Transition secondary → primary on hover for a clear "this is
                // a button, not static text" cue. The previous brightness-only
                // hover was nearly invisible.
                .foregroundStyle(isHovered || isPressed ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                // Hit the full padded area, not just the glyphs – the user
                // was getting dead clicks in the gap between icon and text.
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(isHovered ? 0.14 : 0))
                )
                .opacity(isPressed ? 0.6 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .onHover { isHovered = $0 }
        }
    }
}

// MARK: - Hover Effect Modifier
//
// Stronger hover feedback than the prior `brightness(0.06)`-only modifier.
// A fill-surface button gets an overlay lightening; an outlined button gets
// a subtle tinted background so the whole pill reads as "armed" on hover.
// The previous hover was so subtle users couldn't tell interactive elements
// from static ones.

enum HarvestHoverStyle {
    /// Solid-filled buttons (BannerPrimaryButtonStyle). The hover tint sits
    /// on top of the fill so the brand color is still visible.
    case filled
    /// Outlined / ghost buttons (BannerSecondaryButtonStyle). The hover tint
    /// sits behind the content, using the button's own color at low opacity.
    case outlined(tint: Color)
}

extension View {
    func harvestHover(style: HarvestHoverStyle = .filled, cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverEffectModifier(style: style, cornerRadius: cornerRadius))
    }
}

struct HoverEffectModifier: ViewModifier {
    let style: HarvestHoverStyle
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        switch style {
        case .filled:
            content
                .overlay(
                    // White overlay reads as "lighter" on both the colored
                    // fill and neutral dark surfaces. 0.14 is enough to
                    // register as a deliberate hover, not as rendering noise.
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.white.opacity(isHovered ? 0.14 : 0))
                        .allowsHitTesting(false)
                )
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        case .outlined(let tint):
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(tint.opacity(isHovered ? 0.18 : 0))
                )
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}
