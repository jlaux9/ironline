import SwiftUI

/// Read-only validation dashboard plus the minimal protocol controls required by
/// `docs/phase1-test-plan.md`: identify Tester A/B and explicitly start a new
/// session. Saved debriefs are stamped with these values automatically.
struct Phase1DashboardView: View {
    @State private var ledger = FirstPlayableTestLedger()
    @State private var testerID = "A"
    @State private var sessionID = UUID()

    private var summary: FirstPlayableTestSummary { ledger.summary }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header
                protocolCard
                gateCard
                diagnosticsCard
                trustCard
                historyCard
                ShareLink(item: shareText) {
                    Label("SHARE PHASE 1 REPORT", systemImage: "square.and.arrow.up")
                        .font(.headline.weight(.black))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.white)
                        .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.button))
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.md)
            .padding(.bottom, 32)
        }
        .background(Theme.Color.background.ignoresSafeArea())
        .navigationTitle("Phase 1 Test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ledger = FirstPlayableTestStore.load()
            testerID = FirstPlayableTestStore.currentTesterID()
            sessionID = FirstPlayableTestStore.currentSessionID()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAMERA TRUST")
                .font(.caption.weight(.black))
                .tracking(2.2)
                .foregroundStyle(Theme.Color.accent)
            Text("Is the referee believable yet?")
                .font(.system(size: 30, weight: .black, design: .rounded))
            Text("Incline dumbbell press only. Real sets decide whether the thresholds are trustworthy enough to move forward.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private var protocolCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("TEST PROTOCOL")
                    .font(.caption.weight(.black))
                    .tracking(1.8)
                    .foregroundStyle(Theme.Color.textSecondary)
                Spacer()
                Text(summary.meetsProtocolCoverageGate ? "COVERAGE PASS" : "IN PROGRESS")
                    .font(.caption2.monospaced().weight(.black))
                    .foregroundStyle(summary.meetsProtocolCoverageGate ? Theme.Color.success : Theme.Color.gold)
            }

            Picker("Active tester", selection: $testerID) {
                Text("TESTER A").tag("A")
                Text("TESTER B").tag("B")
            }
            .pickerStyle(.segmented)
            .onChange(of: testerID) { _, newValue in
                FirstPlayableTestStore.setCurrentTesterID(newValue)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("ACTIVE SESSION")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text(String(sessionID.uuidString.prefix(8)).uppercased())
                        .font(.subheadline.monospaced().weight(.black))
                }
                Spacer()
                Button("START NEW SESSION") {
                    sessionID = FirstPlayableTestStore.startNewSession()
                }
                .font(.caption.weight(.black))
                .buttonStyle(.bordered)
            }

            if summary.testerProgress.isEmpty {
                Text("Protocol target: 2 testers · 5 sets each · at least 2 sessions each.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
            } else {
                ForEach(summary.testerProgress) { progress in
                    HStack {
                        Text("TESTER \(progress.testerID)")
                            .font(.caption.weight(.black))
                        Spacer()
                        Text("\(progress.setCount)/5 SETS · \(progress.sessionCount)/2 SESSIONS")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(progress.meetsCoverageGate ? Theme.Color.success : Theme.Color.textSecondary)
                    }
                }
            }

            if summary.unlabeledSetCount > 0 {
                Text("\(summary.unlabeledSetCount) older set\(summary.unlabeledSetCount == 1 ? "" : "s") predate tester/session tracking and do not count toward protocol coverage.")
                    .font(.caption2)
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var gateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.percent(summary.repCountAgreement))
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(summary.meetsRepAgreementGate ? "PASS" : "NOT YET")
                    .font(.caption.monospaced().weight(.black))
                    .foregroundStyle(summary.meetsRepAgreementGate ? Theme.Color.success : Theme.Color.intensity)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        (summary.meetsRepAgreementGate ? Theme.Color.success : Theme.Color.intensity).opacity(0.12),
                        in: Capsule()
                    )
            }

            Text("REP AGREEMENT · 90% GATE")
                .font(.caption.weight(.black))
                .tracking(1.6)
                .foregroundStyle(Theme.Color.textSecondary)

            HStack(spacing: 10) {
                metric("SETS", value: "\(summary.setCount)")
                metric("HUMAN ATTEMPTS", value: "\(summary.totalHumanAttempts)")
                metric("IRON RESOLVED", value: "\(summary.totalIronResolvedAttempts)")
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("REFEREE DIAGNOSTICS")
                .font(.caption.weight(.black))
                .tracking(1.8)
                .foregroundStyle(Theme.Color.textSecondary)

            diagnosticRow(
                title: "Potential false NO REPs",
                value: summary.potentialFalseNoReps,
                note: "IronLine called more shallow reps than the human observer. Review ROM depth / smoothing first."
            )
            diagnosticRow(
                title: "Missed shallow NO REPs",
                value: summary.missedShallowNoReps,
                note: "The human observer saw shallow attempts that IronLine did not reject. Review bottom threshold / attempt depth."
            )
            diagnosticRow(
                title: "Tracking gaps",
                value: summary.totalTrackingGaps,
                note: "Across \(summary.setsWithTrackingGaps) logged set\(summary.setsWithTrackingGaps == 1 ? "" : "s"). Any gap invalidates the in-flight rep."
            )
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("GAME FEEL")
                .font(.caption.weight(.black))
                .tracking(1.8)
                .foregroundStyle(Theme.Color.textSecondary)

            valueRow("NO-REP TRUST", value: summary.noRepTrustRate.map(Format.percent) ?? "NO DATA")
            valueRow("THE LINE PUSH RATE", value: summary.linePushRate.map(Format.percent) ?? "NO DATA")
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT SETS")
                .font(.caption.weight(.black))
                .tracking(1.8)
                .foregroundStyle(Theme.Color.textSecondary)

            if ledger.records.isEmpty {
                Text("No human-checked sets logged yet.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
            } else {
                ForEach(ledger.records.suffix(8).reversed()) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(Format.number(record.weight)) LB")
                                    .font(.subheadline.monospacedDigit().weight(.black))
                                if let tester = record.testerID {
                                    Text("T\(tester)")
                                        .font(.caption2.monospaced().weight(.black))
                                        .foregroundStyle(Theme.Color.accent)
                                }
                            }
                            Text("IRON \(record.ironVerifiedReps)V / \(record.ironNoReps)NR · HUMAN \(record.humanCompletedReps)V / \(record.humanShallowNoReps)NR")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Text(Format.percent(record.repCountAgreement))
                            .font(.caption.monospacedDigit().weight(.black))
                            .foregroundStyle(record.repCountAgreement >= 0.90 ? Theme.Color.success : Theme.Color.intensity)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(.headline.monospacedDigit().weight(.black))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diagnosticRow(title: String, value: Int, note: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("\(value)")
                    .font(.headline.monospacedDigit().weight(.black))
                    .foregroundStyle(value == 0 ? Theme.Color.success : Theme.Color.intensity)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(Theme.Color.textSecondary)
        }
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(value)
                .font(.headline.monospacedDigit().weight(.black))
        }
    }

    private var shareText: String {
        let progress = summary.testerProgress
            .map { "Tester \($0.testerID): \($0.setCount)/5 sets, \($0.sessionCount)/2 sessions" }
            .joined(separator: "\n")

        return """
        IronLine Phase 1 Referee Report
        Exercise: Incline Dumbbell Press
        Sets logged: \(summary.setCount)
        Rep agreement: \(Format.percent(summary.repCountAgreement))
        90% gate: \(summary.meetsRepAgreementGate ? "PASS" : "NOT YET")
        Protocol coverage: \(summary.meetsProtocolCoverageGate ? "PASS" : "NOT YET")
        \(progress.isEmpty ? "No labeled tester coverage yet" : progress)
        Human attempts: \(summary.totalHumanAttempts)
        IronLine resolved attempts: \(summary.totalIronResolvedAttempts)
        Potential false NO REPs: \(summary.potentialFalseNoReps)
        Missed shallow NO REPs: \(summary.missedShallowNoReps)
        Tracking gaps: \(summary.totalTrackingGaps) across \(summary.setsWithTrackingGaps) sets
        No-rep trust: \(summary.noRepTrustRate.map(Format.percent) ?? "NO DATA")
        THE LINE push rate: \(summary.linePushRate.map(Format.percent) ?? "NO DATA")
        """
    }

}
