import Foundation
import MetricsKit

/// Where a module's readings appear in the menu bar.
///
/// This is a choice per module, not one mode for the whole menu bar. Someone who wants
/// CPU in view every second and Disk and Battery only when asked can have exactly that:
/// CPU takes its own items, the other two become cards in the Mectrics item's dashboard.
/// A single global "style" could not express it.
///
/// The raw values are persisted and must never change.
enum MenuBarPlacement: String, CaseIterable, Identifiable {
    /// One status item per chosen component — a reading always in view.
    case ownItems
    /// A card in the Mectrics item's dashboard, a click away.
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
            return String(
                localized: "placement.grouped",
                defaultValue: "Grouped"
            )
        case .off:
            return String(localized: "placement.off", defaultValue: "Off")
        }
    }

    var localizedDescription: String {
        switch self {
        case .ownItems:
            return String(
                localized: "placement.ownItems.description",
                defaultValue: "Its own item, always in view."
            )
        case .grouped:
            return String(
                localized: "placement.grouped.description",
                defaultValue: "A card in the Mectrics icon's dashboard."
            )
        case .off:
            return String(
                localized: "placement.off.description",
                defaultValue: "Not shown in the menu bar."
            )
        }
    }
}

extension MenuBarPlacement {
    /// Modules a clean install groups into the Mectrics item. GPU and Fans are `.heavy`
    /// (SMC/IOKit) providers, so they are offered but never turned on for anyone.
    static let defaultGroupedModules: [MetricID] = []

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
    /// happens when the list changes and not when a value does. The Mectrics item is one
    /// entry however many cards it holds — adding a card changes no status item.
    static func itemKeys(
        orderedItems: [(module: MetricID, component: MenuBarComponent)],
        showsMectricsItem: Bool
    ) -> [String] {
        var keys = orderedItems.map { "\($0.module.rawValue)|\($0.component.rawValue)" }
        if showsMectricsItem { keys.append(mectricsItemKey) }
        return keys
    }

    static let mectricsItemKey = "mectrics"

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
