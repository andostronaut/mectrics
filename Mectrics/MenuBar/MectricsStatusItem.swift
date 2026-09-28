import AppKit

/// The one Mectrics logo item of the single-icon style. Clicking it opens the
/// dashboard popover.
///
/// Unlike a metric item it has nothing to redraw: the logo is a template image, and
/// AppKit tints a template for light, dark, and tinted menu bars on its own. The image,
/// accessibility label, and tooltip are therefore handed to AppKit once, here, and
/// never again — per-cycle work for this item is none at all.
@MainActor
final class MectricsStatusItem: NSObject {
    /// Fixed, so the item never changes width — the same slot the Compact Health
    /// item reserves.
    static let fixedLength: CGFloat = 26

    let item = NSStatusBar.system.statusItem(
        withLength: MectricsStatusItem.fixedLength
    )
    var onClick: (() -> Void)?

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
        button.image = MectricsGlyph.menuBarImage
        button.setAccessibilityLabel(
            String(
                localized: "dashboard.statusItem.accessibilityLabel",
                defaultValue: "Mectrics"
            )
        )
        button.toolTip = String(
            localized: "dashboard.statusItem.help",
            defaultValue: "Show the Mectrics dashboard"
        )
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        onClick?()
    }
}
