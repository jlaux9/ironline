import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header
                    heroLineCard
                    startCard
                    phase1Card
                    refereeStrip
                    firstPlayableRules
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, 10)
                .padding(.bottom, 40)
            }
            .background(Theme.Color.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("IRONLINE")
                    .font(.caption.weight(.black))
                    .tracking(4)
                    .foregroundStyle(Theme.Color.accent)

                Text("Beat expectation.")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(Theme.Color.textPrimary)
            }

            Spacer()

            if appState.isLocalPrototypeMode {
                Text("FIRST PLAYABLE")
                    .font(.caption2.monospaced().weight(.black))
                    .foregroundStyle(Theme.Color.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.Color.gold.opacity(0.12), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var heroLineCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("THE LINE")
                        .font(.caption.weight(.black))
                        .tracking(2.4)
                        .foregroundStyle(Theme.Color.textSecondary)
                    Text("INCLINE DUMBBELL PRESS")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.Color.accent)
                }

                Spacer()

                Image(systemName: "waveform.path.ecg")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.Color.accent)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("70")
                    .font(.system(size: 68, weight: .black, design: .rounded))
                    .monospacedDigit()
                Text("LB")
                    .font(.headline.weight(.black))
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("×")
                    .font(.title.weight(.black))
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("10")
                    .font(.system(size: 50, weight: .black, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 10) {
                metricPill("CAMERA", value: "REFEREE")
                metricPill("SCORING", value: "RELATIVE")
                metricPill("VIDEO", value: "ON DEVICE")
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Theme.Color.surface, Theme.Color.surface.opacity(0.78)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Color.accent)
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.horizontal, 20)
        }
    }

    private var startCard: some View {
        NavigationLink {
            PrototypeWorkoutView()
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "camera.viewfinder")
                        .font(.title.weight(.black))

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.title3.weight(.black))
                }

                Text("START VERIFIED SET")
                    .font(.system(size: 25, weight: .black, design: .rounded))

                Text("Prop the phone side-on. Enter the dumbbell weight. IronLine counts only full-ROM reps and settles the result against THE LINE.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(Theme.Color.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }

    private var phase1Card: some View {
        NavigationLink {
            Phase1DashboardView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.title2.weight(.black))
                    .foregroundStyle(Theme.Color.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text("PHASE 1 REFEREE REPORT")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Agreement gate · false NO REP risk · tracking gaps · game feel")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.black))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            .padding(Theme.Spacing.md)
            .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
    }

    private var refereeStrip: some View {
        HStack(spacing: 0) {
            refereeMetric(icon: "checkmark.seal.fill", title: "VERIFIED", subtitle: "full reps")
            divider
            refereeMetric(icon: "ruler", title: "ROM", subtitle: "measured")
            divider
            refereeMetric(icon: "lock.shield.fill", title: "PRIVATE", subtitle: "no upload")
        }
        .padding(.vertical, 16)
        .background(Theme.Color.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var firstPlayableRules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("THE FIRST TEST")
                .font(.caption.weight(.black))
                .tracking(2)
                .foregroundStyle(Theme.Color.textSecondary)

            ruleRow(number: "01", text: "Start at lockout — roughly 155°+ elbow angle.")
            ruleRow(number: "02", text: "Reach full depth — roughly 100° or less.")
            ruleRow(number: "03", text: "Return to lockout. Shallow attempts get NO REP.")
            ruleRow(number: "04", text: "End the set. Beat or miss THE LINE.")
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Color.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func metricPill(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.Color.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refereeMetric(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.Color.accent)
            Text(title)
                .font(.caption2.weight(.black))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Color.textSecondary.opacity(0.18))
            .frame(width: 1, height: 44)
    }

    private func ruleRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.monospaced().weight(.black))
                .foregroundStyle(Theme.Color.accent)
                .frame(width: 24, alignment: .leading)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }
}
