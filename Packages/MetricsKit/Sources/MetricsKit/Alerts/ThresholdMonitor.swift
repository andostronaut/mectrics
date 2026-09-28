import Foundation

/// Evaluates metric threshold rules as a small incident state machine.
public final class ThresholdMonitor {
    public typealias NotificationHandler = (MetricID, AlertRule, Int) -> Void

    public var onConditionUpdate: ((AlertConditionUpdate) -> Void)?

    private var lastFired: [MetricID: Date] = [:]
    private var violationStartedAt: [MetricID: Date] = [:]
    private var states: [MetricID: AlertConditionState] = [:]
    private let notificationHandler: NotificationHandler

    public init(
        notificationHandler: @escaping NotificationHandler = { _, _, _ in }
    ) {
        self.notificationHandler = notificationHandler
    }

    public func state(for metricID: MetricID) -> AlertConditionState {
        states[metricID] ?? .normal
    }

    public func evaluate(
        latest: [MetricID: MetricSample],
        rules: [MetricID: AlertRule],
        now: Date = Date()
    ) {
        for (id, rule) in rules where rule.enabled {
            guard let sample = latest[id] else { continue }
            let measured = sample.unit == .celsius ? sample.value : sample.value * 100
            let violating = Self.isBelowRule(id)
                ? measured <= Double(rule.thresholdPercent)
                : measured >= Double(rule.thresholdPercent)

            guard violating else {
                recoverIfNeeded(
                    metricID: id,
                    measured: measured,
                    rule: rule,
                    destinations: rule.destinations
                )
                continue
            }

            let startedAt = violationStartedAt[id] ?? now
            if violationStartedAt[id] == nil {
                violationStartedAt[id] = startedAt
                setState(
                    .pending,
                    transition: .pending,
                    metricID: id,
                    measured: measured,
                    rule: rule,
                    startedAt: startedAt,
                    destinations: rule.destinations
                )
            }

            guard now.timeIntervalSince(startedAt) >= Double(rule.durationSeconds),
                  state(for: id) != .active,
                  now.timeIntervalSince(lastFired[id] ?? .distantPast)
                    >= Double(rule.cooldownSeconds)
            else { continue }

            lastFired[id] = now
            setState(
                .active,
                transition: .activated,
                metricID: id,
                measured: measured,
                rule: rule,
                startedAt: startedAt,
                destinations: rule.destinations
            )
            if rule.destinations.contains(.notification) {
                notificationHandler(id, rule, Int(measured.rounded()))
            }
        }

        let enabledIDs = Set(rules.compactMap { $0.value.enabled ? $0.key : nil })
        for id in Set(states.keys).subtracting(enabledIDs) {
            stopWatching(id, rule: rules[id], latest: latest)
        }
    }

    /// A rule that is no longer enabled stops being a condition, and everything showing
    /// it has to be told.
    ///
    /// Resetting only this object's own state was not enough: a consumer learns a
    /// condition is over from an update, so with none sent, a rule switched off while it
    /// was alerting left its condition on every surface that had been told about it —
    /// the menu bar, the dashboard's banner, and an Attention Log event that never
    /// closed. The transition is `.recovered` because that is what it means to every
    /// consumer: this condition is no longer active. It is the same wording a rule gets
    /// when its threshold is raised past the current value.
    private func stopWatching(
        _ id: MetricID,
        rule: AlertRule?,
        latest: [MetricID: MetricSample]
    ) {
        let priorState = state(for: id)
        let startedAt = violationStartedAt[id]
        violationStartedAt[id] = nil
        states[id] = .normal
        guard priorState != .normal else { return }
        let sample = latest[id]
        let measured = sample.map {
            $0.unit == .celsius ? $0.value : $0.value * 100
        } ?? 0
        onConditionUpdate?(AlertConditionUpdate(
            metricID: id,
            state: .normal,
            transition: .recovered,
            measuredValue: measured,
            thresholdValue: Double(rule?.thresholdPercent ?? 0),
            durationSeconds: rule?.durationSeconds ?? 0,
            startedAt: startedAt,
            destinations: rule?.destinations ?? []
        ))
    }

    /// Battery alerts below its threshold; all other metric rules alert above it.
    public static func isBelowRule(_ id: MetricID) -> Bool { id == .battery }

    private func recoverIfNeeded(
        metricID: MetricID,
        measured: Double,
        rule: AlertRule,
        destinations: Set<AlertDestination>
    ) {
        let priorState = state(for: metricID)
        let startedAt = violationStartedAt[metricID]
        violationStartedAt[metricID] = nil
        states[metricID] = .normal
        guard priorState != .normal else { return }
        onConditionUpdate?(AlertConditionUpdate(
            metricID: metricID,
            state: .normal,
            transition: .recovered,
            measuredValue: measured,
            thresholdValue: Double(rule.thresholdPercent),
            durationSeconds: rule.durationSeconds,
            startedAt: startedAt,
            destinations: destinations
        ))
    }

    private func setState(
        _ state: AlertConditionState,
        transition: AlertConditionTransition,
        metricID: MetricID,
        measured: Double,
        rule: AlertRule,
        startedAt: Date?,
        destinations: Set<AlertDestination>
    ) {
        states[metricID] = state
        onConditionUpdate?(AlertConditionUpdate(
            metricID: metricID,
            state: state,
            transition: transition,
            measuredValue: measured,
            thresholdValue: Double(rule.thresholdPercent),
            durationSeconds: rule.durationSeconds,
            startedAt: startedAt,
            destinations: destinations
        ))
    }
}
