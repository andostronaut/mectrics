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
final class DashboardStatusItem: NSObject {
    /// Fixed, so the item never changes width — the same slot the Compact Health
    /// item reserves.
    static let fixedLength: CGFloat = 26

    let item = NSStatusBar.system.statusItem(
        withLength: DashboardStatusItem.fixedLength
    )
    var onClick: (() -> Void)?

    /// Everything the current mark was drawn from, so repeat updates are no-ops. The
    /// appearance is in here because a badged mark is drawn in the menu bar's own label
    /// colour and has to be redrawn when the Mac changes theme.
    private var lastRender: RenderInputs?

    private struct RenderInputs: Equatable {
        let state: HealthState
        let appearanceName: NSAppearance.Name
    }

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
                defaultValue: "Dashboard"
            )
        )
        update(.normal)
    }

    /// Shows `state` on the logo: the plain template mark while everything is normal, and
    /// badged with the same symbol the Attention Log and Compact Health use otherwise.
    ///
    /// Shape carries the state and colour only reinforces it, so the item stays readable
    /// with any colour vision. Only the badge takes the severity colour — the M keeps the
    /// menu bar's own label colour, because a solid mark painted orange on a dark menu
    /// bar reads as dimmer than the white one it replaced, not as louder.
    func update(_ state: HealthState) {
        guard let button = item.button else { return }
        let appearance = button.effectiveAppearance
        let inputs = RenderInputs(state: state, appearanceName: appearance.name)
        guard inputs != lastRender else { return }
        lastRender = inputs
        let isNormal = state == .normal
        button.image = MectricsGlyph.menuBarImage(
            badge: isNormal ? nil : state.symbolName,
            tint: state.tint,
            appearance: appearance
        )
        // The normal mark is a template AppKit tints for every menu bar; the badged one
        // carries its own two colours and must not be recoloured as one silhouette.
        button.contentTintColor = nil
        button.setAccessibilityValue(state.localizedName)
        // Hovering says what is wrong, or what a click does when nothing is.
        button.toolTip = isNormal
            ? String(
                localized: "dashboard.statusItem.help",
                defaultValue: "Show the Dashboard"
            )
            : state.localizedName
    }

    /// Forces the next update to redraw even if the inputs compare equal.
    func invalidateCachedRender() {
        lastRender = nil
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        onClick?()
    }
}
