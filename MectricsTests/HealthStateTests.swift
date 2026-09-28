import MetricsKit
import XCTest
@testable import Mectrics

final class HealthStateTests: XCTestCase {
    func testEveryHealthFixtureResolvesDeterministically() {
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [],
                configuredMetricStates: []
            ),
            .normal
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [condition(state: .pending)],
                configuredMetricStates: [.live]
            ),
            .pending
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [condition(state: .active)],
                configuredMetricStates: [.live]
            ),
            .warning
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [
                    condition(
                        state: .active,
                        conditionKey:
                            SystemAlertSignal.batteryService.conditionKey,
                        measured: 1
                    )
                ],
                configuredMetricStates: [.live]
            ),
            .critical
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [],
                configuredMetricStates: [.stale, .live]
            ),
            .stale
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [],
                configuredMetricStates: [.unavailable]
            ),
            .unavailable
        )
    }

    func testSeverityOutranksRecencyAndPending() {
        let warning = condition(
            state: .active,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let recentPending = condition(
            state: .pending,
            startedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            HealthState.resolve(
                conditions: [recentPending, warning],
                configuredMetricStates: [.live]
            ),
            .warning
        )
    }

    /// Severity separates "the Mac is working hard" from "macOS says this is as bad
    /// as it gets", so the menu bar's red state stays worth looking at.
    func testWorstNativeStatesAreCriticalAndLesserOnesAreNot() {
        XCTAssertEqual(
            severity(
                SystemAlertSignal.thermalPressure.conditionKey,
                measured: Double(ThermalPressureLevel.serious.rawValue)
            ),
            .warning
        )
        XCTAssertEqual(
            severity(
                SystemAlertSignal.thermalPressure.conditionKey,
                measured: Double(ThermalPressureLevel.critical.rawValue)
            ),
            .critical
        )
        XCTAssertEqual(
            severity(
                SystemAlertSignal.memoryPressure.conditionKey,
                measured: Double(MemoryPressureLevel.warning.rawValue)
            ),
            .warning
        )
        XCTAssertEqual(
            severity(
                SystemAlertSignal.memoryPressure.conditionKey,
                measured: Double(MemoryPressureLevel.critical.rawValue)
            ),
            .critical
        )
    }

    /// The Compact Health item and the Attention Log must never disagree about how
    /// serious one event was.
    func testHealthAndAttentionLogAgreeOnSeverity() {
        for key in [
            SystemAlertSignal.thermalPressure.conditionKey,
            SystemAlertSignal.memoryPressure.conditionKey,
            SystemAlertSignal.batteryService.conditionKey,
            "threshold.cpu"
        ] {
            for measured in [0.0, 1, 2, 3, 4] {
                let update = update(key, measured: measured)
                XCTAssertEqual(
                    ActiveAlertCondition(update: update).severity,
                    AlertConditionSeverity.resolve(update),
                    "\(key) at \(measured)"
                )
            }
        }
    }

    @MainActor
    func testMenuBarSlotHasOneInvariantLength() {
        XCTAssertEqual(MectricsStatusItem.fixedLength, 26)
        XCTAssertTrue(
            Set(HealthState.allCases.map { _ in
                MectricsStatusItem.fixedLength
            }).count == 1
        )
    }

    // MARK: - Helpers

    private func severity(
        _ conditionKey: String,
        measured: Double
    ) -> AttentionSeverity {
        ActiveAlertCondition(
            update: update(conditionKey, measured: measured)
        ).severity
    }

    private func update(
        _ conditionKey: String,
        measured: Double
    ) -> AlertConditionUpdate {
        AlertConditionUpdate(
            conditionKey: conditionKey,
            metricID: .cpu,
            state: .active,
            transition: .activated,
            measuredValue: measured,
            unit: .count,
            thresholdValue: 1,
            durationSeconds: 30,
            startedAt: Date(timeIntervalSince1970: 1),
            destinations: [.compactHealth, .attentionLog]
        )
    }

    private func condition(
        state: AlertConditionState,
        conditionKey: String = "threshold.cpu",
        measured: Double = 95,
        startedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> ActiveAlertCondition {
        ActiveAlertCondition(update: AlertConditionUpdate(
            conditionKey: conditionKey,
            metricID: .cpu,
            state: state,
            transition: state == .active ? .activated : .pending,
            measuredValue: measured,
            thresholdValue: 90,
            durationSeconds: 30,
            startedAt: startedAt,
            destinations: [.compactHealth]
        ))
    }
}
