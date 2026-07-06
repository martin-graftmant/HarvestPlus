//
//  BannerManager.swift
//  HarvestPlus
//
//  Created by Razvan Politic on 14/04/2026.
//
//  Owns the floating nudge banner: decides when to show it (date-based
//  snooze / skip-for-today muting), drives the self-rescheduling nudge
//  timer off the timer-state stream, and shows / hides the BannerPanel.
//

import AppKit
import SwiftUI
import Combine

// MARK: - Banner Manager

@MainActor
final class BannerManager: ObservableObject {
    @Published var isVisible: Bool = false

    private var panel: BannerPanel?
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var nudgeDelayTimer: Timer?

    // MARK: - Date-based muting
    //
    // Previously we tracked snoozing with an `isSnoozed: Bool` and a 15-min
    // Timer that flipped it back. Two real bugs lived in that design:
    //   1) The `.running` branch reset `isSnoozed` to false, so a brief
    //      running→stopped transition during the snooze period broke it.
    //      That's why the banner reappeared roughly 30s after clicking
    //      Snooze: the 60s poll re-emitted `.running` (or just .stopped
    //      again) and the nudge-delay timer rearmed.
    //   2) Stuck states: if the snooze Timer never fired (e.g. the system
    //      was asleep through the 15 min, or two Snooze clicks left a
    //      dangling Timer reference), `isSnoozed` could remain true
    //      indefinitely – which is why "after a few skips it doesn't
    //      appear anymore" happened.
    //
    // The fix is to drop both timers and the boolean, and represent each
    // mute as an absolute Date in the future. Date-based muting can't
    // drift out of sync with reality – it naturally expires when wall-
    // clock passes the stored timestamp, no Timer to mis-fire or leak.
    // Both values persist in UserDefaults so a 15-min snooze or a "skip
    // for today" survives quit/relaunch.

    private static let snoozedUntilKey = "bannerSnoozedUntil"
    private static let skippedUntilKey = "bannerSkippedUntil"

    private var snoozedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Self.snoozedUntilKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.snoozedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.snoozedUntilKey)
            }
        }
    }

    private var skippedUntil: Date? {
        get { UserDefaults.standard.object(forKey: Self.skippedUntilKey) as? Date }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.skippedUntilKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.skippedUntilKey)
            }
        }
    }

    /// True if any active mute (snooze or skip-for-today) is still in
    /// effect. Replaces the old `isSnoozed` boolean everywhere.
    private var isMuted: Bool {
        let now = Date()
        if let s = snoozedUntil, now < s { return true }
        if let s = skippedUntil, now < s { return true }
        return false
    }

    init(appState: AppState) {
        self.appState = appState
        observeTimerState()
    }

    // MARK: - State Observation

    private func observeTimerState() {
        guard let appState = appState else { return }

        appState.$timerState
            // CRITICAL: `@Published` re-emits on every assignment, and
            // TimerMonitor re-assigns `timerState` on every poll (e.g. every
            // 15s). Without dedup, each poll re-entered handleTimerStateChange
            // and reset the 30s nudge delay timer, so with a poll interval
            // ≤ 30s the nudge could never fire. removeDuplicates() (TimerState
            // is Equatable) makes us react only to genuine state transitions.
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleTimerStateChange(state)
            }
            .store(in: &cancellables)
    }

    private func handleTimerStateChange(_ state: TimerState) {
        switch state {
        case .running:
            // Timer started – cancel any pending nudge and hide the banner.
            // DO NOT clear snoozedUntil / skippedUntil: those are explicit
            // absolute time windows the user chose, and a brief
            // running→stopped transition (or a polling re-emit of `.running`)
            // shouldn't break them.
            nudgeDelayTimer?.invalidate()
            nudgeDelayTimer = nil
            hideBanner()

        case .stopped:
            // Arm the nudge with the standard 30s grace period – enough time
            // for the user to start a new timer before we prompt.
            scheduleNudge(after: 30)

        case .offline:
            nudgeDelayTimer?.invalidate()
            nudgeDelayTimer = nil
            hideBanner()
        }
    }

    // MARK: - Nudge scheduling
    //
    // The nudge should appear once all of these hold continuously: timer
    // stopped, within work hours, nudge enabled, and not muted (snooze /
    // skip-for-today). We model that with a single pending timer that, when
    // it fires, either shows the banner or – if a *temporary* condition is
    // blocking (an active snooze/skip, or we're outside work hours) –
    // reschedules itself to re-check when that condition is likely to have
    // lifted. This keeps the nudge reliable regardless of the poll interval
    // and without depending on `@Published` re-emissions.

    private func scheduleNudge(after delay: TimeInterval) {
        nudgeDelayTimer?.invalidate()
        nudgeDelayTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateNudge()
            }
        }
    }

    private func evaluateNudge() {
        guard let appState = appState else { return }

        // Only relevant while the timer is stopped.
        guard appState.timerState == .stopped else { return }

        // Temporarily muted (snooze / skip-for-today): re-check just after
        // the mute is due to lift rather than dropping the nudge entirely.
        if let until = activeMuteExpiry {
            scheduleNudge(after: max(1, until.timeIntervalSinceNow) + 1)
            return
        }

        guard appState.settings.timerNudgeEnabled else { return }

        // Outside configured work hours: don't nag, but keep checking on a
        // low frequency so we catch the start of the next work window.
        guard appState.settings.workSchedule.isWorkingHours(at: Date()) else {
            scheduleNudge(after: 300)  // 5 min
            return
        }

        showBanner(mode: .nudge)
    }

    /// The latest still-in-the-future mute expiry (snooze or skip), or nil
    /// if nothing is currently muting the nudge.
    private var activeMuteExpiry: Date? {
        let now = Date()
        return [snoozedUntil, skippedUntil]
            .compactMap { $0 }
            .filter { $0 > now }
            .max()
    }

    // MARK: - Show / Hide

    func showBanner(mode: BannerMode) {
        guard let appState = appState else { return }

        // Per-mode width. The nudge is deliberately narrow so the view grows
        // taller – it reads as a calm, square-ish prompt rather than a strip.
        // The reactive modes get more width for their action rows.
        let bannerWidth = Self.preferredWidth(for: mode)

        let actions = BannerActions(
            onSnooze: { [weak self] in
                self?.snooze()
            },
            onSkipForToday: { [weak self] in
                self?.skipForToday()
            },
            onClose: { [weak self] in
                self?.hideBanner()
            },
            onStopTimer: { [weak self] in
                Task {
                    await self?.appState?.stopCurrentTimer()
                }
                self?.hideBanner()
            },
            onStopAndSubtractIdle: { [weak self] in
                Task {
                    await self?.appState?.stopAndSubtractIdleTime()
                }
                self?.hideBanner()
            },
            onKeepGoing: { [weak self] in
                self?.hideBanner()
            },
            onOpenHarvest: { [weak self] in
                PopoverView.openHarvestApp()
                self?.hideBanner()
                // Re-arm in 3 minutes so a user who opens Harvest and gets
                // distracted (never actually starts a timer) gets prompted again
                // rather than silently going un-tracked for the rest of the day.
                // If they DO start a timer in the meantime, the `.running`
                // transition in handleTimerStateChange cancels this pending
                // nudge before it fires.
                self?.scheduleNudge(after: 180)
            }
        )

        let snoozeMins = Int(appState.settings.snoozeDuration / 60)

        // Pin width via SwiftUI so the view can calculate the height it needs
        // given that width. No hard-coded min height – compact modes (nudge)
        // are free to settle into their natural square-ish proportions.
        let bannerView = BannerView(
            mode: mode,
            actions: actions,
            snoozeDurationMinutes: snoozeMins
        )
        .frame(width: bannerWidth)

        let hostingView = NSHostingView(rootView: bannerView)
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let bannerHeight = max(fittingSize.height, 80)
        hostingView.frame = NSRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight)

        // Create panel if needed
        if panel == nil {
            panel = BannerPanel(contentRect: NSRect(x: 0, y: 0, width: bannerWidth, height: bannerHeight))
        }

        guard let panel = panel else { return }
        panel.setContentSize(NSSize(width: bannerWidth, height: bannerHeight))
        panel.contentView = hostingView

        // Position based on user preference
        if appState.settings.bannerPosition == .bottom {
            panel.positionAboveDock()
        } else {
            panel.positionBelowMenuBar()
        }

        // Animate in: start offscreen above, slide down
        let finalOrigin = panel.frame.origin
        let startOrigin = NSPoint(x: finalOrigin.x, y: finalOrigin.y + 60)
        panel.setFrameOrigin(startOrigin)
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(finalOrigin)
            panel.animator().alphaValue = 1
        }

        isVisible = true
    }

    func hideBanner() {
        guard let panel = panel, isVisible else { return }

        let currentOrigin = panel.frame.origin
        let targetOrigin = NSPoint(x: currentOrigin.x, y: currentOrigin.y + 60)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrameOrigin(targetOrigin)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            Task { @MainActor [weak self] in
                self?.isVisible = false
            }
        })
    }

    // MARK: - Snooze / Skip

    private func snooze() {
        let duration = appState?.settings.snoozeDuration ?? 15 * 60
        snoozedUntil = Date().addingTimeInterval(duration)
        hideBanner()
        // Re-arm so the nudge reappears once the snooze lifts (evaluateNudge
        // sees the active mute and reschedules itself for the expiry).
        scheduleNudge(after: 1)
    }

    /// Suppress the banner for the rest of today. "Today" ends at 00:00
    /// local time, so this is essentially "leave me alone until tomorrow".
    private func skipForToday() {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        if let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) {
            skippedUntil = startOfTomorrow
        }
        hideBanner()
        scheduleNudge(after: 1)
    }

    // MARK: - Sizing

    /// Each mode has different content weight – nudge is minimal and wants a
    /// near-square footprint; the idle banner needs room for three buttons.
    private static func preferredWidth(for mode: BannerMode) -> CGFloat {
        let screenCap = (NSScreen.main?.frame.width ?? 1200) * 0.9
        let desired: CGFloat
        switch mode {
        case .nudge:           desired = 420   // narrow → grows tall, feels square-ish (3-button footer)
        case .idle:            desired = 580   // 3 action buttons
        case .longTimer:       desired = 500   // 2 action buttons
        case .eodSummary,
             .eowSummary:      desired = 460   // stats row
        }
        return min(desired, screenCap)
    }

    deinit {
        nudgeDelayTimer?.invalidate()
    }
}
