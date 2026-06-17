//
//  MeetingEntrySheet.swift
//  HarvestPlus
//
//  Sheet for turning a calendar meeting into a Harvest time entry.
//  Shows the meeting title as editable notes; user picks project + task.
//  If the same meeting title has been mapped before, the project + task are
//  pre-filled so it's a single-click save.
//

import SwiftUI

// MARK: - Shared Formatters (hoisted to avoid per-render allocation)

private let meetingFullDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .full
    return f
}()

private let meetingTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

struct MeetingEntrySheet: View {
    @EnvironmentObject var appState: AppState

    let meeting: CalendarEvent
    let onDismiss: () -> Void

    // Form state
    @State private var selectedProjectId: Int?
    @State private var selectedTaskId: Int?
    @State private var notes: String
    @State private var durationDate: Date
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var didAutoFill: Bool = false

    init(meeting: CalendarEvent, onDismiss: @escaping () -> Void) {
        self.meeting = meeting
        self.onDismiss = onDismiss
        _notes = State(initialValue: meeting.subject)
        _durationDate = State(initialValue: Self.durationDate(fromMinutes: max(0, meeting.durationMinutes)))
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    meetingSummary
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    entryForm

                    if let error = errorMessage {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(AppColor.harvestRed)
                            .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }

            Divider()

            footer
        }
        .frame(width: 460, height: 560)
        .task {
            // Refresh on a cadence (see loadProjectAssignmentsIfNeeded) so new
            // Harvest projects appear without refetching on every open.
            await appState.loadProjectAssignmentsIfNeeded()
            prefillFromMemoryIfPossible()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log this meeting")
                    .font(.headline)
                Text(meetingDateString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
            // The Cancel button owns `.cancelAction` (Escape); don't add a
            // second handler here or both fire and the sheet can behave oddly.
        }
        .padding(.horizontal, AppSpacing.xl)
        .padding(.vertical, 14)
    }

    // MARK: - Meeting summary

    private var meetingSummary: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(AppColor.meetingBlue)
                .frame(width: 4, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.subject)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(meetingTimeRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(meeting.durationMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Spacer()

            if didAutoFill {
                Label("Remembered", systemImage: "sparkles")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(AppColor.harvestOrange)
                    .transition(.opacity)
            }
        }
        .padding(AppSpacing.md)
        .harvestSurface(cornerRadius: AppRadius.sm)
        .animation(.easeOut(duration: 0.2), value: didAutoFill)
    }

    // MARK: - Entry form
    //
    // All fields share the same `Form { Section { ... } }.formStyle(.grouped)`
    // chrome used by `ScheduleSettingsTab` so the sheet matches the rest of
    // the app. Each row is a plain SwiftUI Form control (TextField / Picker /
    // DatePicker) with its label supplied via the first argument – Form takes
    // care of label-on-left / control-on-right layout and field widths.

    private var entryForm: some View {
        Form {
            Section {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(1...3)

                Picker("Project", selection: projectBinding) {
                    Text("Choose project").tag(Int?.none)
                    ForEach(appState.projectAssignments) { assignment in
                        Text(projectDisplayName(assignment))
                            .tag(assignment.project.id as Int?)
                    }
                }
                .disabled(appState.projectAssignments.isEmpty)

                Picker("Task", selection: $selectedTaskId) {
                    Text(selectedProjectId == nil ? "Choose project first" : "Choose task")
                        .tag(Int?.none)
                    ForEach(availableTasks, id: \.id) { task in
                        Text(task.name).tag(task.id as Int?)
                    }
                }
                .disabled(selectedProjectId == nil || availableTasks.isEmpty)

                DatePicker("Duration", selection: $durationDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
            }
        }
        .formStyle(.grouped)
    }

    /// Reset the task when the project changes so a stale task ID from another
    /// project can't be saved.
    private var projectBinding: Binding<Int?> {
        Binding(
            get: { selectedProjectId },
            set: { newValue in
                if selectedProjectId != newValue {
                    selectedProjectId = newValue
                    selectedTaskId = nil
                }
            }
        )
    }

    private func projectDisplayName(_ assignment: ProjectAssignment) -> String {
        if let client = assignment.client {
            return "\(client.name) – \(assignment.project.name)"
        }
        return assignment.project.name
    }

    private var availableTasks: [HarvestTask] {
        guard let pid = selectedProjectId,
              let assignment = appState.projectAssignments.first(where: { $0.project.id == pid }) else {
            return []
        }
        return assignment.activeTasks
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if appState.meetingMapper.savedDefault(for: meeting.subject) != nil {
                Button("Forget project") {
                    appState.meetingMapper.forget(meetingTitle: meeting.subject)
                    didAutoFill = false
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Clear the remembered project/task for future meetings with this title")
            }

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                save()
            } label: {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save entry")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private var canSave: Bool {
        selectedProjectId != nil && selectedTaskId != nil && totalHours > 0
    }

    private var totalHours: Double {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: durationDate)
        return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    }

    private func save() {
        guard let projectId = selectedProjectId,
              let taskId = selectedTaskId,
              let assignment = appState.projectAssignments.first(where: { $0.project.id == projectId }),
              let task = assignment.activeTasks.first(where: { $0.id == taskId }),
              totalHours > 0
        else { return }

        let hours = totalHours
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        isSaving = true
        errorMessage = nil

        Task {
            let success = await appState.createEntryForMeeting(
                meetingTitle: meeting.subject,
                projectId: projectId,
                projectName: assignment.project.name,
                taskId: taskId,
                taskName: task.name,
                spentDate: meeting.start,
                hours: hours,
                notes: trimmedNotes.isEmpty ? nil : trimmedNotes
            )
            isSaving = false

            if success {
                onDismiss()
            } else {
                errorMessage = appState.actionError ?? "Couldn't save the entry."
            }
        }
    }

    private func prefillFromMemoryIfPossible() {
        // Don't clobber user edits. `.task` fires after assignments finish
        // loading, which can be seconds on cold start; if the user already
        // picked a project/task while we were loading, bail.
        guard !didAutoFill && selectedProjectId == nil && selectedTaskId == nil else {
            return
        }
        guard let saved = appState.meetingMapper.savedDefault(for: meeting.subject) else {
            return
        }
        // Only prefill if the saved project still exists in the user's assignments.
        guard let assignment = appState.projectAssignments.first(where: { $0.project.id == saved.projectId }) else {
            return
        }
        guard assignment.activeTasks.contains(where: { $0.id == saved.taskId }) else {
            // Project still exists but saved task no longer does – prefill project only.
            selectedProjectId = saved.projectId
            didAutoFill = true
            return
        }
        selectedProjectId = saved.projectId
        selectedTaskId = saved.taskId
        didAutoFill = true
    }

    // MARK: - Formatting

    private var meetingDateString: String {
        return meetingFullDateFormatter.string(from: meeting.start)
    }

    private var meetingTimeRange: String {
        return "\(meetingTimeFormatter.string(from: meeting.start)) – \(meetingTimeFormatter.string(from: meeting.end))"
    }

    /// Build a Date whose hour/minute components encode a duration for the DatePicker.
    private static func durationDate(fromMinutes totalMinutes: Int) -> Date {
        let clamped = min(max(totalMinutes, 0), 23 * 60 + 59)
        let h = clamped / 60
        let m = clamped % 60
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? Date()
    }
}
