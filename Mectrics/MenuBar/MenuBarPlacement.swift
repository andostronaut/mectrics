import Foundation
import MetricsKit

/// Where a module's readings appear in the menu bar.
///
/// This is a choice per module, not one mode for the whole menu bar. Someone who wants
/// CPU in view every second and Disk and Battery only when asked can have exactly that:
/// CPU takes its own items, the other two become cards in the Dashboard's dashboard.
/// A single global "style" could not express it.
///
/// The raw values are persisted and must never change.
enum MenuBarPlacement: String, CaseIterable, Identifiable {
    /// One status item per chosen component — a reading always in view.
    case ownItems
    /// A card in the Dashboard's dashboard, a click away.
    case grouped
    /// Not shown, and not sampled for the menu bar's sake.
    case off

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .ownItems:
            return String(
                localized: "placement.ownItems",
                defaultValue: "Menu bar"
            )
        case .grouped:
            // Named for where it goes, not for what happens to it: "Grouped" left the
            // obvious question — grouped into what? — unanswered on screen.
            return String(
                localized: "placement.grouped",
                defaultValue: "Dashboard"
            )
        case .off:
            return String(localized: "placement.off", defaultValue: "Off")
        }
    }
}

extension MenuBarPlacement {
    /// What a clean install puts in the Dashboard: the two readings everyone wants and
    /// nothing else. They start as cards rather than as items because the menu bar is
    /// the scarce surface — a first run leaves exactly one icon there, and a module
    /// earns its own item by being asked for one.
    static let defaultGroupedModules: [MetricID] = [.cpu, .memory]

    /// Where a module currently is, derived from the two sets that actually decide it.
    ///
    /// The sets stay the source of truth rather than a stored placement per module,
    /// because a module's components and its card are what the menu bar is built from;
    /// a third stored value could disagree with them.
    static func placement(
        of id: MetricID,
        enabledComponents: [MetricID: Set<MenuBarComponent>],
        groupedModules: Set<MetricID>
    ) -> MenuBarPlacement {
        if groupedModules.contains(id) { return .grouped }
        if !(enabledComponents[id] ?? []).isEmpty { return .ownItems }
        return .off
    }

    /// Modules the app watches — samples, publishes to widgets, and lists in summaries.
    /// A module earns this by being visible somewhere, its own item or a card.
    static func watchedModules(
        available: [MetricID],
        enabledComponents: [MetricID: Set<MenuBarComponent>],
        groupedModules: Set<MetricID>
    ) -> Set<MetricID> {
        Set(available.filter {
            placement(
                of: $0,
                enabledComponents: enabledComponents,
                groupedModules: groupedModules
            ) != .off
        })
    }

    /// Identity of every status item the menu bar shows, in display order, so a rebuild
    /// happens when the list changes and not when a value does.
    ///
    /// The Dashboard always leads it. It is the app's one permanent item — its health
    /// badge is the only thing that speaks up unasked, and an app whose whole menu bar
    /// can be switched off has no way back — so it is one entry here however many cards
    /// it holds, and grouping a module changes no status item at all.
    static func itemKeys(
        orderedItems: [(module: MetricID, component: MenuBarComponent)]
    ) -> [String] {
        [dashboardItemKey]
            + orderedItems.map { "\($0.module.rawValue)|\($0.component.rawValue)" }
    }

    static let dashboardItemKey = "mectrics"

    /// The grouped modules as stored: the defaults when nothing was ever stored, and
    /// never a module this Mac cannot report. An empty stored list is a choice.
    static func groupedModules(
        stored: [String]?,
        available: [MetricID]
    ) -> Set<MetricID> {
        guard let stored else {
            return Set(defaultGroupedModules.filter(available.contains))
        }
        return Set(stored.compactMap(MetricID.init(rawValue:)).filter(available.contains))
    }
}
