import Foundation
@testable import MetricsKit
import XCTest

final class AlertMonitorTests: XCTestCase {
    func testThresholdMonitorActivatesAndRecoversOnce() {
        let monitor = ThresholdMonitor()
        var updates: [AlertConditionUpdate] = []
        monitor.onConditionUpdate = { updates.append($0) }
        let start = Date(timeIntervalSince1970: 1_000)
        let rule = AlertRule(
            enabled: true,
            thresholdPercent: 80,
            durationSeconds: 30
        )

        monitor.evaluate(
            latest: [.cpu: MetricSample(value: 0.9)],
            rules: [.cpu: rule],
            now: start
        )
        monitor.evaluate(
            latest: [.cpu: MetricSample(value: 0.95)],
            rules: [.cpu: rule],
            now: start.addingTimeInterval(30)
        )
        monitor.evaluate(
            latest: [.cpu: MetricSample(value: 0.4)],
            rules: [.cpu: rule],
            now: start.addingTimeInterval(31)
        )

        XCTAssertEqual(
            updates.map(\.transition),
            [.pending, .activated, .recovered]
        )
    }

    func testConfigurationDecodesSavedAppRules() throws {
        let thresholdData = Data(
            """
            {
              "cpu": {
                "enabled": true,
                "thresholdPercent": 85,
                "durationSeconds": 60,
                "cooldownSeconds": 900,
                "destinations": ["notification", "attentionLog"]
              },
              "unknown": {
                "enabled": true,
                "thresholdPercent": 1,
                "durationSeconds": 0,
                "cooldownSeconds": 0,
                "destinations": []
              }
            }
            """.utf8
        )
        let systemData = Data(
            """
            {
              "diskAvailableCapacity": {
                "enabled": true,
                "thresholdValue": 10737418240,
                "durationSeconds": 30,
                "cooldownSeconds": 900,
                "destinations": ["compactHealth"]
              }
            }
            """.utf8
        )

        let configuration = try AlertConfiguration.decode(
            thresholdData: thresholdData,
            systemData: systemData
        )

        XCTAssertEqual(configuration.enabledRuleCount, 2)
        XCTAssertEqual(configuration.requiredMetricIDs, [.cpu, .disk])
        XCTAssertEqual(configuration.thresholdRules[.cpu]?.thresholdPercent, 85)
        XCTAssertNil(configuration.thresholdRules[.memory])
        XCTAssertEqual(
            configuration.systemRules[.diskAvailableCapacity]?.thresholdValue,
            10 * 1_024 * 1_024 * 1_024
        )
    }

    func testAlertStreamEventUsesStableJSONFields() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let timestamp = Date(timeIntervalSince1970: 1_030)
        let update = AlertConditionUpdate(
            metricID: .battery,
            state: .active,
            transition: .activated,
            measuredValue: 19,
            thresholdValue: 20,
            durationSeconds: 30,
            startedAt: startedAt,
            destinations: [.attentionLog]
        )
        let event = AlertStreamEvent(update: update, timestamp: timestamp)

        XCTAssertEqual(event.schemaVersion, 1)
        XCTAssertEqual(event.condition, "threshold.battery")
        XCTAssertEqual(event.comparison, .atOrBelow)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["event"] as? String, "activated")
        XCTAssertEqual(object["metric"] as? String, "battery")
        XCTAssertEqual(object["unit"] as? String, "percent")
        XCTAssertEqual(object["comparison"] as? String, "atOrBelow")
    }

    func testBatteryServiceEventUsesAboveComparison() {
        let update = AlertConditionUpdate(
            conditionKey: SystemAlertSignal.batteryService.conditionKey,
            metricID: .battery,
            state: .active,
            transition: .activated,
            measuredValue: 1,
            unit: .count,
            thresholdValue: 1,
            durationSeconds: 30,
            startedAt: Date(),
            destinations: [.attentionLog]
        )

        XCTAssertEqual(
            AlertStreamEvent(update: update).comparison,
            .atOrAbove
        )
    }

    func testConfiguredRuleListContainsOnlyEnabledRules() {
        let configuration = AlertConfiguration(
            thresholdRules: [
                .cpu: AlertRule(enabled: true, thresholdPercent: 90),
                .memory: AlertRule(enabled: false, thresholdPercent: 80)
            ],
            systemRules: [
                .diskAvailableCapacity: SystemAlertRule(
                    enabled: true,
                    thresholdValue: 10 * 1_024 * 1_024 * 1_024
                )
            ]
        )

        XCTAssertEqual(
            configuration.configuredRules.map(\.condition),
            ["system.diskAvailableCapacity", "threshold.cpu"]
        )
        XCTAssertEqual(
            configuration.configuredRules.first?.comparison,
            .atOrBelow
        )
    }

    func testOneShotHealthReportChecksCurrentLimits() {
        let configuration = AlertConfiguration(
            thresholdRules: [
                .cpu: AlertRule(enabled: true, thresholdPercent: 90),
                .battery: AlertRule(enabled: true, thresholdPercent: 20)
            ],
            systemRules: [:]
        )

        let report = AlertHealthReport(
            configuration: configuration,
            latest: [
                .cpu: MetricSample(value: 0.95),
                .battery: MetricSample(value: 0.50)
            ]
        )

        XCTAssertEqual(report.status, .attention)
        XCTAssertEqual(
            report.conditions.map(\.state),
            [.normal, .limitCrossed]
        )
    }

    func testOneShotHealthReportDistinguishesUnavailableAndUnconfigured() {
        let configured = AlertConfiguration(
            thresholdRules: [
                .gpu: AlertRule(enabled: true, thresholdPercent: 90)
            ],
            systemRules: [:]
        )

        XCTAssertEqual(
            AlertHealthReport(
                configuration: configured,
                latest: [:]
            ).status,
            .unavailable
        )
        XCTAssertEqual(
            AlertHealthReport(
                configuration: AlertConfiguration(
                    thresholdRules: [:],
                    systemRules: [:]
                ),
                latest: [:]
            ).status,
            .notConfigured
        )
    }

    func testMissingBatteryServiceFlagIsHealthy() {
        let configuration = AlertConfiguration(
            thresholdRules: [:],
            systemRules: [
                .batteryService: SystemAlertRule(
                    enabled: true,
                    thresholdValue: 1
                )
            ]
        )

        let report = AlertHealthReport(
            configuration: configuration,
            latest: [.battery: MetricSample(value: 0.8)]
        )

        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.conditions.first?.measuredValue, 0)
    }

    // MARK: - Native system conditions

    /// The whole point of the state signals: a number crossing a line and the system
    /// actually being in trouble are different questions. Nearly full memory under no
    /// kernel pressure is not a problem, and must not read as one.
    func testMemoryPressureIgnoresHowFullMemoryIs() {
        let configuration = AlertConfiguration(
            thresholdRules: [:],
            systemRules: [
                .memoryPressure: SystemAlertRule(
                    enabled: true,
                    thresholdValue: Double(MemoryPressureLevel.warning.rawValue)
                )
            ]
        )
        let nearlyFull = MetricSample(
            value: 0.96,
            unit: .fraction,
            detail: [
                "pressureLevel": Double(MemoryPressureLevel.normal.rawValue)
            ]
        )

        let relaxed = AlertHealthReport(
            configuration: configuration,
            latest: [.memory: nearlyFull]
        )
        XCTAssertEqual(relaxed.status, .healthy)
        XCTAssertEqual(relaxed.conditions.first?.measuredValue, 1)

        let pressured = AlertHealthReport(
            configuration: configuration,
            latest: [
                .memory: MetricSample(
                    value: 0.62,
                    unit: .fraction,
                    detail: [
                        "pressureLevel":
                            Double(MemoryPressureLevel.warning.rawValue)
                    ]
                )
            ]
        )
        XCTAssertEqual(pressured.status, .attention)
    }

    /// Thermal pressure comes from ProcessInfo, so the report must resolve it with no
    /// sampled provider behind it rather than calling the rule unavailable.
    func testThermalPressureIsCheckableWithoutASampledMetric() {
        let configuration = AlertConfiguration(
            thresholdRules: [:],
            systemRules: [
                .thermalPressure: SystemAlertRule(
                    enabled: true,
                    thresholdValue: Double(ThermalPressureLevel.serious.rawValue)
                )
            ]
        )

        let report = AlertHealthReport(configuration: configuration, latest: [:])
        let condition = try? XCTUnwrap(report.conditions.first)

        XCTAssertNotEqual(condition?.state, .unavailable)
        XCTAssertEqual(
            condition?.measuredValue,
            Double(ThermalPressureLevel.current.rawValue)
        )
        XCTAssertEqual(condition?.comparison, .atOrAbove)
    }

    func testThermalPressureHasNoProviderDependency() {
        let configuration = AlertConfiguration(
            thresholdRules: [:],
            systemRules: [
                .thermalPressure: SystemAlertRule(
                    enabled: true,
                    thresholdValue: Double(ThermalPressureLevel.serious.rawValue)
                )
            ]
        )

        XCTAssertTrue(configuration.requiredMetricIDs.isEmpty)
        XCTAssertNil(SystemAlertSignal.thermalPressure.samplingMetricID)
        XCTAssertEqual(SystemAlertSignal.thermalPressure.metricID, .cpu)
    }

    func testSystemConditionSourceReadsEveryNativeSignal() {
        let readings = SystemConditionSource.readings(
            latest: [
                .memory: MetricSample(
                    value: 0.8,
                    unit: .fraction,
                    detail: ["pressureLevel": 4]
                ),
                .disk: MetricSample(
                    value: 0.5,
                    unit: .fraction,
                    detail: ["free": 1_024]
                ),
                .battery: MetricSample(
                    value: 0.5,
                    unit: .fraction,
                    detail: ["serviceRecommended": 1]
                )
            ],
            thermalLevel: .critical
        )

        XCTAssertEqual(readings[.thermalPressure]?.value, 3)
        XCTAssertEqual(readings[.memoryPressure]?.value, 4)
        XCTAssertEqual(readings[.diskAvailableCapacity]?.value, 1_024)
        XCTAssertEqual(readings[.batteryService]?.value, 1)
    }

    /// A machine that dips into throttling for a moment during a build is working, not
    /// failing. Only a state that *stays* is the cost worth reporting.
    func testThermalPressureAlertsOnlyWhenTheStateIsSustained() {
        var deliveries = 0
        let monitor = SystemConditionMonitor { _, _, _ in deliveries += 1 }
        let start = Date(timeIntervalSince1970: 5_000)
        let rule = SystemAlertRule(
            enabled: true,
            thresholdValue: Double(ThermalPressureLevel.serious.rawValue),
            durationSeconds: 120,
            destinations: [.notification, .attentionLog]
        )

        // A brief excursion followed by recovery must not alert.
        evaluateThermal(monitor, .serious, rule: rule, at: start)
        evaluateThermal(
            monitor,
            .nominal,
            rule: rule,
            at: start.addingTimeInterval(30)
        )
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(monitor.state(for: .thermalPressure), .normal)

        // Staying throttled past the window does.
        evaluateThermal(
            monitor,
            .serious,
            rule: rule,
            at: start.addingTimeInterval(60)
        )
        XCTAssertEqual(monitor.state(for: .thermalPressure), .pending)
        evaluateThermal(
            monitor,
            .critical,
            rule: rule,
            at: start.addingTimeInterval(179)
        )
        XCTAssertEqual(deliveries, 0)
        evaluateThermal(
            monitor,
            .critical,
            rule: rule,
            at: start.addingTimeInterval(181)
        )
        XCTAssertEqual(monitor.state(for: .thermalPressure), .active)
        XCTAssertEqual(deliveries, 1)
    }

    func testMemoryPressureUsesTheKernelsOwnLevelScale() {
        let warningRule = Double(MemoryPressureLevel.warning.rawValue)
        XCTAssertFalse(SystemConditionMonitor.isViolating(
            SystemConditionReading(
                .memoryPressure,
                value: Double(MemoryPressureLevel.normal.rawValue)
            ),
            threshold: warningRule
        ))
        XCTAssertTrue(SystemConditionMonitor.isViolating(
            SystemConditionReading(
                .memoryPressure,
                value: Double(MemoryPressureLevel.critical.rawValue)
            ),
            threshold: warningRule
        ))
        // Critical-only rules must not fire on a warning.
        XCTAssertFalse(SystemConditionMonitor.isViolating(
            SystemConditionReading(.memoryPressure, value: warningRule),
            threshold: Double(MemoryPressureLevel.critical.rawValue)
        ))
    }

    private func evaluateThermal(
        _ monitor: SystemConditionMonitor,
        _ level: ThermalPressureLevel,
        rule: SystemAlertRule,
        at now: Date
    ) {
        monitor.evaluate(
            readings: SystemConditionSource.readings(
                latest: [:],
                thermalLevel: level
            ),
            rules: [.thermalPressure: rule],
            now: now
        )
    }

    func testMetricSnapshotKeepsStableOrderDetailsAndUnavailableModules() {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let report = MetricSnapshotReport(
            latest: [
                .memory: MetricSample(
                    timestamp: timestamp,
                    value: 0.5,
                    detail: ["used": 8_000]
                ),
                .cpu: MetricSample(
                    timestamp: timestamp,
                    value: 0.25,
                    detail: ["coreCount": 8]
                )
            ],
            requested: [.cpu, .memory, .battery],
            timestamp: timestamp
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.metrics.map(\.metric), [.cpu, .memory])
        XCTAssertEqual(report.metrics.first?.detail["coreCount"], 8)
        XCTAssertEqual(report.unavailable, [.battery])
    }
}

// MARK: - Switching a rule off ends its condition

/// A rule switched off while it was alerting must tell everything showing it.
///
/// The monitors reset their own state for a rule that is no longer enabled, but sent no
/// update, and a consumer only learns a condition is over from an update. So the
/// condition stayed on the menu bar and in the dashboard's banner, and its Attention Log
/// event never closed, for a rule the user had switched off.
final class RuleDisabledEndsConditionTests: XCTestCase {
    func testDisablingAnAlertingThresholdRuleEmitsRecovery() {
        let monitor = ThresholdMonitor()
        var updates: [AlertConditionUpdate] = []
        monitor.onConditionUpdate = { updates.append($0) }

        let sample = MetricSample(value: 0.9, unit: .fraction)
        var rule = AlertRule(
            enabled: true,
            thresholdPercent: 70,
            durationSeconds: 0,
            cooldownSeconds: 0,
            destinations: [.compactHealth, .attentionLog]
        )
        monitor.evaluate(latest: [.memory: sample], rules: [.memory: rule])
        XCTAssertEqual(monitor.state(for: .memory), .active)

        updates.removeAll()
        rule.enabled = false
        // The reading is still above the threshold: only the rule changed.
        monitor.evaluate(latest: [.memory: sample], rules: [.memory: rule])

        XCTAssertEqual(monitor.state(for: .memory), .normal)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.state, .normal)
        XCTAssertEqual(updates.first?.transition, .recovered)
        XCTAssertEqual(updates.first?.metricID, .memory)
    }

    /// And says it once, not on every cycle afterwards.
    func testADisabledRuleIsAnnouncedOnceNotEveryCycle() {
        let monitor = ThresholdMonitor()
        var updates: [AlertConditionUpdate] = []
        monitor.onConditionUpdate = { updates.append($0) }

        let sample = MetricSample(value: 0.9, unit: .fraction)
        var rule = AlertRule(
            enabled: true,
            thresholdPercent: 70,
            durationSeconds: 0,
            cooldownSeconds: 0
        )
        monitor.evaluate(latest: [.memory: sample], rules: [.memory: rule])
        rule.enabled = false
        updates.removeAll()
        for _ in 0..<5 {
            monitor.evaluate(latest: [.memory: sample], rules: [.memory: rule])
        }
        XCTAssertEqual(updates.count, 1)
    }

    func testDisablingAnAlertingSystemRuleEmitsRecovery() {
        let monitor = SystemConditionMonitor()
        var updates: [AlertConditionUpdate] = []
        monitor.onConditionUpdate = { updates.append($0) }

        let reading = SystemConditionReading(
            .memoryPressure,
            value: Double(MemoryPressureLevel.critical.rawValue)
        )
        var rule = SystemAlertRule(
            enabled: true,
            thresholdValue: Double(MemoryPressureLevel.warning.rawValue),
            durationSeconds: 0,
            cooldownSeconds: 0
        )
        monitor.evaluate(readings: [.memoryPressure: reading], rules: [.memoryPressure: rule])
        XCTAssertEqual(monitor.state(for: .memoryPressure), .active)

        updates.removeAll()
        rule.enabled = false
        monitor.evaluate(readings: [.memoryPressure: reading], rules: [.memoryPressure: rule])

        XCTAssertEqual(monitor.state(for: .memoryPressure), .normal)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.transition, .recovered)
        XCTAssertEqual(updates.first?.conditionKey, SystemAlertSignal.memoryPressure.conditionKey)
    }

    /// A signal whose reading disappears must stop claiming the Mac is unwell.
    func testASignalThatCanNoLongerBeReadEndsItsCondition() {
        let monitor = SystemConditionMonitor()
        var updates: [AlertConditionUpdate] = []
        monitor.onConditionUpdate = { updates.append($0) }

        let rule = SystemAlertRule(
            enabled: true,
            thresholdValue: Double(MemoryPressureLevel.warning.rawValue),
            durationSeconds: 0,
            cooldownSeconds: 0
        )
        monitor.evaluate(
            readings: [.memoryPressure: SystemConditionReading(
                .memoryPressure,
                value: Double(MemoryPressureLevel.critical.rawValue)
            )],
            rules: [.memoryPressure: rule]
        )
        XCTAssertEqual(monitor.state(for: .memoryPressure), .active)

        updates.removeAll()
        monitor.evaluate(readings: [:], rules: [.memoryPressure: rule])

        XCTAssertEqual(monitor.state(for: .memoryPressure), .normal)
        XCTAssertEqual(updates.first?.transition, .recovered)
    }
}
