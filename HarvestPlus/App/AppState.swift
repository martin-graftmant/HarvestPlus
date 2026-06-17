//
//  AppState.swift
//  HarvestPlus
//
//  Created by Razvan Politic on 14/04/2026.
//
//  The app's single source of truth (`ObservableObject`). Owns the timer
//  state, today's / this week's entries, settings, the Harvest client, and
//  the monitor / banner / idle / update helpers; persists settings to
//  UserDefaults and loads saved credentials at launch. The model/settings
//  types it holds live in TimerState.swift, WorkSchedule.swift, and
//  AppSettings.swift.
//

import SwiftUI
import Combine

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var timerState: TimerState = .stopped
    @Published var todayEntries: [TimeEntry] = []
    @Published var weekEntries: [TimeEntry] = []
    @Published var settings: AppSettings = AppSettings()
    @Published var isConnected: Bool = false

    /// Wall-clock time of the most recent successful Harvest API poll.
    /// Live elapsed time for the running timer is extrapolated from this
    /// value (not from `timer_started_at`), because Harvest's API returns
    /// `hours` as the live total at poll time. See TimeEntry.liveHours().
    @Published var lastPolledAt: Date?

    private(set) var harvestClient: HarvestAPIClient?
    /// Token kept in memory so the Settings UI can read it without a second
    /// keychain call on every view appear. Populated once at launch, updated
    /// whenever new credentials are saved. Never written anywhere except the
    /// login Keychain.
    private(set) var harvestToken: String = ""
    private(set) var timerMonitor: TimerMonitor?
    private(set) var bannerManager: BannerManager?
    private(set) var idleDetector: IdleDetector?
    private(set) var systemEventHandler: SystemEventHandler?
    @Published var actionError: String? = nil

    /// Guards the timer mutation actions (start / stop / stop-and-subtract) so a
    /// double-click – or a manual Stop racing the auto-stop-on-sleep – can't fire
    /// two Harvest writes for the same entry (the second would 422 and surface a
    /// spurious error). Set/cleared on the main actor around the network round-trip.
    private var isApplyingTimerAction = false

    // Calendar integration (EventKit)
    let calendarService = CalendarService()
    @Published var todayMeetings: [CalendarEvent] = []

    // Meeting → project/task memory
    let meetingMapper = MeetingProjectMapper()

    /// The meeting the user is about to log. Set when they click a meeting from the
    /// popover; a separate window reads this and shows the entry form.
    @Published var pendingMeetingEntry: CalendarEvent?

    // Project assignments (projects + tasks the user can log against). Loaded lazily.
    @Published var projectAssignments: [ProjectAssignment] = []
    @Published var isLoadingProjectAssignments: Bool = false
    /// When project assignments were last fetched, for the refresh cadence in
    /// loadProjectAssignmentsIfNeeded(force:).
    private var projectAssignmentsLastLoaded: Date?

    // Sparkle-based auto-updater. Initialised eagerly so the background
    // scheduler is running before the user ever opens Settings.
    let updateChecker = UpdateChecker()

    init() {
        // Load persisted settings
        loadPersistedSettings()

        // Try to load saved credentials on launch. We deliberately do NOT
        // re-save them here – the ACL was set the first time the items were
        // written, and with a stable Developer ID signature it stays valid
        // across all future builds. Re-saving on every launch was previously
        // triggering "change access permissions" password prompts because
        // KeychainHelper.save used to attach a new ACL to every update.
        if let accountId = try? KeychainHelper.loadString(key: KeychainKey.harvestAccountId),
           let token = try? KeychainHelper.loadString(key: KeychainKey.harvestToken),
           !accountId.isEmpty, !token.isEmpty {
            harvestClient = HarvestAPIClient(accountId: accountId, token: token)
            harvestToken = token
            settings.harvestAccountId = accountId
            isConnected = true
            Task {
                await fetchInitialData()
                startMonitoring()
            }
        }

        // Load calendar events if authorized
        if calendarService.isAuthorized {
            todayMeetings = calendarService.getEvents(for: Date())
        }

        // Sparkle handles its own scheduling – the SPUUpdater inside
        // updateChecker was started in its initializer with
        // `startingUpdater: true`, so background checks are already armed
        // and will fire on Sparkle's `SUScheduledCheckInterval` (24h).
    }

    func initializeHarvestClient(accountId: String, token: String) {
        harvestClient = HarvestAPIClient(accountId: accountId, token: token)
        harvestToken = token
        isConnected = true
        Task {
            await fetchInitialData()
            startMonitoring()
        }
    }

    // MARK: - Timer Monitor + Banner

    private func startMonitoring() {
        timerMonitor?.stopPolling()
        let monitor = TimerMonitor(appState: self)
        timerMonitor = monitor
        monitor.startPolling(interval: settings.pollingInterval)

        // Set up banner manager
        if bannerManager == nil {
            bannerManager = BannerManager(appState: self)
        }

        // Set up idle detector
        if idleDetector == nil {
            let detector = IdleDetector(appState: self)
            detector.onIdleDetected = { [weak self] idleDuration in
                guard let self = self else { return }
                if case .running(let entry) = self.timerState {
                    let taskName = entry.shortDisplayName
                    self.bannerManager?.showBanner(mode: .idle(taskName: taskName))
                }
            }
            idleDetector = detector
            detector.startMonitoring()
        }

        // Set up system event handler (auto-start/stop, EOD/EOW summaries)
        if systemEventHandler == nil {
            systemEventHandler = SystemEventHandler(appState: self)
        }
    }

    // MARK: - Timer Actions

    func stopCurrentTimer() async {
        guard !isApplyingTimerAction,
              let client = harvestClient,
              let entry = currentRunningEntry else { return }
        isApplyingTimerAction = true
        defer { isApplyingTimerAction = false }

        do {
            _ = try await client.stopTimer(entryId: entry.id)
            timerState = .stopped
            idleDetector?.resetIdleState()
            invalidateEntryCache()
            await timerMonitor?.pollNow()
        } catch {
            actionError = error.localizedDescription
        }
    }

    func startTimer(projectId: Int, taskId: Int) async {
        guard !isApplyingTimerAction, let client = harvestClient else { return }
        isApplyingTimerAction = true
        defer { isApplyingTimerAction = false }

        do {
            let entry = try await client.startTimer(projectId: projectId, taskId: taskId)
            timerState = .running(entry)
            idleDetector?.resetIdleState()
            invalidateEntryCache()
            await timerMonitor?.pollNow()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Stop the current timer and subtract the idle duration from the entry.
    func stopAndSubtractIdleTime() async {
        guard !isApplyingTimerAction,
              let client = harvestClient,
              let entry = currentRunningEntry,
              let detector = idleDetector else { return }
        isApplyingTimerAction = true
        defer { isApplyingTimerAction = false }

        let idleHours = detector.currentIdleDuration / 3600.0

        do {
            // Stop the timer first
            let stoppedEntry = try await client.stopTimer(entryId: entry.id)

            // Subtract idle time from the total hours
            let adjustedHours = max(0, stoppedEntry.hours - idleHours)
            _ = try await client.updateTimeEntry(entryId: entry.id, hours: adjustedHours)

            timerState = .stopped
            detector.resetIdleState()
            invalidateEntryCache()
            // Refresh data immediately
            await timerMonitor?.pollNow()
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Data Fetching

    private func fetchInitialData() async {
        guard let client = harvestClient else { return }

        do {
            // Fetch running timer
            if let running = try await client.getRunningTimer() {
                timerState = .running(running)
            } else {
                timerState = .stopped
            }

            // Fetch today's entries
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            todayEntries = try await client.getTimeEntries(from: startOfDay, to: Date())

            // Fetch current week's entries (Monday to Sunday)
            let isoCal = Calendar(identifier: .iso8601)
            let monday = isoCal.date(from: isoCal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))!
            let sunday = isoCal.date(byAdding: .day, value: 6, to: monday)!
            weekEntries = try await client.getTimeEntries(from: monday, to: sunday)
        } catch {
            if let apiError = error as? HarvestAPIError {
                switch apiError {
                case .unauthorized:
                    isConnected = false
                case .networkError:
                    // Credentials are fine – we're just offline. Show it now
                    // instead of waiting for the first scheduled poll.
                    timerState = .offline
                default:
                    break
                }
            }
            // Keep previous state on other errors
        }
    }

    var todayTotalHours: Double {
        let now = Date()
        let polledAt = lastPolledAt
        return todayEntries.reduce(0) { total, entry in
            total + entry.liveHours(now: now, polledAt: polledAt)
        }
    }

    var todayTarget: Double {
        HolidayEngine.expectedHours(for: Date(), settings: settings)
    }

    var todayProgress: Double {
        guard todayTarget > 0 else { return 0 }
        return min(todayTotalHours / todayTarget, 1.0)
    }

    var todayDelta: Double {
        todayTotalHours - todayTarget
    }

    var currentRunningEntry: TimeEntry? {
        if case .running(let entry) = timerState {
            return entry
        }
        return nil
    }

    // MARK: - Export Data (non-reactive – does NOT trigger view re-renders)

    /// Holds the current export period for the active dashboard tab.
    /// Intentionally NOT @Published so setting it doesn't cascade re-renders.
    var pendingExportPeriod: ExportPeriod?

    // MARK: - Entry Cache

    private var entryCache: [String: (entries: [TimeEntry], fetchedAt: Date)] = [:]
    private let cacheTTL: TimeInterval = 120  // 2 minutes

    private static let cacheKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func cacheKey(from: Date, to: Date) -> String {
        return "\(Self.cacheKeyFormatter.string(from: from))_\(Self.cacheKeyFormatter.string(from: to))"
    }

    /// Fetch entries for a given date range (for dashboard use). Uses cache.
    func fetchEntries(from: Date, to: Date) async -> [TimeEntry] {
        let key = cacheKey(from: from, to: to)

        // Return cached if fresh
        if let cached = entryCache[key],
           Date().timeIntervalSince(cached.fetchedAt) < cacheTTL {
            return cached.entries
        }

        guard let client = harvestClient else { return [] }
        do {
            let entries = try await client.getTimeEntries(from: from, to: to)
            entryCache[key] = (entries: entries, fetchedAt: Date())
            return entries
        } catch {
            return []
        }
    }

    /// Wall-clock time when the entries for this date range were last
    /// fetched from Harvest. Dashboards use this as `polledAt` for live-
    /// elapsed extrapolation so the running timer's contribution matches
    /// `entry.hours` exactly – using the global `lastPolledAt` instead
    /// can be off by tens of seconds because that's updated by
    /// `TimerMonitor` on a different schedule than the dashboards' cache.
    /// Returns the global `lastPolledAt` as a fallback when nothing is
    /// cached for this range yet (e.g., first paint before fetch lands).
    func fetchedAt(from: Date, to: Date) -> Date? {
        let key = cacheKey(from: from, to: to)
        return entryCache[key]?.fetchedAt ?? lastPolledAt
    }

    /// Invalidate cache (e.g. after starting/stopping a timer).
    func invalidateEntryCache() {
        entryCache.removeAll()
    }

    // MARK: - Calendar Integration

    func refreshTodayMeetings() {
        guard calendarService.isAuthorized else {
            todayMeetings = []
            return
        }
        todayMeetings = calendarService.getEvents(for: Date())
    }

    /// Fetch meetings for a specific date (for dashboard use).
    func fetchMeetings(for date: Date) async -> [CalendarEvent] {
        guard calendarService.isAuthorized else { return [] }
        return calendarService.getEvents(for: date)
    }

    // MARK: - Project Assignments (projects + tasks)

    /// Load the user's project assignments, refreshing at most once an hour.
    /// Projects change rarely, so we cache them and avoid hitting the network
    /// (and the error popups a flaky connection brings) on every open. Pass
    /// `force` to refresh immediately regardless of the cache age.
    func loadProjectAssignmentsIfNeeded(force: Bool = false) async {
        let ttl: TimeInterval = 3600   // refresh at most once an hour
        let isFresh = projectAssignmentsLastLoaded.map { Date().timeIntervalSince($0) < ttl } ?? false
        if !force && !projectAssignments.isEmpty && isFresh { return }
        guard let client = harvestClient else { return }

        isLoadingProjectAssignments = true
        do {
            let assignments = try await client.getMyProjectAssignments()
            // Keep only active project assignments with at least one active task.
            projectAssignments = assignments
                .filter { $0.isActive && !$0.activeTasks.isEmpty }
                .sorted { $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending }
            projectAssignmentsLastLoaded = Date()
        } catch {
            // A background refresh failed. Keep the cached projects and stay
            // quiet; only surface the error when we have nothing to show.
            if projectAssignments.isEmpty {
                actionError = "Couldn't load projects: \(error.localizedDescription)"
            }
        }
        isLoadingProjectAssignments = false
    }

    /// Create a (non-running) time entry for a meeting and remember the
    /// project/task choice for that meeting title.
    /// Returns `true` on success.
    @discardableResult
    func createEntryForMeeting(
        meetingTitle: String,
        projectId: Int,
        projectName: String,
        taskId: Int,
        taskName: String,
        spentDate: Date,
        hours: Double?,
        notes: String?
    ) async -> Bool {
        guard let client = harvestClient else { return false }

        do {
            _ = try await client.createTimeEntry(
                projectId: projectId,
                taskId: taskId,
                spentDate: spentDate,
                hours: hours,
                notes: notes
            )

            // Remember the choice for this meeting title
            meetingMapper.remember(
                meetingTitle: meetingTitle,
                projectId: projectId,
                projectName: projectName,
                taskId: taskId,
                taskName: taskName
            )

            invalidateEntryCache()
            await timerMonitor?.pollNow()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    // MARK: - Load Persisted Settings

    private func loadPersistedSettings() {
        let ud = UserDefaults.standard

        // General
        settings.pollingInterval = ud.object(forKey: "pollingInterval") as? TimeInterval ?? 60

        // Work Schedule
        settings.workSchedule.workStartTime = DateComponents(
            hour: ud.object(forKey: "workStartHour") as? Int ?? 8,
            minute: ud.object(forKey: "workStartMinute") as? Int ?? 0
        )
        settings.workSchedule.workEndTime = DateComponents(
            hour: ud.object(forKey: "workEndHour") as? Int ?? 16,
            minute: ud.object(forKey: "workEndMinute") as? Int ?? 0
        )
        settings.workSchedule.targetMon = ud.object(forKey: "targetMon") as? Double ?? 7.5
        settings.workSchedule.targetTue = ud.object(forKey: "targetTue") as? Double ?? 7.5
        settings.workSchedule.targetWed = ud.object(forKey: "targetWed") as? Double ?? 7.5
        settings.workSchedule.targetThu = ud.object(forKey: "targetThu") as? Double ?? 7.5
        settings.workSchedule.targetFri = ud.object(forKey: "targetFri") as? Double ?? 7.0
        settings.workSchedule.targetSat = ud.object(forKey: "targetSat") as? Double ?? 0.0
        settings.workSchedule.targetSun = ud.object(forKey: "targetSun") as? Double ?? 0.0
        settings.workSchedule.lunchDuration = (ud.object(forKey: "lunchDuration") as? Double ?? 30) * 60
        if ud.bool(forKey: "hasLunchWindow") {
            settings.workSchedule.lunchWindowStart = DateComponents(
                hour: ud.object(forKey: "lunchWindowHour") as? Int ?? 12,
                minute: ud.object(forKey: "lunchWindowMinute") as? Int ?? 0
            )
        }

        // Notifications
        settings.timerNudgeEnabled = ud.object(forKey: "timerNudge") as? Bool ?? true
        settings.bannerPosition = BannerPosition(rawValue: ud.string(forKey: "bannerPosition") ?? "Top") ?? .top
        settings.snoozeDuration = (ud.object(forKey: "snoozeDuration") as? Double ?? 15) * 60
        settings.idleDetectionEnabled = ud.object(forKey: "idleDetection") as? Bool ?? true
        settings.idleThreshold = (ud.object(forKey: "idleThreshold") as? Double ?? 15) * 60
        settings.longTimerWarningEnabled = ud.object(forKey: "longTimerWarning") as? Bool ?? true
        settings.longTimerThreshold = (ud.object(forKey: "longTimerThreshold") as? Double ?? 3) * 3600
        settings.autoStopOnSleep = ud.bool(forKey: "autoStopOnSleep")

        // EOD / EOW summary schedule – keys written by NotificationsSettingsTab.
        // Without loading here, the scheduler falls back to 16:00 every app
        // launch until the user opens Settings (which re-syncs as a side effect).
        settings.eodSummaryEnabled = ud.object(forKey: "eodSummary") as? Bool ?? true
        settings.eodSummaryTime = DateComponents(
            hour: ud.object(forKey: "eodHour") as? Int ?? 16,
            minute: ud.object(forKey: "eodMinute") as? Int ?? 0
        )
        settings.eowSummaryEnabled = ud.object(forKey: "eowSummary") as? Bool ?? true
        settings.eowSummaryTime = DateComponents(
            hour: ud.object(forKey: "eowHour") as? Int ?? 16,
            minute: ud.object(forKey: "eowMinute") as? Int ?? 0
        )

        // Holidays
        settings.holidayTaskNames = ud.string(forKey: "holidayTaskNames") ?? "Holiday"
        settings.holidayICSUrl = ud.string(forKey: "holidayICSUrl") ?? ""

        // Export
        settings.defaultExportFormat = ExportFormat(rawValue: ud.string(forKey: "defaultExportFormat") ?? "PDF") ?? .pdf
        settings.pdfPaperSize = PaperSize(rawValue: ud.string(forKey: "pdfPaperSize") ?? "A4") ?? .a4
        // Default true; treat a stored missing key as "on" so existing
        // users keep the prefix-stripping behaviour they had before.
        settings.stripProjectPrefixCodes = ud.object(forKey: "stripProjectPrefixCodes") as? Bool ?? true
        // Stored as `yyyy-MM-dd` so it's human-readable in the plist and
        // round-trips cleanly across time zones.
        if let dateString = ud.string(forKey: "reportStartDate"),
           let date = Self.persistedDateFormatter.date(from: dateString) {
            settings.reportStartDate = date
        }
    }

    /// Day-only formatter for persisting cutoff-style dates.
    static let persistedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
