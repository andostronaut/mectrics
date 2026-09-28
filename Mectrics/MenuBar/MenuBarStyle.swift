import Foundation
import MetricsKit

/// How Mectrics occupies the menu bar.
///
/// The raw values are persisted under `"menuBarStyle"` and must never change.
enum MenuBarStyle: String, CaseIterable, Identifiable {
    /// One status item per chosen component — the original layout, and the default.
    case items
    /// One Mectrics logo item; clicking it opens the dashboard popover.
    case singleIcon

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .items:
            return String(
                localized: "menuBarStyle.items",
                defaultValue: "Separate"
            )
        case .singleIcon:
            return String(
                localized: "menuBarStyle.singleIcon",
                defaultValue: "Compact"
            )
        }
    }

    /// One sentence on what the style puts in the menu bar, for the Settings footer.
    var localizedDescription: String {
        switch self {
        case .items:
            return String(
                localized: "menuBarStyle.items.description",
                defaultValue: "Every chosen reading gets its own item."
            )
        case .singleIcon:
            return String(
                localized: "menuBarStyle.singleIcon.description",
                defaultValue: "One Mectrics icon. Click it to see every chosen reading in one dashboard."
            )
        }
    }
}

extension MenuBarStyle {
    /// Default dashboard modules for someone who has never chosen: the four a system
    /// dashboard is expected to show, plus battery. GPU and Fans are `.heavy`
    /// (SMC/IOKit) providers, so the dashboard offers them but never turns them on.
    static let defaultDashboardModules: [MetricID] = [
        .cpu, .memory, .battery, .network, .disk
    ]

    /// Modules the app watches — samples, publishes to widgets, and lists in summaries —
    /// for a style. Separate items watch every module with at least one component in
    /// the menu bar; the single icon watches the dashboard's modules.
    static func watchedModules(
        style: MenuBarStyle,
        available: [MetricID],
        enabledComponents: [MetricID: Set<MenuBarComponent>],
        dashboardModules: Set<MetricID>
    ) -> Set<MetricID> {
        switch style {
        case .items:
            return Set(available.filter { !(enabledComponents[$0] ?? []).isEmpty })
        case .singleIcon:
            return dashboardModules.intersection(available)
        }
    }

    /// Identity of every metric status item the menu bar shows for a style, in display
    /// order. Empty for the single icon: the logo is not a metric item, and whatever
    /// components become available underneath it, the menu bar has nothing to rebuild.
    static func itemKeys(
        style: MenuBarStyle,
        orderedItems: [(module: MetricID, component: MenuBarComponent)]
    ) -> [String] {
        switch style {
        case .items:
            return orderedItems.map { "\($0.module.rawValue)|\($0.component.rawValue)" }
        case .singleIcon:
            return []
        }
    }

    /// The dashboard's modules as stored under `"dashboardModules"`: the defaults when
    /// nothing was ever stored, and never a module this Mac cannot report. An empty
    /// stored list is a choice and stays empty.
    static func dashboardModules(
        stored: [String]?,
        available: [MetricID]
    ) -> Set<MetricID> {
        guard let stored else {
            return Set(defaultDashboardModules.filter(available.contains))
        }
        return Set(stored.compactMap(MetricID.init(rawValue:)).filter(available.contains))
    }
}
