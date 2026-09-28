import AppKit
import SwiftUI
import MetricsKit

/// Creates and updates the menu bar items and manages the detail popover on click.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    /// Modules that came on screen (true) or left it (false). A surface's modules are
    /// reported together — the dashboard's cards in one call — so one opening is one
    /// sampling update, not one per card.
    var onDetailVisibilityChanged: ((Set<MetricID>, Bool) -> Void)?

    private let model: AppModel
    /// One status item per enabled (module, component) pair, keyed "module|component".
    private var items: [String: MetricStatusItem] = [:]
    private var compactHealthItem: CompactHealthStatusItem?
    /// The single-icon style's logo item; nil with separate items.
    private var logoItem: MectricsStatusItem?
    private let popover = NSPopover()

    /// What the shared popover is showing. All three share one `NSPopover`, so a
    /// click on another item replaces the content rather than stacking a second one.
    private enum PopoverKind: Equatable {
        case module(MetricID)
        case health
        case dashboard
    }

    /// The content the popover shows, kept until the popover has finished closing so
    /// a click on the same item during the close animation still reads as a toggle.
    private var popoverKind: PopoverKind?
    /// True from the moment a close begins until something is shown again.
    private var isPopoverClosing = false
    /// Exactly the modules reported visible via `onDetailVisibilityChanged`, so the
    /// same set is reported hidden later — even if the dashboard's modules changed
    /// while it was open.
    private var reportedVisibleModules: Set<MetricID> = []

    init(model: AppModel) {
        self.model = model
        super.init()
        // Native transient popovers close when the user clicks elsewhere.
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A popover made key can outlive a switch to another app — clicking a window
        // that is already frontmost is not the "interaction elsewhere" that transient
        // behaviour watches for. Close it explicitly when Mectrics stops being active.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        // Items skip redrawing when their inputs are unchanged, and the system accent
        // is a dynamic color that keeps its identity when the user picks a new one.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemColorsDidChange),
            name: NSColor.systemColorsDidChangeNotification,
            object: nil
        )
    }

    @objc private func applicationDidResignActive() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    @objc private func systemColorsDidChange() {
        for statusItem in items.values { statusItem.invalidateCachedRender() }
        compactHealthItem?.invalidateCachedRender()
        // The logo's badge tint is a dynamic system colour too, and it keeps its
        // identity when the user picks a new accent.
        logoItem?.invalidateCachedRender()
        refresh()
    }

    /// Rebuilds the menu bar items from scratch based on the menu bar style and the
    /// enabled modules.
    func rebuild() {
        // Every item is about to be removed, and with it whatever button the open
        // popover is anchored to. Close it first — at once, not animated out from an
        // anchor that no longer exists — so what it reported visible is reported
        // hidden instead of left behind with a popover pointing at nothing.
        if popoverKind != nil || popover.isShown {
            endPopoverVisibility()
            isPopoverClosing = true
            popover.animates = false
            popover.close()
            popoverKind = nil
            releasePopoverContent()
        }
        for (_, item) in items { item.remove() }
        items.removeAll()
        compactHealthItem?.remove()
        compactHealthItem = nil
        logoItem?.remove()
        logoItem = nil

        switch model.menuBarStyle {
        case .singleIcon:
            // No Compact Health item here: the logo carries the health state and the
            // dashboard leads with the condition, so a second icon would say it twice.
            let logo = MectricsStatusItem()
            logo.onClick = { [weak self] in
                self?.toggleDashboardPopover()
            }
            logoItem = logo
        case .items:
            if model.compactHealthEnabled {
                let healthItem = CompactHealthStatusItem()
                healthItem.onClick = { [weak self] in
                    self?.toggleHealthPopover()
                }
                compactHealthItem = healthItem
            }
            for (id, component) in model.orderedEnabledItems {
                let statusItem = MetricStatusItem(id: id, component: component)
                statusItem.onClick = { [weak self] moduleID in
                    self?.togglePopover(for: moduleID)
                }
                items["\(id.rawValue)|\(component.rawValue)"] = statusItem
            }
        }
        refresh()
    }

    /// Updates the live values of all items. Under the single icon the only thing that
    /// can change is the logo's health badge, and only on a severity transition — both
    /// health items drop an update that repeats the state they already show.
    func refresh() {
        let accent = model.accentNSColor
        let health = model.compactHealthState
        compactHealthItem?.update(health)
        logoItem?.update(health)
        // History is shared by every item of the same module, and only charted
        // components need it at all.
        var histories: [MetricID: [Double]] = [:]
        for statusItem in items.values {
            let id = statusItem.id
            let sample = model.latest[id]
            let samples: [Double]
            if statusItem.component.drawsSparkline {
                if let cached = histories[id] {
                    samples = cached
                } else {
                    samples = model.history(id)
                    histories[id] = samples
                }
            } else {
                samples = []
            }
            statusItem.update(
                visual: sample.map {
                    MenuBarText.visual(
                        for: id,
                        component: statusItem.component,
                        sample: $0,
                        temperature: model.temperature(for: id)
                    )
                },
                state: model.metricState(for: id, isEnabled: true),
                samples: samples,
                accent: accent,
                showIcon: model.showMenuBarIcons
            )
        }
    }

    /// Brings what the open dashboard reports visible in line with the dashboard's
    /// current modules. Called when they change without a menu bar rebuild.
    func dashboardModulesChanged() {
        guard popoverKind == .dashboard, !isPopoverClosing else { return }
        let current = Set(model.orderedDashboardModules)
        let removed = reportedVisibleModules.subtracting(current)
        let added = current.subtracting(reportedVisibleModules)
        reportedVisibleModules = current
        if !removed.isEmpty { onDetailVisibilityChanged?(removed, false) }
        if !added.isEmpty { onDetailVisibilityChanged?(added, true) }
    }

    // MARK: - Popover

    private func togglePopover(for id: MetricID) {
        // Anchor on the module's first item (a module can have several).
        guard let button = items.values.first(where: { $0.id == id })?.item.button else { return }
        if popover.isShown && popoverKind == .module(id) {
            closePopover()
            return
        }

        let signpostID = PerformanceSignposts.beginModulePopover()
        show(
            DetailPopoverView(model: model, moduleID: id),
            as: .module(id),
            visibleModules: [id],
            from: button
        )
        PerformanceSignposts.endModulePopover(signpostID)
    }

    private func toggleHealthPopover() {
        guard let button = compactHealthItem?.item.button else { return }
        if popover.isShown && popoverKind == .health {
            closePopover()
            return
        }

        let signpostID = PerformanceSignposts.beginHealthPopover()
        show(
            CompactHealthPopoverView(model: model),
            as: .health,
            visibleModules: [],
            from: button
        )
        PerformanceSignposts.endHealthPopover(signpostID)
    }

    private func toggleDashboardPopover() {
        guard let button = logoItem?.item.button else { return }
        if popover.isShown && popoverKind == .dashboard {
            closePopover()
            return
        }

        let signpostID = PerformanceSignposts.beginDashboardPopover()
        // Every card is a detail surface: CPU, Memory, and GPU show temperatures, and
        // Energy Guard treats GPU and Fans as on screen while the dashboard is open.
        show(
            DashboardPopoverView(model: model),
            as: .dashboard,
            visibleModules: Set(model.orderedDashboardModules),
            from: button
        )
        PerformanceSignposts.endDashboardPopover(signpostID)
    }

    /// Replaces whatever the popover shows with `content`, anchored at `button`, and
    /// reports `visibleModules` visible.
    private func show<Content: View>(
        _ content: Content,
        as kind: PopoverKind,
        visibleModules: Set<MetricID>,
        from button: NSStatusBarButton
    ) {
        // Showing over an open popover swaps its content without closing it, so the
        // content being replaced gets no close callback; its visibility ends here.
        endPopoverVisibility()
        let host = NSHostingController(rootView: content.quietFocusRing())
        // Content height varies (top-processes list expands/collapses, the dashboard
        // drills into a module) — let SwiftUI drive the popover size, not a pin.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popoverKind = kind
        isPopoverClosing = false
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popover.contentViewController?.view.window?.clearInitialFocus()
        reportedVisibleModules = visibleModules
        if !visibleModules.isEmpty {
            onDetailVisibilityChanged?(visibleModules, true)
        }
    }

    private func closePopover() {
        endPopoverVisibility()
        isPopoverClosing = true
        popover.performClose(nil)
    }

    /// Reports every module the popover reported visible as hidden. Every way a
    /// popover ends — toggled closed, replaced by another, closed by AppKit, or
    /// orphaned by a rebuild — passes through here, and only the first pass finds
    /// anything to report, so each visible report gets exactly one hidden one.
    private func endPopoverVisibility() {
        let modules = reportedVisibleModules
        reportedVisibleModules = []
        if !modules.isEmpty {
            onDetailVisibilityChanged?(modules, false)
        }
    }

    /// Drops the closed popover's SwiftUI content. A closed popover's window is only
    /// ordered out: its view tree would go on observing the model — every dashboard
    /// card re-evaluated each cycle — and running `.task` loops such as the top
    /// processes list's `ps`, all off screen, until the next opening replaced it.
    /// Every opening installs fresh content, so nothing is lost.
    private func releasePopoverContent() {
        popover.contentViewController = nil
    }

    // AppKit sends `willClose` the moment a close begins and `didClose` after the
    // animation. A click that shows new content during that animation re-opens the
    // popover once it finishes, so the late `didClose` then belongs to the content
    // that is gone, not the content now on screen. Visibility therefore ends in
    // `willClose`, and `didClose` forgets the content only if nothing was shown since.

    /// AppKit's own closes (transient dismissal, resigning active) begin here.
    func popoverWillClose(_ notification: Notification) {
        endPopoverVisibility()
        isPopoverClosing = true
    }

    func popoverDidClose(_ notification: Notification) {
        guard isPopoverClosing else { return }
        popoverKind = nil
        releasePopoverContent()
    }
}
