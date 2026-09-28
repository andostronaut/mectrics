import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import MetricsKit

/// Bridge between the UI and the MetricsKit engine. `@Observable` → SwiftUI views update
/// automatically as `latest` changes.
@Observable
@MainActor
final class AppModel {
    let engine: MetricsEngine
    let attentionLog = AttentionLogStore()

    /// Core modules available on this machine (e.g. no battery on a desktop).
    let availableModules: [MetricID]
    private let availableMetricIDs: Set<MetricID>

    /// The latest sample per module (read by the menu bar + popover).
    var latest: [MetricID: MetricSample] = [:]

    /// Whether the battery, not the adapter, is powering the Mac: the system's
    /// providing power source, which the battery's charging flag cannot tell apart
    /// from a Mac held at its charge limit. AppDelegate reads it at launch and again
    /// on every power-source notification, so no view has to; nil until then.
    var isOnBattery: Bool?

    /// Consecutive provider attempts that returned no sample. Short interruptions keep
    /// the last valid value; repeated failures become an explicit error state.
    private(set) var consecutiveSamplingFailures: [MetricID: Int] = [:]
    private var onboardingPreviewActive = false
    private var builderPreviewActive = false

    /// Enabled menu bar items: per module, which components are shown. A module may
    /// contribute several items at once (e.g. Battery icon + Battery health).
    ///
    /// The single-icon style never edits this, so switching back to separate items
    /// restores exactly the layout that was there before.
    var enabledComponents: [MetricID: Set<MenuBarComponent>] {
        didSet {
            persistEnabledComponents()
            resetFailuresForNewlyWatchedModules(
                previouslyWatched: MenuBarPlacement.watchedModules(
                    available: availableModules,
                    enabledComponents: oldValue,
                    groupedModules: groupedModules
                )
            )
            refreshActiveMetrics()
            // Only when the menu bar's list of items actually changes. A grouped module
            // shows a card and no items, so editing its components — which taking it off
            // the dashboard does — changes nothing in the menu bar, and rebuilding for it
            // tore down every status item and closed the open dashboard with them.
            if menuBarItemKeys(for: oldValue) != menuBarItemKeys {
                onModulesChanged?()
            }
        }
    }

    /// Modules shown as a card in the Dashboard's dashboard rather than as items of
    /// their own. Kept apart from `enabledComponents` so a module moving between the two
    /// never destroys the components it had.
    var groupedModules: Set<MetricID> {
        didSet {
            defaults.set(
                groupedModules.map(\.rawValue).sorted(),
                forKey: Self.groupedModulesKey
            )
            guard groupedModules != oldValue else { return }
            let hadItem = Self.showsDashboardItem(
                grouped: oldValue,
                keptWhenEmpty: dashboardItemEnabled
            )
            resetFailuresForNewlyWatchedModules(
                previouslyWatched: MenuBarPlacement.watchedModules(
                    available: availableModules,
                    enabledComponents: enabledComponents,
                    groupedModules: oldValue
                )
            )
            refreshActiveMetrics()
            // The first card can bring the item back and the last can take it away, if
            // it is not being kept while empty. Otherwise the watched set changed and no
            // status item did, which is the lighter of the two notifications.
            if hadItem == showsDashboardItem {
                onWatchedModulesChanged?()
            } else {
                onModulesChanged?()
            }
        }
    }

    /// Modules the app watches: with at least one component in the menu bar, or with
    /// a card in the dashboard under the single icon. Sampling, widgets, summaries, and
    /// the popovers all scope to this.
    var enabledModules: Set<MetricID> {
        MenuBarPlacement.watchedModules(
            available: availableModules,
            enabledComponents: enabledComponents,
            groupedModules: groupedModules
        )
    }

    /// A module that starts being watched begins with a clean failure count, so an
    /// error from before it was switched off does not greet it on its way back.
    private func resetFailuresForNewlyWatchedModules(
        previouslyWatched: Set<MetricID>
    ) {
        for id in enabledModules.subtracting(previouslyWatched) {
            consecutiveSamplingFailures[id] = 0
        }
    }

    /// Menu bar items in display order: module order, then the component order
    /// defined by `MenuBarComponent.available(for:)`.
    var orderedEnabledItems: [(module: MetricID, component: MenuBarComponent)] {
        availableModules
            // A grouped module keeps its components for when it comes back, but it is
            // showing a card right now, not items.
            .filter { !groupedModules.contains($0) }
            .flatMap { id in
                availableComponents(for: id)
                    .filter { enabledComponents[id]?.contains($0) ?? false }
                    .map { (id, $0) }
            }
    }

    /// Called when the menu bar's list of status items changes, so it can be rebuilt
    /// (wired by AppDelegate).
    @ObservationIgnored var onModulesChanged: (() -> Void)?

    /// Called when the watched modules change without any status item changing — a
    /// dashboard module turned on or off under the single icon. Lighter than
    /// `onModulesChanged`: nothing in the menu bar is torn down (wired by AppDelegate).
    @ObservationIgnored var onWatchedModulesChanged: (() -> Void)?

    /// Called when a view asks for the settings window (wired by AppDelegate).
    @ObservationIgnored var onOpenSettings: (() -> Void)?

    /// Opens Settings on the Menu Bar pane, where the dashboard's modules are chosen
    /// (wired by AppDelegate).
    @ObservationIgnored var onOpenMenuBarSettings: (() -> Void)?

    /// Called by the Help menu to present the optional onboarding again.
    @ObservationIgnored var onOpenOnboarding: (() -> Void)?

    /// Opens the bounded local event history.
    @ObservationIgnored var onOpenAttentionLog: (() -> Void)?

    /// Opens the previewable, local-only diagnostics export.
    @ObservationIgnored var onOpenDiagnostics: (() -> Void)?

    /// Runs Sparkle's signature-verifying update check.
    @ObservationIgnored var onCheckForUpdates: (() -> Void)?

    /// Opens a persistent metric detail window from shared attention surfaces.
    @ObservationIgnored var onOpenMetricDetail: ((MetricID) -> Void)?

    @ObservationIgnored var onEnergyGuardPreferenceChanged: (() -> Void)?

    /// One-shot flag for the current onboarding experience. Versioning lets a
    /// substantially redesigned welcome appear once for existing users without
    /// repeatedly interrupting them on ordinary launches.
    var hasCompletedOnboarding: Bool {
        didSet {
            if hasCompletedOnboarding {
                defaults.set(
                    Self.currentOnboardingVersion,
                    forKey: Self.onboardingVersionKey
                )
            } else {
                defaults.removeObject(forKey: Self.onboardingVersionKey)
            }
        }
    }

    /// Embed a small module icon at the leading edge of every menu bar item, so it's
    /// clear which value belongs to which hardware. Off = values only.
    var showMenuBarIcons: Bool {
        didSet {
            defaults.set(showMenuBarIcons, forKey: Self.menuBarIconsKey)
            if showMenuBarIcons != oldValue { onAppearanceChanged?() }
        }
    }

    /// Optional one-item health summary. Existing metric items and their layout are
    /// preserved when this is toggled.
    /// Keep the Dashboard in the menu bar when nothing is grouped into it.
    ///
    /// It is not a permanent item. Emptying the menu bar entirely is recoverable —
    /// launching Mectrics again opens Settings (`applicationShouldHandleReopen`) — so
    /// locking the icon in place would spend the scarce surface on someone who only
    /// wants CPU there. With cards inside it there is nothing to decide: they would have
    /// nowhere to be shown, so it stays.
    var dashboardItemEnabled: Bool {
        didSet {
            defaults.set(dashboardItemEnabled, forKey: Self.dashboardItemEnabledKey)
            guard dashboardItemEnabled != oldValue else { return }
            // Only ever changes the menu bar when no card is holding the item there.
            if groupedModules.isEmpty { onModulesChanged?() }
        }
    }

    /// Whether the Dashboard is in the menu bar: because something is grouped into it,
    /// or because it was asked to stay while empty.
    var showsDashboardItem: Bool {
        Self.showsDashboardItem(
            grouped: groupedModules,
            keptWhenEmpty: dashboardItemEnabled
        )
    }

    private static func showsDashboardItem(
        grouped: Set<MetricID>,
        keptWhenEmpty: Bool
    ) -> Bool {
        keptWhenEmpty || !grouped.isEmpty
    }

    /// Whether the dashboard shows the card for the Mac itself — its macOS version and
    /// uptime. It is a card like any other, so it can be taken off from the dashboard and
    /// put back from the Dashboard's row in Settings.
    var showsDeviceCard: Bool {
        didSet {
            defaults.set(showsDeviceCard, forKey: Self.showsDeviceCardKey)
        }
    }

    /// Whether Mectrics looks for a new version on its own.
    ///
    /// Off until the user is asked, because it is the only thing in the app that reaches
    /// the network. Sparkle owns the stored value, so this reads and writes that same key
    /// rather than keeping a second copy that could disagree with the updater.
    var automaticUpdateChecks: Bool {
        didSet {
            guard automaticUpdateChecks != oldValue else { return }
            onAutomaticUpdateChecksChanged?(automaticUpdateChecks)
            hasAnsweredUpdateChecks = true
        }
    }

    /// True once the user has answered the question either way, so it is asked once and
    /// never again.
    var hasAnsweredUpdateChecks: Bool {
        didSet { defaults.set(hasAnsweredUpdateChecks, forKey: Self.answeredUpdateChecksKey) }
    }

    @ObservationIgnored var onAutomaticUpdateChecksChanged: ((Bool) -> Void)?

    /// Default-on adaptive monitoring preference.
    var adaptMonitoringToEnergyState: Bool {
        didSet {
            defaults.set(
                adaptMonitoringToEnergyState,
                forKey: Self.adaptMonitoringKey
            )
            if adaptMonitoringToEnergyState != oldValue {
                onEnergyGuardPreferenceChanged?()
            }
        }
    }

    var energyGuardMode: EnergyGuardMode = .normal
    var energyGuardReason: EnergyGuardReason = .none

    /// Accent color for sparklines/charts (`.system` follows macOS accent).
    var accentChoice: AccentChoice {
        didSet {
            defaults.set(accentChoice.rawValue, forKey: Self.accentKey)
            if accentChoice != oldValue { onAppearanceChanged?() }
        }
    }

    /// Called when a look-related setting changes so the menu bar redraws immediately
    /// (SwiftUI views update on their own via observation).
    @ObservationIgnored var onAppearanceChanged: (() -> Void)?

    /// Per-module notification threshold rules.
    var alertRules: [MetricID: AlertRule] {
        didSet {
            persistAlertRules()
            refreshActiveMetrics()
        }
    }

    /// Native system signals are separate from percentage rules so an upgrade never
    /// replaces or silently changes an existing threshold.
    var systemAlertRules: [SystemAlertSignal: SystemAlertRule] {
        didSet {
            persistSystemAlertRules()
            refreshActiveMetrics()
        }
    }

    /// Current evaluator state for live rule previews and shared attention surfaces.
    var alertConditionStates: [MetricID: AlertConditionState] = [:]
    var alertConditionStartedAt: [MetricID: Date] = [:]
    var alertMeasuredValues: [MetricID: Double] = [:]
    var systemConditionStates: [SystemAlertSignal: AlertConditionState] = [:]
    var activeAlertConditions: [String: ActiveAlertCondition] = [:]

    func applyAlertUpdate(_ update: AlertConditionUpdate) {
        if update.state == .normal {
            activeAlertConditions[update.conditionKey] = nil
        } else {
            activeAlertConditions[update.conditionKey] =
                ActiveAlertCondition(update: update)
        }
        if let signal = SystemAlertSignal.allCases.first(
            where: { $0.conditionKey == update.conditionKey }
        ) {
            systemConditionStates[signal] = update.state
            return
        }
        alertConditionStates[update.metricID] = update.state
        alertMeasuredValues[update.metricID] = update.measuredValue
        if let startedAt = update.startedAt, update.state != .normal {
            alertConditionStartedAt[update.metricID] = startedAt
        } else {
            alertConditionStartedAt[update.metricID] = nil
        }
    }

    func isComponentEnabled(_ component: MenuBarComponent, for id: MetricID) -> Bool {
        enabledComponents[id]?.contains(component) ?? false
    }

    /// Turns a look on or off, except that **the last one on stays on**.
    ///
    /// A module in the menu bar has to draw something, so clearing its last look used to
    /// drop it to `.off` — the row collapsed under the pointer and the chips that were
    /// being edited disappeared with it. One control, one decision: the chips choose
    /// which looks, and the pop-up beside them is what takes the module out.
    func toggleComponent(_ component: MenuBarComponent, for id: MetricID) {
        var set = enabledComponents[id] ?? []
        if set.contains(component) {
            guard set.count > 1 || placement(of: id) != .ownItems else { return }
            set.remove(component)
        } else {
            set.insert(component)
        }
        enabledComponents[id] = set
    }

    /// True when this look is the only one left, so the chip showing it says it cannot
    /// be switched off rather than swallowing the click.
    func isOnlyEnabledComponent(_ component: MenuBarComponent, for id: MetricID) -> Bool {
        placement(of: id) == .ownItems
            && enabledComponents[id] == [component]
    }

    func placement(of id: MetricID) -> MenuBarPlacement {
        MenuBarPlacement.placement(
            of: id,
            enabledComponents: enabledComponents,
            groupedModules: groupedModules
        )
    }

    /// Moves a module between its own items, the dashboard, and nowhere.
    ///
    /// Placement is exclusive so "where do I see Disk?" has one answer. Moving a module
    /// to the dashboard keeps the components it had, so moving it back restores the
    /// items it was showing rather than resetting it to a default.
    func setPlacement(_ placement: MenuBarPlacement, for id: MetricID) {
        guard availableModules.contains(id), placement != self.placement(of: id) else {
            return
        }
        switch placement {
        case .grouped:
            groupedModules.insert(id)
        case .ownItems:
            groupedModules.remove(id)
            if (enabledComponents[id] ?? []).isEmpty {
                enabledComponents[id] = [.default(for: id)]
            }
        case .off:
            groupedModules.remove(id)
            enabledComponents[id] = []
        }
    }

    /// The dashboard's modules in card order (the menu bar's module order).
    var orderedDashboardModules: [MetricID] {
        availableModules.filter { groupedModules.contains($0) }
    }

    /// Component choices worth offering for a module. Battery health and cycle count
    /// and temperatures are hidden when this Mac does not report them, so the
    /// builder never offers a look that can only ever render a dash.
    ///
    /// The answer is derived from the sample details but changes only when a reading
    /// appears or disappears, so it is cached rather than recomputed from `latest`.
    /// Settings rows read this instead of `latest` and therefore keep their view
    /// identity while values tick — see `componentOptions`.
    func availableComponents(for id: MetricID) -> [MenuBarComponent] {
        componentOptions[id] ?? Self.componentOptions(for: id, detail: nil, temperature: nil)
    }

    /// Cached per-module component availability. Updated only when it changes.
    private(set) var componentOptions: [MetricID: [MenuBarComponent]] = [:]

    private static func componentOptions(
        for id: MetricID,
        detail: [String: Double]?,
        temperature: Double?
    ) -> [MenuBarComponent] {
        let components = MenuBarComponent.available(for: id)
        guard let detail else {
            return components.filter { $0 != .temperature }
        }
        return components.filter { component in
            switch component {
            case .health: return detail["healthPercent"] != nil
            case .cycles: return detail["cycleCount"] != nil
            case .temperature: return temperature != nil
            default:      return true
            }
        }
    }

    /// System signals this Mac can actually report. Like `componentOptions`, this is
    /// derived from sample details but changes only when a reading appears, so Settings
    /// can list its rules without depending on `latest`.
    private(set) var availableSystemAlertSignals: Set<SystemAlertSignal> = Set(
        SystemAlertSignal.allCases.filter { $0 != .batteryService }
    )

    /// Recomputes the cached option lists. Returns true when the menu bar's own list
    /// of items changed and it therefore has to be rebuilt — never under the single
    /// icon, whose one item does not depend on which components exist.
    ///
    /// Availability only ever grows within a session. A sensor that reads out of range
    /// for one cycle — an idle GPU reporting nothing is routine — is a failed read, not
    /// hardware that disappeared, and the item already knows how to render a dash for a
    /// missing value. Recomputing from scratch instead let a flapping key add and
    /// remove a menu bar item every few seconds, and every rebuild tears down and
    /// re-creates every status item.
    @discardableResult
    private func refreshComponentOptions() -> Bool {
        var options = componentOptions
        for id in availableModules {
            let discovered = Self.componentOptions(
                for: id,
                detail: latest[id]?.detail,
                temperature: temperature(for: id)
            )
            let known = componentOptions[id] ?? []
            options[id] = MenuBarComponent.available(for: id).filter {
                discovered.contains($0) || known.contains($0)
            }
        }
        // macOS only reports a service recommendation on Macs whose battery has one.
        if latest[.battery]?.detail["serviceRecommended"] != nil,
           !availableSystemAlertSignals.contains(.batteryService) {
            availableSystemAlertSignals.insert(.batteryService)
        }
        guard options != componentOptions else { return false }
        // Read before the new options land — and only now, not on every cycle.
        let previousItems = menuBarItemKeys
        componentOptions = options
        return menuBarItemKeys != previousItems
    }

    /// Identity of every metric status item the menu bar shows, in display order.
    private var menuBarItemKeys: [String] {
        MenuBarPlacement.itemKeys(
            orderedItems: orderedEnabledItems,
            showsDashboardItem: showsDashboardItem
        )
    }

    /// The same list for a different set of components, so a `didSet` can ask whether the
    /// menu bar it is about to rebuild would actually look any different.
    ///
    /// Editing components cannot move the Dashboard, so its presence is passed in
    /// rather than recomputed: deriving it from the components alone would report a
    /// change that did not happen.
    private func menuBarItemKeys(
        for components: [MetricID: Set<MenuBarComponent>]
    ) -> [String] {
        let items = availableModules
            .filter { !groupedModules.contains($0) }
            .flatMap { id in
                availableComponents(for: id)
                    .filter { components[id]?.contains($0) ?? false }
                    .map { (module: id, component: $0) }
            }
        // Editing components cannot move the Dashboard, so its presence is passed
        // through rather than recomputed from the components alone.
        return MenuBarPlacement.itemKeys(
            orderedItems: items,
            showsDashboardItem: showsDashboardItem
        )
    }

    /// Temperature belonging to a hardware-domain module, if the SMC exposes a
    /// recognized sensor for that domain on this Mac.
    func temperature(for id: MetricID) -> Double? {
        let detail = latest[.sensors]?.detail
        switch id {
        case .cpu:    return detail?["cpuMax"]
        case .memory: return detail?["memoryMax"]
        case .gpu:    return detail?["gpuMax"]
        default:      return nil
        }
    }

    /// Keeps every available module sampled while the menu bar builder is on screen,
    /// so its component previews show real values rather than placeholders.
    func beginBuilderPreview() {
        builderPreviewActive = true
        refreshActiveMetrics()
        engine.requestRefresh()
    }

    func endBuilderPreview() {
        builderPreviewActive = false
        refreshActiveMetrics()
    }

    /// Modules whose popover, dashboard card, or detail window is on screen. Those
    /// surfaces show a temperature, so the SMC is worth reading while one is open.
    private var visibleDetailModules: Set<MetricID> = []

    /// Replaces the on-screen modules in one step. The dashboard shows several at once,
    /// and a forced pass reads every active provider — the SMC included — so one
    /// opening asks for one pass, not one per card. Back-to-back passes would also
    /// measure CPU load and network rates over a few milliseconds.
    func setVisibleDetailModules(_ ids: Set<MetricID>) {
        guard ids != visibleDetailModules else { return }
        let gained = !ids.isSubset(of: visibleDetailModules)
        visibleDetailModules = ids
        refreshActiveMetrics()
        // A newly opened surface should show a temperature immediately rather than
        // waiting for the next heavy cycle.
        if gained { engine.requestRefresh(includingHeavy: true) }
    }

    private let defaults = UserDefaults.standard
    private static let enabledKey = "enabledModules"
    private static let onboardingVersionKey = "completedOnboardingVersion"
    private static let currentOnboardingVersion = 2
    private static let accentKey = "accentChoice"
    private static let menuBarIconsKey = "showMenuBarIcons"
    private static let dashboardItemEnabledKey = "dashboardItemEnabled"
    private static let groupedModulesKey = "groupedModules"
    private static let showsDeviceCardKey = "showsDeviceCard"
    private static let adaptMonitoringKey = "adaptMonitoringToEnergyState"
    private static let answeredUpdateChecksKey = "hasAnsweredAutomaticUpdateChecks"
    private static let alertsKey = AlertConfigurationStorage.thresholdRulesKey
    private static let systemAlertsKey = AlertConfigurationStorage.systemRulesKey
    private static let moduleComponentsKey = "moduleComponents"
    private static let legacyStylesKey = "moduleStyles"

    init() {
        // Availability is probed once and the result handed to the engine, because
        // asking a hardware-backed provider whether it exists is as expensive as
        // sampling it.
        let availableProviders = MetricsKit.coreProviders().filter { $0.isAvailable }
        let available = availableProviders.map(\.id)
        self.availableMetricIDs = Set(available)
        // Temperatures are not a standalone module: the sensors provider keeps
        // sampling in the background and its readings surface inside the CPU/GPU
        // popovers (hardware-domain grouping).
        self.availableModules = available.filter { $0 != .sensors }

        let engine = MetricsEngine()
        engine.register(availableProviders, alreadyFiltered: true)
        self.engine = engine

        self.hasCompletedOnboarding =
            defaults.integer(forKey: Self.onboardingVersionKey) >= Self.currentOnboardingVersion
        self.accentChoice = AccentChoice(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .pink
        // Icons default to on; only an explicit user choice turns them off.
        self.showMenuBarIcons = defaults.object(forKey: Self.menuBarIconsKey) as? Bool ?? true
        self.adaptMonitoringToEnergyState =
            defaults.object(forKey: Self.adaptMonitoringKey) as? Bool ?? true
        self.automaticUpdateChecks = defaults.bool(
            forKey: UpdateController.automaticChecksKey
        )
        self.hasAnsweredUpdateChecks = defaults.bool(
            forKey: Self.answeredUpdateChecksKey
        )
        self.alertRules = Self.loadAlertRules(from: defaults, available: available)
        self.systemAlertRules = Self.loadSystemAlertRules(from: defaults)
        self.enabledComponents = Self.loadEnabledComponents(
            from: defaults, available: available.filter { $0 != .sensors })
        // Nothing is grouped unless it was asked for, so an existing menu bar is
        // exactly as it was: every module keeps the items it had.
        // Kept while empty unless it was turned off, so a menu bar never goes silently
        // blank behind someone who cleared the Dashboard out.
        self.dashboardItemEnabled =
            defaults.object(forKey: Self.dashboardItemEnabledKey) as? Bool ?? true
        // On unless it was turned off, so the dashboard has something to say about the
        // Mac even before a module is grouped into it.
        self.showsDeviceCard =
            defaults.object(forKey: Self.showsDeviceCardKey) as? Bool ?? true
        self.groupedModules = MenuBarPlacement.groupedModules(
            stored: defaults.array(forKey: Self.groupedModulesKey) as? [String],
            available: available.filter { $0 != .sensors }
        )
        refreshComponentOptions()
        refreshActiveMetrics()
        PerformanceSignposts.providersReady(count: availableProviders.count)
    }

    /// Watched modules in menu bar order (CPU, Memory, Battery ...).
    var orderedEnabledModules: [MetricID] {
        let enabled = enabledModules
        return availableModules.filter(enabled.contains)
    }

    /// Module-level switch, for surfaces that ask only whether a module is shown at
    /// all — onboarding, where placement is not a question yet.
    ///
    /// Enabling puts the module in the Dashboard, because that is where a reading
    /// starts: the menu bar is the scarce surface, and a module earns its own item by
    /// being asked for one. A surface that knows better says so with
    /// `setPlacement(_:for:)`.
    func setEnabled(_ enabled: Bool, for id: MetricID) {
        guard enabled != (placement(of: id) != .off) else { return }
        setPlacement(enabled ? .grouped : .off, for: id)
    }

    /// Normalized history for sparklines.
    func history(_ id: MetricID, count: Int = 40) -> [Double] {
        engine.store.history(id, count: count).map(\.normalized)
    }

    /// Applies one engine pass while preserving the last valid sample across short
    /// provider interruptions.
    func apply(_ report: SamplingCycleReport) {
        for (id, sample) in report.samples {
            latest[id] = sample
            consecutiveSamplingFailures[id] = 0
        }
        for id in report.failedMetricIDs {
            consecutiveSamplingFailures[id, default: 0] += 1
        }
        // A component appearing or disappearing (a temperature this Mac only reports
        // sometimes, a battery that starts reporting health) changes what belongs in
        // the menu bar, so the items are rebuilt — but only then, not every cycle.
        if refreshComponentOptions() {
            onModulesChanged?()
        }
    }

    /// Shared state resolver used by menu bar, popover, panel, and Settings preview.
    func metricState(
        for id: MetricID,
        isEnabled: Bool? = nil,
        now: Date = Date()
    ) -> MetricDataState {
        let enabled = isEnabled ?? enabledModules.contains(id)
        return MetricDataState.resolve(
            isAvailable: availableMetricIDs.contains(id),
            isEnabled: enabled,
            sample: latest[id],
            consecutiveFailures: consecutiveSamplingFailures[id, default: 0],
            now: now
        )
    }

    func refreshMetrics() {
        // An explicit refresh reads everything, including whatever Energy Guard has
        // been slowing down or holding back.
        engine.requestRefresh(includingHeavy: true)
    }

    /// Temporarily samples the recommended onboarding metrics without changing the
    /// user's menu bar choices.
    func beginOnboardingPreview() {
        onboardingPreviewActive = true
        refreshActiveMetrics()
        engine.requestRefresh()
    }

    func endOnboardingPreview() {
        onboardingPreviewActive = false
        refreshActiveMetrics()
    }

    /// Samples watched modules plus metrics required by enabled alerts. Temperature
    /// readings stay active when CPU, memory, or GPU is visible because their
    /// popovers, the dashboard, and optional menu bar components show them.
    private func refreshActiveMetrics() {
        var active = enabledModules
        if onboardingPreviewActive {
            active.formUnion([.cpu, .memory, .battery, .network])
        }
        if builderPreviewActive {
            active.formUnion(availableModules)
        }
        // Reading the SMC is the most expensive thing this app does, so a temperature
        // is sampled only where one is actually on screen: a `.temperature` menu bar
        // component (separate items only — the single icon shows none), an open
        // popover, dashboard, or detail window for a hardware-domain module, or the
        // builder previewing temperature chips (separate items only — under the
        // single icon it shows switches and health badges, never a temperature). A
        // module merely *having* a menu bar item does not earn it — its popover is
        // closed, and nothing in the item shows a temperature. A rule watching that
        // module needs no temperature of its own either: the CPU temperature rule asks
        // for `.sensors` directly, and thermal pressure comes from ProcessInfo, not the
        // SMC.
        let showsTemperature = [MetricID.cpu, .memory, .gpu].contains { id in
            // A grouped module's components are not on screen; its card is, and a card
            // asks for its temperature by being visible, not by existing.
            placement(of: id) == .ownItems
                && (enabledComponents[id]?.contains(.temperature) ?? false)
        }
        if showsTemperature
            || !visibleDetailModules.isDisjoint(with: [.cpu, .memory, .gpu])
            || builderPreviewActive {
            active.insert(.sensors)
        }
        for (id, rule) in alertRules where rule.enabled {
            active.insert(id)
        }
        for (signal, rule) in systemAlertRules where rule.enabled {
            if let samplingMetricID = signal.samplingMetricID {
                active.insert(samplingMetricID)
            }
        }
        engine.setActiveMetrics(active)
    }

    private static let enabledComponentsKey = "enabledComponents"

    private static func loadEnabledComponents(from defaults: UserDefaults,
                                              available: [MetricID]) -> [MetricID: Set<MenuBarComponent>] {
        if let data = defaults.data(forKey: Self.enabledComponentsKey),
           let raw = try? JSONDecoder().decode([String: [String]].self, from: data) {
            var result: [MetricID: Set<MenuBarComponent>] = [:]
            for (key, values) in raw {
                guard let id = MetricID(rawValue: key), available.contains(id) else { continue }
                let valid = MenuBarComponent.available(for: id)
                // The chart-only component was removed; a layout that used it keeps
                // its module by falling back to value + graph.
                let migrated = values.map { $0 == "graph" ? "valueGraph" : $0 }
                result[id] = Set(
                    migrated.compactMap(MenuBarComponent.init).filter(valid.contains)
                )
            }
            return result
        }
        // Migrate the one-component-per-module era (enabledModules + moduleComponents).
        let legacyChoices = Self.loadModuleComponents(from: defaults)
        guard let raw = defaults.array(forKey: Self.enabledKey) as? [String] else {
            // A clean install: no items of their own at all. The menu bar starts with
            // the Dashboard and nothing else, holding the cards in
            // `MenuBarPlacement.defaultGroupedModules`, and a module earns an item of
            // its own by being asked for one.
            return [:]
        }
        let legacyEnabled = raw
            .compactMap { MetricID(rawValue: $0) }
            .filter(available.contains)
        var result: [MetricID: Set<MenuBarComponent>] = [:]
        for id in (legacyEnabled.isEmpty ? available : legacyEnabled) {
            let choice = legacyChoices[id] ?? .default(for: id)
            result[id] = [MenuBarComponent.available(for: id).contains(choice) ? choice : .default(for: id)]
        }
        return result
    }

    private func persistEnabledComponents() {
        let raw = Dictionary(uniqueKeysWithValues: enabledComponents.map { key, value in
            (key.rawValue, value.map(\.rawValue).sorted())
        })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.enabledComponentsKey)
        }
    }

    // MARK: - Appearance

    /// Effective accent as an AppKit color (menu bar rendering).
    var accentNSColor: NSColor { accentChoice.nsColor ?? .controlAccentColor }

    /// Effective accent as a SwiftUI color (popover, floating panel).
    var accentColor: Color { Color(nsColor: accentNSColor) }

    // MARK: - Alerts

    /// Modules that support threshold alerts, in canonical order. Includes sensors
    /// (CPU temperature) even though temperatures are not a menu bar module.
    var alertableModules: [MetricID] {
        MetricID.allCases.filter { alertRules[$0] != nil }
    }

    private static func defaultAlertRules(available: [MetricID]) -> [MetricID: AlertRule] {
        var rules: [MetricID: AlertRule] = [:]
        for id in available {
            switch id {
            case .cpu, .memory, .disk, .gpu:
                rules[id] = AlertRule(enabled: false, thresholdPercent: 90)
            case .battery:
                rules[id] = AlertRule(enabled: false, thresholdPercent: 20)
            case .sensors:
                // Threshold is °C for the temperature rule, not a percentage.
                rules[id] = AlertRule(enabled: false, thresholdPercent: 85)
            default:
                break
            }
        }
        return rules
    }

    private static func loadAlertRules(from defaults: UserDefaults,
                                       available: [MetricID]) -> [MetricID: AlertRule] {
        var rules = defaultAlertRules(available: available)
        if let data = defaults.data(forKey: Self.alertsKey),
           let raw = try? JSONDecoder().decode([String: AlertRule].self, from: data) {
            for (key, rule) in raw {
                if let id = MetricID(rawValue: key), rules[id] != nil {
                    rules[id] = rule
                }
            }
        }
        // Where an alert appears is fixed policy, not a stored per-rule choice.
        return rules.mapValues {
            var rule = $0
            rule.destinations = AlertsSettingsTab.alertDestinations
            return rule
        }
    }

    private func persistAlertRules() {
        let raw = Dictionary(uniqueKeysWithValues: alertRules.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.alertsKey)
        }
    }

    var systemConditionReadings: [SystemAlertSignal: SystemConditionReading] {
        SystemConditionSource.readings(latest: latest)
    }

    var healthConditions: [ActiveAlertCondition] {
        activeAlertConditions.values
            .filter { $0.destinations.contains(.compactHealth) }
            .sorted {
                if $0.severity.rank != $1.severity.rank {
                    return $0.severity.rank > $1.severity.rank
                }
                return $0.startedAt > $1.startedAt
            }
    }

    var healthMetricIDs: Set<MetricID> {
        var ids = Set(alertRules.compactMap { id, rule in
            rule.enabled && rule.destinations.contains(.compactHealth)
                ? id
                : nil
        })
        for (signal, rule) in systemAlertRules
            where rule.enabled && rule.destinations.contains(.compactHealth) {
            ids.insert(signal.metricID)
        }
        return ids
    }

    var healthState: HealthState {
        HealthState.resolve(
            conditions: healthConditions,
            configuredMetricStates: healthMetricIDs.map {
                metricState(for: $0, isEnabled: true)
            }
        )
    }

    private static func defaultSystemAlertRules()
        -> [SystemAlertSignal: SystemAlertRule] {
        [
            // A build that pushes the chip into throttling for twenty seconds is
            // normal work, not news. These two default to longer sustained windows
            // than the percentage rules because only a state that *stays* is a cost.
            .thermalPressure: SystemAlertRule(
                enabled: false,
                thresholdValue: Double(ThermalPressureLevel.serious.rawValue),
                durationSeconds: 120
            ),
            .memoryPressure: SystemAlertRule(
                enabled: false,
                thresholdValue: Double(MemoryPressureLevel.warning.rawValue),
                durationSeconds: 60
            ),
            .diskAvailableCapacity: SystemAlertRule(
                enabled: false,
                thresholdValue: 20 * 1_024 * 1_024 * 1_024
            ),
            .batteryService: SystemAlertRule(
                enabled: false,
                thresholdValue: 1
            )
        ]
    }

    private static func loadSystemAlertRules(
        from defaults: UserDefaults
    ) -> [SystemAlertSignal: SystemAlertRule] {
        var rules = defaultSystemAlertRules()
        guard let data = defaults.data(forKey: Self.systemAlertsKey),
              let raw = try? JSONDecoder().decode(
                  [String: SystemAlertRule].self,
                  from: data
              )
        else {
            return rules.mapValues {
                var rule = $0
                rule.destinations = AlertsSettingsTab.alertDestinations
                return rule
            }
        }
        for (key, rule) in raw {
            if let signal = SystemAlertSignal(rawValue: key) {
                rules[signal] = rule
            }
        }
        return rules.mapValues {
            var rule = $0
            rule.destinations = AlertsSettingsTab.alertDestinations
            return rule
        }
    }

    private func persistSystemAlertRules() {
        let raw = Dictionary(
            uniqueKeysWithValues: systemAlertRules.map {
                ($0.key.rawValue, $0.value)
            }
        )
        if let data = try? JSONEncoder().encode(raw) {
            defaults.set(data, forKey: Self.systemAlertsKey)
        }
    }

    /// Legacy single-choice-per-module preference, read only for migration.
    private static func loadModuleComponents(from defaults: UserDefaults) -> [MetricID: MenuBarComponent] {
        if let raw = defaults.dictionary(forKey: Self.moduleComponentsKey) as? [String: String] {
            var components: [MetricID: MenuBarComponent] = [:]
            for (key, value) in raw {
                if let id = MetricID(rawValue: key), let component = MenuBarComponent(rawValue: value) {
                    components[id] = component
                }
            }
            return components
        }
        if let legacy = defaults.dictionary(forKey: Self.legacyStylesKey) as? [String: String] {
            var components: [MetricID: MenuBarComponent] = [:]
            for (key, value) in legacy {
                guard let id = MetricID(rawValue: key) else { continue }
                switch value {
                case "value": components[id] = .value
                case "graph": components[id] = .valueGraph
                case "both":  components[id] = .valueGraph
                default: break
                }
            }
            return components
        }
        return [:]
    }
}
