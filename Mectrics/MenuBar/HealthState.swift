import AppKit
import MetricsKit
import SwiftUI

struct ActiveAlertCondition: Equatable, Identifiable {
    var id: String { conditionKey }
    let conditionKey: String
    let metricID: MetricID
    let state: AlertConditionState
    let severity: AttentionSeverity
    let startedAt: Date
    let measuredValue: Double
    let thresholdValue: Double
    let unit: MetricUnit
    let destinations: Set<AlertDestination>

    init(update: AlertConditionUpdate) {
        conditionKey = update.conditionKey
        metricID = update.metricID
        state = update.state
        severity = Self.severity(for: update)
        startedAt = update.startedAt ?? Date()
        measuredValue = update.measuredValue
        thresholdValue = update.thresholdValue
        unit = update.unit
        destinations = update.destinations
    }

    private static func severity(
        for update: AlertConditionUpdate
    ) -> AttentionSeverity {
        guard update.state == .active else { return .info }
        return AlertConditionSeverity.resolve(update)
    }
}

/// Severity of an alerting condition, shared by the Compact Health item and the
/// Attention Log so one event cannot be a warning in the menu bar and critical in the
/// log. Critical is reserved for a state macOS itself calls its worst.
enum AlertConditionSeverity {
    static func resolve(_ update: AlertConditionUpdate) -> AttentionSeverity {
        switch update.conditionKey {
        // A battery macOS wants serviced is a hardware fault, not a passing spike.
        case SystemAlertSignal.batteryService.conditionKey:
            return .critical
        case SystemAlertSignal.thermalPressure.conditionKey:
            return update.measuredValue
                >= Double(ThermalPressureLevel.critical.rawValue)
                ? .critical
                : .warning
        case SystemAlertSignal.memoryPressure.conditionKey:
            return update.measuredValue
                >= Double(MemoryPressureLevel.critical.rawValue)
                ? .critical
                : .warning
        default:
            return .warning
        }
    }
}

enum HealthState: String, CaseIterable, Equatable {
    case normal
    case pending
    case warning
    case critical
    case stale
    case unavailable

    static func resolve(
        conditions: [ActiveAlertCondition],
        configuredMetricStates: [MetricDataState]
    ) -> Self {
        if conditions.contains(where: { $0.severity == .critical }) {
            return .critical
        }
        if conditions.contains(where: { $0.state == .active }) {
            return .warning
        }
        if conditions.contains(where: { $0.state == .pending }) {
            return .pending
        }
        if configuredMetricStates.contains(.stale) {
            return .stale
        }
        if !configuredMetricStates.isEmpty,
           configuredMetricStates.allSatisfy({
               $0 == .unavailable || $0 == .permissionRequired
           }) {
            return .unavailable
        }
        return .normal
    }

    var symbolName: String {
        switch self {
        case .normal: return "checkmark.shield"
        case .pending: return "clock.badge"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon.fill"
        case .stale: return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .unavailable: return "questionmark.circle"
        }
    }

    var localizedName: String {
        switch self {
        case .normal:
            return String(
                localized: "health.state.normal",
                defaultValue: "All systems normal"
            )
        case .pending:
            return String(
                localized: "health.state.pending",
                defaultValue: "A condition is pending"
            )
        case .warning:
            return String(
                localized: "health.state.warning",
                defaultValue: "Attention recommended"
            )
        case .critical:
            return String(
                localized: "health.state.critical",
                defaultValue: "Critical attention needed"
            )
        case .stale:
            return String(
                localized: "health.state.stale",
                defaultValue: "Some readings are stale"
            )
        case .unavailable:
            return String(
                localized: "health.state.unavailable",
                defaultValue: "Selected readings are unavailable"
            )
        }
    }

    var tint: NSColor {
        switch self {
        case .normal: return .labelColor
        case .pending, .stale: return .systemOrange
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unavailable: return .secondaryLabelColor
        }
    }
}


extension AttentionSeverity {
    var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    var symbolName: String {
        switch self {
        case .info: return "clock"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

extension ActiveAlertCondition {
    /// One line on what is wrong, shared by the Compact Health and dashboard popovers.
    var summary: String {
        switch conditionKey {
        case SystemAlertSignal.thermalPressure.conditionKey:
            return String(
                localized: "health.condition.thermal",
                defaultValue: "CPU and GPU held back to cool down (\(SystemSignalFormat.thermal(measuredValue)))"
            )
        case SystemAlertSignal.memoryPressure.conditionKey:
            return String(
                localized: "health.condition.memoryPressure",
                defaultValue: "Memory pressure is \(SystemSignalFormat.pressure(measuredValue))"
            )
        case SystemAlertSignal.diskAvailableCapacity.conditionKey:
            return String(
                localized: "health.condition.diskCapacity",
                defaultValue: "\(MetricFormat.bytes(measuredValue)) disk space remains"
            )
        case SystemAlertSignal.batteryService.conditionKey:
            return String(
                localized: "health.condition.batteryService",
                defaultValue: "macOS recommends battery service"
            )
        default:
            let value = unit == .celsius
                ? "\(Int(measuredValue.rounded()))°C"
                : "\(Int(measuredValue.rounded()))%"
            return state == .pending
                ? String(
                    localized: "health.condition.pending",
                    defaultValue: "\(value), waiting for sustained duration"
                )
                : String(
                    localized: "health.condition.active",
                    defaultValue: "\(value), threshold crossed"
                )
        }
    }
}
