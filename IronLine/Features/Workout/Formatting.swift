import Foundation

/// Display formatting shared by the first-playable set report and the Phase 1
/// dashboard. Deliberately tiny: two functions, no protocol, no injection.
/// It exists because these two surfaces quote the same numbers at the tester,
/// and previously each carried its own copy.
enum Format {
    /// Whole numbers print bare, fractions keep one decimal: "70", "72.5".
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// A 0...1 ratio as a whole percent.
    ///
    /// One implementation on purpose. The dashboard and the set report both
    /// print rep agreement, and they previously rounded differently
    /// (`%.0f` rounds half to even, `.rounded()` rounds half away from zero),
    /// so the same underlying value could read 90% on one screen and 91% on
    /// the other.
    ///
    /// Note this rounds to nearest, so a value just under the 0.90 gate can
    /// still display as "90%" beside a "NOT YET" verdict. That is a display
    /// choice, not a gate bug — `meetsRepAgreementGate` compares the raw
    /// Double. See the reconciliation audit before changing it.
    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
