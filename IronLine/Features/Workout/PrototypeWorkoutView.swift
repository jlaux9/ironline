import Foundation
import SwiftUI

/// First playable vertical slice:
/// manual weight + camera-verified reps + personalized target + beat/miss result.
///
/// This deliberately proves the core game feel before Duels, Crews, Ghosts,
/// physique scanning, or automatic weight recognition are allowed into scope.
struct PrototypeWorkoutView: View {
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var camera = CameraManager()

    @State private var weight = 70.0
    @State private var line = PerformanceLine(weight: 70, reps: 10)
    @State private var result: LineResult?
    @State private var countdown: Int?

    @State private var completedWeight = 70.0
    @State private var completedVerifiedReps = 0
    @State private var completedAttempts = 0
    @State private var completedNoReps = 0
    @State private var completedTrackingGaps = 0

    @State private var showingDebrief = false
    @State private var humanCompletedReps = 0
    @State private var humanShallowReps = 0
    @State private var agreesWithNoRepCalls: Bool?
    @State private var lineMadeMePushHarder: Bool?
    @State private var testLedger = FirstPlayableTestLedger()
    @State private var currentTestRecordID: UUID?

    @State private var workoutSessionID: UUID?
    @State private var exerciseID: UUID?
    @State private var setNumber = 1
    @State private var setStartedAt: Date?
    @State private var backendStatus = "CONNECTING"

    var body: some View {
        ZStack {
            Theme.Color.background.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                .opacity(0.58)

            LinearGradient(
                colors: [.clear, Theme.Color.background.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                trackingHUD
                Spacer()
                controls
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.md)
        }
        .navigationBarBackButtonHidden(false)
        .sheet(isPresented: $showingDebrief) {
            testDebrief
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            testLedger = FirstPlayableTestStore.load()
            camera.prepareAndStart()
            await prepareBackend()
        }
        .onDisappear {
            camera.stop()
            Task { await finishBackendSession() }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("THE LINE")
                .font(.caption.weight(.black))
                .tracking(3)
                .foregroundStyle(Theme.Color.textSecondary)

            Text("\(Format.number(line.weight)) × \(line.reps)")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Text("INCLINE DUMBBELL PRESS")
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(Theme.Color.accent)

            Text(backendStatus)
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var trackingHUD: some View {
        VStack(spacing: 14) {
            Text("\(camera.repsCompleted)")
                .font(.system(size: 112, weight: .black, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            ProgressView(value: camera.romProgress)
                .tint(camera.romProgress >= 0.98 ? Theme.Color.success : Theme.Color.accent)
                .frame(maxWidth: 260)

            Text(feedbackText)
                .font(.headline.weight(.black))
                .foregroundStyle(feedbackColor)
                .multilineTextAlignment(.center)
                .frame(minHeight: 24)

            HStack(spacing: 14) {
                if let angle = camera.elbowAngle {
                    telemetryLabel("ELBOW", value: "\(Int(angle.rounded()))°")
                }
                telemetryLabel("NO REPS", value: "\(camera.noRepCount)")
                telemetryLabel("TRACK GAPS", value: "\(camera.trackingLossCount)")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if let result {
                resultCard(result)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WEIGHT")
                        .font(.caption2.weight(.black))
                        .tracking(1.5)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("\(Format.number(weight)) LB")
                        .font(.title2.monospacedDigit().weight(.black))
                }

                Spacer()

                Stepper("", value: $weight, in: 5...250, step: 5)
                    .labelsHidden()
                    .disabled(camera.isSetActive || countdown != nil)
            }
            .padding(14)
            .background(Theme.Color.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.card))

            Button(action: toggleSet) {
                Text(primaryButtonTitle)
                    .font(.headline.weight(.black))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(camera.isSetActive ? Theme.Color.intensity : Theme.Color.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            }
            .disabled(countdown != nil || (!camera.isSetActive && !cameraReadyToStart))
        }
    }

    private func resultCard(_ result: LineResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.beatLine ? "LINE BEATEN" : "LINE MISSED")
                        .font(.headline.weight(.black))
                    Text(String(format: "%+.1f%% VS EXPECTATION", result.scorePercent))
                        .font(.caption.monospacedDigit().weight(.bold))
                }
                Spacer()
                Image(systemName: result.beatLine ? "arrow.up.right" : "arrow.down.right")
                    .font(.title.weight(.black))
            }

            HStack(spacing: 12) {
                resultMetric("VERIFIED", value: "\(completedVerifiedReps)")
                resultMetric("NO REPS", value: "\(completedNoReps)")
                resultMetric("TRACK GAPS", value: "\(completedTrackingGaps)")
            }

            HStack(spacing: 16) {
                Button {
                    showingDebrief = true
                } label: {
                    Label(currentTestRecordID == nil ? "LOG HUMAN CHECK" : "EDIT HUMAN CHECK", systemImage: "person.badge.shield.checkmark")
                        .font(.caption.weight(.black))
                }

                ShareLink(item: setReportText(result)) {
                    Label("SHARE", systemImage: "square.and.arrow.up")
                        .font(.caption.weight(.black))
                }
            }
            .foregroundStyle(Theme.Color.textPrimary)
        }
        .foregroundStyle(result.beatLine ? Theme.Color.success : Theme.Color.intensity)
        .padding(14)
        .background(Theme.Color.surface.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var testDebrief: some View {
        NavigationStack {
            Form {
                Section("HUMAN OBSERVER") {
                    Stepper("Completed reps: \(humanCompletedReps)", value: $humanCompletedReps, in: 0...100)
                    Stepper("Shallow / no-reps: \(humanShallowReps)", value: $humanShallowReps, in: 0...100)
                }

                Section("TRUST") {
                    debriefChoice(
                        title: "Did you agree with every NO REP call?",
                        selection: $agreesWithNoRepCalls
                    )

                    debriefChoice(
                        title: "Did THE LINE make you push harder?",
                        selection: $lineMadeMePushHarder
                    )
                }

                Section("IRONLINE REFEREE") {
                    LabeledContent("Verified reps", value: "\(completedVerifiedReps)")
                    LabeledContent("No-reps", value: "\(completedNoReps)")
                    LabeledContent("Tracking gaps", value: "\(completedTrackingGaps)")
                    LabeledContent("Rep-count delta", value: signed(completedVerifiedReps - humanCompletedReps))
                }

                Section("PHASE 1 LEDGER") {
                    LabeledContent("Sets logged", value: "\(testLedger.summary.setCount)")
                    LabeledContent("Rep agreement", value: Format.percent(testLedger.summary.repCountAgreement))
                    LabeledContent(
                        "90% gate",
                        value: testLedger.summary.meetsRepAgreementGate ? "PASS" : "NOT YET"
                    )
                    if let trust = testLedger.summary.noRepTrustRate {
                        LabeledContent("No-rep trust", value: Format.percent(trust))
                    }
                    if let push = testLedger.summary.linePushRate {
                        LabeledContent("LINE push rate", value: Format.percent(push))
                    }
                }

                Section {
                    ShareLink(item: setReportText(result)) {
                        Label("SHARE COMPLETE TEST SNAPSHOT", systemImage: "square.and.arrow.up")
                            .font(.headline.weight(.bold))
                    }
                }
            }
            .navigationTitle("Set Debrief")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCurrentTestRecord()
                        showingDebrief = false
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private func debriefChoice(title: String, selection: Binding<Bool?>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            Picker(title, selection: selection) {
                Text("NOT LOGGED").tag(Bool?.none)
                Text("YES").tag(Bool?.some(true))
                Text("NO").tag(Bool?.some(false))
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 4)
    }

    private func telemetryLabel(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .font(.caption2.monospacedDigit().weight(.bold))
    }

    private func resultMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.black))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setReportText(_ result: LineResult?) -> String {
        let outcome: String
        let score: String
        if let result {
            outcome = result.beatLine ? "LINE BEATEN" : "LINE MISSED"
            score = String(format: "%+.1f%%", result.scorePercent)
        } else {
            outcome = "NOT SCORED"
            score = "N/A"
        }

        let summary = testLedger.summary

        return """
        IronLine First Playable Test
        Exercise: Incline Dumbbell Press
        Weight: \(Format.number(completedWeight)) lb
        IronLine verified reps: \(completedVerifiedReps)
        IronLine no-reps: \(completedNoReps)
        Attempts resolved: \(completedAttempts)
        Tracking gaps: \(completedTrackingGaps)
        Human completed reps: \(humanCompletedReps)
        Human shallow/no-reps: \(humanShallowReps)
        Rep-count delta (IronLine - human): \(signed(completedVerifiedReps - humanCompletedReps))
        Agreed with every no-rep call: \(yesNo(agreesWithNoRepCalls))
        THE LINE made me push harder: \(yesNo(lineMadeMePushHarder))
        THE LINE: \(Format.number(line.weight)) × \(line.reps)
        Result: \(outcome) (\(score))
        Phase 1 sets logged: \(summary.setCount)
        Phase 1 rep agreement: \(Format.percent(summary.repCountAgreement))
        Phase 1 90% gate: \(summary.meetsRepAgreementGate ? "PASS" : "NOT YET")
        """
    }

    private var feedbackText: String {
        switch camera.trackingState {
        case .trackingLost:
            return camera.isSetActive ? "TRACKING LOST — RESET AT TOP" : "STEP INTO FRAME"
        case .requestingPermission:
            return "REQUESTING CAMERA"
        case .denied:
            return "CAMERA ACCESS REQUIRED"
        case .failed(let message):
            return message.uppercased()
        default:
            break
        }

        if let last = camera.lastFeedback { return last }

        switch camera.trackingState {
        case .tracking:
            return camera.isSetActive ? "VERIFYING" : "READY — HOLD POSITION"
        case .ready:
            return "STEP INTO FRAME"
        default:
            return "POSITION PHONE SIDE-ON"
        }
    }

    private var feedbackColor: Color {
        switch camera.trackingState {
        case .trackingLost, .denied, .failed:
            return Theme.Color.intensity
        default:
            break
        }

        guard let feedback = camera.lastFeedback else { return Theme.Color.textSecondary }
        return feedback.hasPrefix("NO REP") ? Theme.Color.intensity : Theme.Color.success
    }

    private var primaryButtonTitle: String {
        if let countdown { return "STARTING IN \(countdown)" }
        if camera.isSetActive { return "END SET" }
        return cameraReadyToStart ? "START VERIFIED SET" : "GET IN FRAME TO START"
    }

    private var cameraReadyToStart: Bool {
        if case .tracking = camera.trackingState {
            return true
        }
        return false
    }

    private func toggleSet() {
        if camera.isSetActive {
            camera.endSet()
            let endedAt = Date()
            let startedAt = setStartedAt ?? endedAt

            completedWeight = weight
            completedVerifiedReps = camera.repsCompleted
            completedAttempts = camera.repsAttempted
            completedNoReps = camera.noRepCount
            completedTrackingGaps = camera.trackingLossCount

            humanCompletedReps = completedVerifiedReps
            humanShallowReps = completedNoReps
            agreesWithNoRepCalls = nil
            lineMadeMePushHarder = nil
            currentTestRecordID = nil

            result = LineScoring.score(
                actualWeight: completedWeight,
                actualReps: completedVerifiedReps,
                against: line
            )

            Task {
                await persistSet(
                    weight: completedWeight,
                    repsCompleted: completedVerifiedReps,
                    repsAttempted: completedAttempts,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            }
            return
        }

        result = nil
        Task { @MainActor in
            for value in stride(from: 3, through: 1, by: -1) {
                guard cameraReadyToStart else {
                    countdown = nil
                    return
                }

                countdown = value
                try? await Task.sleep(for: .seconds(1))
            }

            guard cameraReadyToStart else {
                countdown = nil
                return
            }

            countdown = nil
            setStartedAt = Date()
            camera.beginSet()
        }
    }

    private func saveCurrentTestRecord() {
        guard let result else { return }

        let recordID = currentTestRecordID ?? UUID()
        let record = FirstPlayableSetRecord(
            id: recordID,
            weight: completedWeight,
            ironVerifiedReps: completedVerifiedReps,
            ironNoReps: completedNoReps,
            ironTrackingGaps: completedTrackingGaps,
            humanCompletedReps: humanCompletedReps,
            humanShallowNoReps: humanShallowReps,
            agreedWithEveryNoRepCall: agreesWithNoRepCalls,
            lineMadeUserPushHarder: lineMadeMePushHarder,
            lineScorePercent: result.scorePercent
        )

        testLedger.replace(record)
        FirstPlayableTestStore.save(testLedger)
        currentTestRecordID = recordID
    }

    @MainActor
    private func prepareBackend() async {
        guard let userID = authManager.session?.user.id else {
            backendStatus = "LOCAL MODE · NO SESSION"
            return
        }

        do {
            let resolvedExerciseID = try await WorkoutService.exerciseID(named: "Incline Dumbbell Press")
            let resolvedSessionID = try await WorkoutService.startSession(userID: userID)

            exerciseID = resolvedExerciseID
            workoutSessionID = resolvedSessionID

            let envelope = try await WorkoutService.getLine(exerciseID: resolvedExerciseID)
            if let activeLine = envelope.line {
                line = activeLine.performanceLine
                backendStatus = "LINE V\(activeLine.version) · \(Int((activeLine.confidence * 100).rounded()))% CONF"
            } else if envelope.baseline == true {
                backendStatus = "BUILDING LINE · \(envelope.sessionsRemaining ?? 0) SESSIONS"
            } else {
                backendStatus = "PROTOTYPE LINE"
            }
        } catch {
            backendStatus = "LOCAL MODE · \(error.localizedDescription.uppercased())"
        }
    }

    @MainActor
    private func persistSet(
        weight: Double,
        repsCompleted: Int,
        repsAttempted: Int,
        startedAt: Date,
        endedAt: Date
    ) async {
        guard let workoutSessionID, let exerciseID else {
            backendStatus = "LOCAL RESULT · NOT SYNCED"
            return
        }

        backendStatus = "SYNCING VERIFIED SET"

        do {
            let saved = try await WorkoutService.saveVerifiedSet(
                sessionID: workoutSessionID,
                exerciseID: exerciseID,
                setNumber: setNumber,
                weight: weight,
                repsCompleted: repsCompleted,
                repsAttempted: repsAttempted,
                startedAt: startedAt,
                endedAt: endedAt
            )
            backendStatus = saved.isPR ? "VERIFIED PR · SYNCED" : "VERIFIED · SYNCED"
            setNumber += 1
        } catch {
            backendStatus = "SAVE FAILED · LOCAL RESULT KEPT"
        }
    }

    @MainActor
    private func finishBackendSession() async {
        guard let workoutSessionID else { return }

        do {
            try await WorkoutService.completeSession(id: workoutSessionID)
            if let exerciseID {
                _ = try await WorkoutService.recalculateLine(exerciseID: exerciseID)
            }
        } catch {
            // Leaving the screen must never block on a network cleanup failure.
        }
    }

    private func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func yesNo(_ value: Bool?) -> String {
        guard let value else { return "Not logged" }
        return value ? "Yes" : "No"
    }
}
