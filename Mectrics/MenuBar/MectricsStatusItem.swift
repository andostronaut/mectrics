import AppKit

/// The one Mectrics logo item of the single-icon style. Clicking it opens the
/// dashboard popover.
///
/// It is also the health item for this style. There is no second icon beside it: the
/// dashboard already leads with what is wrong, so a separate Compact Health item would
/// put the same conditions in the menu bar twice — the duplication that retired the
/// floating panel (AGENTS.md §4). Health therefore rides on this one mark, as a badge.
///
/// Per-cycle work is still none. The logo is a template image, which AppKit tints for
/// light, dark, and tinted menu bars by itself, and the badge changes only when the
/// severity does — a transition measured in minutes, not in sampling cycles. Repeat
/// updates with the same state are dropped before anything reaches AppKit.
@MainActor
final class MectricsStatusItem: NSObject {
    /// Fixed, so the item never changes width — the same slot the Compact Health
    /// item reserves.
    static let fixedLength: CGFloat = 26

    let item = NSStatusBar.system.statusItem(
        withLength: MectricsStatusItem.fixedLength
    )
    var onClick: (() -> Void)?

    /// The state the current mark was drawn for, so repeat updates are no-ops.
    private var lastState: CompactHealthState?

    override init() {
        super.init()
        item.autosaveName = "mectrics.logo"
        // Removing an autosave-named item persists a hidden flag; force visible so a
        // rebuild always shows it again.
        item.isVisible = true
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.imagePosition = .imageOnly
        // The label names the item and never changes; the value carries the state.
        button.setAccessibilityLabel(
            String(
                localized: "dashboard.statusItem.accessibilityLabel",
                defaultValue: "Mectrics"
            )
        )
        update(.normal)
    }

    /// Shows `state` on the logo: unbadged and untinted while everything is normal, and
    /// badged with the same symbol the Attention Log and Compact Health use otherwise.
    ///
    /// Shape carries the state and colour only reinforces it, so the item stays readable
    /// with any colour vision and in a tinted menu bar.
    func update(_ state: CompactHealthState) {
        guard let button = item.button else { return }
        guard state != lastState else { return }
        lastState = state
        let isNormal = state == .normal
        button.image = MectricsGlyph.menuBarImage(
            badge: isNormal ? nil : state.symbolName
        )
        button.contentTintColor = isNormal ? nil : state.tint
        button.setAccessibilityValue(state.localizedName)
        // Hovering says what is wrong, or what a click does when nothing is.
        button.toolTip = isNormal
            ? String(
                localized: "dashboard.statusItem.help",
                defaultValue: "Show the Mectrics dashboard"
            )
            : state.localizedName
    }

    /// Forces the next update to redraw even if the state is unchanged.
    func invalidateCachedRender() {
        lastState = nil
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        onClick?()
    }
}
