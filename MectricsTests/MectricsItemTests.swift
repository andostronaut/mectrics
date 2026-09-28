import AppKit
import MetricsKit
import XCTest
@testable import Mectrics

/// The single-icon style's pure pieces: which modules each style watches, when the
/// menu bar has to be rebuilt, the logo item's slot, and the logo itself.
///
/// Nothing here creates a status item or an `AppModel`: either would touch the real
/// menu bar or the user's real preferences.
final class MectricsItemTests: XCTestCase {
    private let laptop: [MetricID] = [.cpu, .memory, .battery, .network, .disk, .gpu, .fans]
    private let desktop: [MetricID] = [.cpu, .memory, .network, .disk, .gpu]

    // MARK: - Placement

    /// The raw values are persisted, so renaming a case would move someone's modules.
    func testRawValuesArePersistedAndThereforeNeverChange() {
        XCTAssertEqual(MenuBarPlacement.ownItems.rawValue, "ownItems")
        XCTAssertEqual(MenuBarPlacement.grouped.rawValue, "grouped")
        XCTAssertEqual(MenuBarPlacement.off.rawValue, "off")
        for placement in MenuBarPlacement.allCases {
            XCTAssertEqual(MenuBarPlacement(rawValue: placement.rawValue), placement)
        }
    }

    func testEveryPlacementHasItsOwnNameAndDescription() {
        let names = MenuBarPlacement.allCases.map(\.localizedName)
        let descriptions = MenuBarPlacement.allCases.map(\.localizedDescription)
        XCTAssertFalse(names.contains { $0.isEmpty })
        XCTAssertFalse(descriptions.contains { $0.isEmpty })
        XCTAssertEqual(Set(names).count, MenuBarPlacement.allCases.count)
        XCTAssertEqual(Set(descriptions).count, MenuBarPlacement.allCases.count)
    }

    /// Grouped wins over left-over components, because a grouped module keeps the
    /// components it had so moving it back restores the items it was showing.
    func testGroupedWinsOverLeftOverComponents() {
        XCTAssertEqual(
            MenuBarPlacement.placement(
                of: .disk,
                enabledComponents: [.disk: [.value, .ring]],
                groupedModules: [.disk]
            ),
            .grouped
        )
        XCTAssertEqual(
            MenuBarPlacement.placement(
                of: .disk,
                enabledComponents: [.disk: [.value]],
                groupedModules: []
            ),
            .ownItems
        )
        for components: [MetricID: Set<MenuBarComponent>] in [[.disk: []], [:]] {
            XCTAssertEqual(
                MenuBarPlacement.placement(
                    of: .disk,
                    enabledComponents: components,
                    groupedModules: []
                ),
                .off
            )
        }
    }

    /// The point of the whole model: one module in the menu bar and another in the
    /// dashboard, both watched — which one global style could not express.
    func testAModuleWithItemsAndAGroupedModuleAreBothWatched() {
        let watched = MenuBarPlacement.watchedModules(
            available: desktop,
            enabledComponents: [
                .cpu: [.value, .temperature],
                .memory: [],
                .network: [.netActivity]
            ],
            groupedModules: [.disk, .gpu]
        )
        XCTAssertEqual(watched, [.cpu, .network, .disk, .gpu])
    }

    /// A module this Mac cannot report is never watched, however it was stored.
    func testStoredPlacementsForAbsentHardwareAreIgnored() {
        XCTAssertEqual(
            MenuBarPlacement.watchedModules(
                available: desktop,
                enabledComponents: [.battery: [.batteryIcon]],
                groupedModules: [.fans]
            ),
            []
        )
    }

    func testNothingPlacedWatchesNothing() {
        XCTAssertEqual(
            MenuBarPlacement.watchedModules(
                available: laptop,
                enabledComponents: [:],
                groupedModules: []
            ),
            []
        )
    }

    // MARK: - When the menu bar is rebuilt

    func testItemKeysNameEachModuleAndComponentInDisplayOrder() {
        let items: [(module: MetricID, component: MenuBarComponent)] = [
            (.cpu, .value),
            (.cpu, .temperature),
            (.network, .netActivity)
        ]
        XCTAssertEqual(
            MenuBarPlacement.itemKeys(orderedItems: items, showsMectricsItem: false),
            ["cpu|value", "cpu|temperature", "network|netActivity"]
        )
        XCTAssertEqual(
            MenuBarPlacement.itemKeys(orderedItems: [], showsMectricsItem: false),
            []
        )
    }

    /// The Mectrics item is one entry however many cards it holds, so adding or
    /// removing a card never tears down and re-creates every status item.
    func testTheMectricsItemIsOneEntryWhateverItHolds() {
        let items: [(module: MetricID, component: MenuBarComponent)] = [(.cpu, .value)]
        XCTAssertEqual(
            MenuBarPlacement.itemKeys(orderedItems: items, showsMectricsItem: true),
            ["cpu|value", MenuBarPlacement.mectricsItemKey]
        )
    }

    /// Gaining or losing the item itself is a genuine change in which items exist.
    func testTheMectricsItemAppearingChangesTheItemList() {
        let items: [(module: MetricID, component: MenuBarComponent)] = [(.cpu, .value)]
        XCTAssertNotEqual(
            MenuBarPlacement.itemKeys(orderedItems: items, showsMectricsItem: false),
            MenuBarPlacement.itemKeys(orderedItems: items, showsMectricsItem: true)
        )
    }

    // MARK: - The dashboard's own cards

    /// The Mac's card is a card like any other and can be taken off.
    func testTheDeviceCardCanBeTakenOff() {
        XCTAssertEqual(
            DashboardLayout.cards(for: [.cpu], includesDevice: true),
            [.module(.cpu), .device]
        )
        XCTAssertEqual(
            DashboardLayout.cards(for: [.cpu], includesDevice: false),
            [.module(.cpu)]
        )
    }

    /// With nothing left at all the grid says why it is empty rather than going blank.
    func testAnEmptyDashboardStillExplainsItself() {
        XCTAssertEqual(
            DashboardLayout.cards(for: [], includesDevice: true),
            [.device, .emptyHint]
        )
        XCTAssertEqual(
            DashboardLayout.cards(for: [], includesDevice: false),
            [.emptyHint]
        )
    }

    /// Taking a card off edits the module's components, and the menu bar must not be
    /// rebuilt for it: a grouped module contributes no items, so the list is unchanged —
    /// and a rebuild tears down every status item, taking the open dashboard with it.
    func testRemovingACardLeavesTheItemListAlone() {
        let components: [MetricID: Set<MenuBarComponent>] = [
            .cpu: [.value],
            // Grouped, and still holding the components it had before it was grouped.
            .disk: [.value, .ring]
        ]
        let before = MenuBarPlacement.itemKeys(
            orderedItems: orderedItems(components, grouped: [.disk]),
            showsMectricsItem: true
        )
        // Taking Disk off the dashboard clears its components.
        var after = components
        after[.disk] = []
        XCTAssertEqual(
            before,
            MenuBarPlacement.itemKeys(
                orderedItems: orderedItems(after, grouped: []),
                showsMectricsItem: true
            ),
            "Removing a card changed the menu bar's item list"
        )
    }

    private func orderedItems(
        _ components: [MetricID: Set<MenuBarComponent>],
        grouped: Set<MetricID>
    ) -> [(module: MetricID, component: MenuBarComponent)] {
        desktop
            .filter { !grouped.contains($0) }
            .flatMap { id in
                MenuBarComponent.available(for: id)
                    .filter { components[id]?.contains($0) ?? false }
                    .map { (module: id, component: $0) }
            }
    }

    // MARK: - Grouped modules as stored

    /// Nothing is grouped unless it was asked for, so an update leaves every existing
    /// menu bar exactly as it was.
    func testNothingIsGroupedByDefault() {
        XCTAssertTrue(MenuBarPlacement.defaultGroupedModules.isEmpty)
        XCTAssertEqual(
            MenuBarPlacement.groupedModules(stored: nil, available: laptop),
            []
        )
    }

    func testStoredModulesDropUnknownAndUnavailableValues() {
        XCTAssertEqual(
            MenuBarPlacement.groupedModules(
                stored: ["gpu", "battery", "bogus", "CPU", "", "disk", "disk"],
                available: desktop
            ),
            [.gpu, .disk]
        )
    }

    /// AppModel stores the set as sorted raw values; reading that back through a real
    /// defaults domain has to give the same set.
    func testGroupedModulesRoundTripThroughTheStoredFormat() throws {
        let suiteName = "MenuBarPlacementTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for chosen: Set<MetricID> in [[], [.gpu], [.cpu, .fans, .network], Set(laptop)] {
            defaults.set(chosen.map(\.rawValue).sorted(), forKey: "groupedModules")
            XCTAssertEqual(
                MenuBarPlacement.groupedModules(
                    stored: defaults.array(forKey: "groupedModules") as? [String],
                    available: laptop
                ),
                chosen
            )
        }
        defaults.removeObject(forKey: "groupedModules")
        XCTAssertEqual(
            MenuBarPlacement.groupedModules(
                stored: defaults.array(forKey: "groupedModules") as? [String],
                available: laptop
            ),
            []
        )
    }


    // MARK: - Logo status item

    /// Only the static length is read: creating the item would add it to the real menu
    /// bar and persist its autosave name.
    @MainActor
    func testLogoSlotFitsTheLogoAndCentersItOnWholePixels() {
        let length = MectricsStatusItem.fixedLength
        let logo = MectricsGlyph.menuBarImage.size
        XCTAssertEqual(length, length.rounded(), "The slot must be whole points")
        XCTAssertEqual(length.truncatingRemainder(dividingBy: 2), 0, "The slot must be even")
        XCTAssertGreaterThanOrEqual(length, logo.width)
        // Equal margins on both sides, each whole, so the logo stays sharp at 1x.
        XCTAssertEqual((length - logo.width).truncatingRemainder(dividingBy: 2), 0)
    }

    // MARK: - Logo glyph

    func testGlyphAspectRatioMatchesTheAppIconsM() {
        XCTAssertEqual(MectricsGlyph.aspectRatio, 565.0 / 390.0, accuracy: 0.0001)
    }

    func testTemplateImageIsMonochromeAtTheRequestedHeightAndWholePointWidth() {
        for height: CGFloat in [10, 14, 15, 16, 18, 22, 37.5] {
            let image = MectricsGlyph.templateImage(height: height)
            let exactWidth = height * MectricsGlyph.aspectRatio
            XCTAssertTrue(image.isTemplate, "\(height)")
            XCTAssertEqual(image.size.height, height, "\(height)")
            XCTAssertEqual(image.size.width, exactWidth.rounded(.down), "\(height)")
            XCTAssertEqual(image.size.width, image.size.width.rounded(), "\(height)")
            XCTAssertLessThan(exactWidth - image.size.width, 1, "\(height)")
            XCTAssertGreaterThanOrEqual(exactWidth - image.size.width, 0, "\(height)")
        }
    }

    /// The menu bar's logo: a template (so AppKit tints it for every menu bar), no
    /// taller than a menu bar's content, both sides whole and even so it centers on
    /// whole pixels.
    func testMenuBarImageIsAnEvenSizedTemplateThatFitsTheMenuBar() {
        let image = MectricsGlyph.menuBarImage
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertLessThanOrEqual(image.size.height, 22)
        XCTAssertEqual(
            image.size,
            MectricsGlyph.templateImage(height: image.size.height).size
        )
        XCTAssertEqual(image.size.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(image.size.height.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertIdentical(image, MectricsGlyph.menuBarImage, "Built once, not per read")
    }

    /// A template image that draws nothing would leave an invisible, clickable slot in
    /// the menu bar.
    func testTemplateImageDrawsTheMEdgeToEdge() throws {
        for scale: CGFloat in [1, 2] {
            let image = MectricsGlyph.templateImage(height: 14)
            let bitmap = try render(image, scale: scale)
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            var inked = 0
            for x in 0..<width {
                for y in 0..<height where alpha(bitmap, x, y) > 0 { inked += 1 }
            }
            let coverage = Double(inked) / Double(width * height)
            XCTAssertGreaterThan(coverage, 0.3, "scale \(scale)")
            XCTAssertLessThan(coverage, 0.9, "scale \(scale)")

            // Both stems reach the image's sides, the shoulders its top, the feet its
            // bottom.
            XCTAssertTrue((0..<height).contains { alpha(bitmap, 0, $0) > 0 }, "left, \(scale)x")
            XCTAssertTrue((0..<height).contains { alpha(bitmap, width - 1, $0) > 0 }, "right, \(scale)x")
            XCTAssertTrue((0..<width).contains { alpha(bitmap, $0, 0) > 0 }, "top, \(scale)x")
            XCTAssertTrue((0..<width).contains { alpha(bitmap, $0, height - 1) > 0 }, "bottom, \(scale)x")
            // The notch between the shoulders is open.
            XCTAssertEqual(alpha(bitmap, width / 2, 0), 0, "notch, \(scale)x")
        }
    }

    func testPathAtNaturalSizeFillsItsRectAndLeavesTheMsOpeningsEmpty() {
        let rect = CGRect(x: 0, y: 0, width: 565, height: 390)
        let path = MectricsGlyph.path(in: rect)
        XCTAssertFalse(path.isEmpty)
        assertBox(path.boundingBoxOfPath, equals: rect, accuracy: 0.5)

        // Ink: both stems, halfway up.
        XCTAssertTrue(path.contains(CGPoint(x: 35, y: 195)))
        XCTAssertTrue(path.contains(CGPoint(x: 530, y: 195)))
        // Empty: the notch between the shoulders and the space under the valley.
        XCTAssertFalse(path.contains(CGPoint(x: 282.5, y: 40)))
        XCTAssertFalse(path.contains(CGPoint(x: 282.5, y: 385)))
        // Empty: between a stem and the valley's underside.
        XCTAssertFalse(path.contains(CGPoint(x: 120, y: 380)))
    }

    /// Aspect-fit and centered in any rect, wider or taller than the M.
    func testPathIsAspectFittedAndCenteredInItsRect() {
        let rects = [
            CGRect(x: 10, y: 20, width: 200, height: 50),
            CGRect(x: -30, y: 5, width: 50, height: 200),
            CGRect(x: 3, y: 4, width: 20, height: 14),
            CGRect(x: 0, y: 0, width: 1130, height: 780)
        ]
        for rect in rects {
            let box = MectricsGlyph.path(in: rect).boundingBoxOfPath
            let accuracy = max(rect.width, rect.height) * 0.002
            XCTAssertGreaterThanOrEqual(box.minX, rect.minX - accuracy, "\(rect)")
            XCTAssertGreaterThanOrEqual(box.minY, rect.minY - accuracy, "\(rect)")
            XCTAssertLessThanOrEqual(box.maxX, rect.maxX + accuracy, "\(rect)")
            XCTAssertLessThanOrEqual(box.maxY, rect.maxY + accuracy, "\(rect)")
            XCTAssertEqual(box.midX, rect.midX, accuracy: accuracy, "\(rect)")
            XCTAssertEqual(box.midY, rect.midY, accuracy: accuracy, "\(rect)")
            XCTAssertEqual(box.width / box.height, MectricsGlyph.aspectRatio, accuracy: 0.01, "\(rect)")
            // One side fills the rect.
            XCTAssertTrue(
                abs(box.width - rect.width) <= accuracy || abs(box.height - rect.height) <= accuracy,
                "\(rect) → \(box)"
            )
        }
    }

    /// The pink tip is the bottom of the right stem, cut from the outline itself.
    func testTipIsTheBottomOfTheRightStemInsideTheOutline() {
        for rect in [
            CGRect(x: 0, y: 0, width: 565, height: 390),
            CGRect(x: 12, y: 7, width: 90, height: 90)
        ] {
            let outline = MectricsGlyph.path(in: rect)
            let tip = MectricsGlyph.tipPath(in: rect)
            XCTAssertFalse(tip.isEmpty, "\(rect)")

            let glyph = outline.boundingBoxOfPath
            let box = tip.boundingBoxOfPath
            let accuracy = glyph.width * 0.002
            XCTAssertGreaterThanOrEqual(box.minX, glyph.minX - accuracy, "\(rect)")
            XCTAssertLessThanOrEqual(box.maxX, glyph.maxX + accuracy, "\(rect)")
            XCTAssertGreaterThanOrEqual(box.minY, glyph.minY - accuracy, "\(rect)")
            XCTAssertLessThanOrEqual(box.maxY, glyph.maxY + accuracy, "\(rect)")

            // On the right stem, reaching the foot, about a quarter of the M's height.
            XCTAssertGreaterThan(box.minX, glyph.midX, "\(rect)")
            XCTAssertEqual(box.maxX, glyph.maxX, accuracy: accuracy, "\(rect)")
            XCTAssertEqual(box.maxY, glyph.maxY, accuracy: accuracy, "\(rect)")
            XCTAssertLessThan(box.width, glyph.width * 0.2, "\(rect)")
            XCTAssertGreaterThan(box.height, glyph.height * 0.15, "\(rect)")
            XCTAssertLessThan(box.height, glyph.height * 0.4, "\(rect)")

            let center = CGPoint(x: box.midX, y: box.midY)
            XCTAssertTrue(tip.contains(center), "\(rect)")
            XCTAssertTrue(outline.contains(center), "\(rect)")
        }
    }

    // MARK: - The logo as the health item

    /// The single icon is also the health item, and the item reserves a fixed width, so
    /// a badge must not make the mark any bigger. A logo that grew when something went
    /// wrong would move every item after it — the one thing the menu bar may never do.
    @MainActor
    func testBadgingTheLogoNeverChangesItsSize() {
        let plain = MectricsGlyph.menuBarImage.size
        for state in HealthState.allCases where state != .normal {
            let badged = Self.badged(state)
            XCTAssertEqual(badged.size, plain, "\(state.rawValue)")
            // Two colours, so it is deliberately not a template: AppKit must not
            // recolour the badge and the M as one silhouette.
            XCTAssertFalse(badged.isTemplate, "\(state.rawValue)")
        }
    }

    /// No state, no badge: nothing is wrong, so the mark is the plain shared logo and
    /// not a second image that merely looks like it.
    @MainActor
    func testNoBadgeIsThePlainSharedLogo() {
        XCTAssertIdentical(
            MectricsGlyph.menuBarImage(
                badge: nil,
                tint: HealthState.warning.tint,
                appearance: Self.appearance
            ),
            MectricsGlyph.menuBarImage
        )
    }

    /// Built once per symbol. The badge changes on a severity transition, not on a
    /// sampling cycle, so this stays off the per-cycle path either way — but drawing it
    /// again on every read would undo that.
    @MainActor
    func testBadgedLogosAreBuiltOncePerState() {
        XCTAssertIdentical(
            Self.badged(.critical),
            Self.badged(.critical)
        )
    }

    /// Each state has to be legible as a shape, because colour alone is not a signal
    /// someone with any colour vision, or a tinted menu bar, can rely on. Every badged
    /// mark differs from the plain logo, and no two states draw the same thing.
    @MainActor
    func testEveryHealthStateDrawsItsOwnMark() throws {
        var inkedPixels: [String: [Bool]] = [:]
        let plain = try coverage(of: MectricsGlyph.menuBarImage)
        for state in HealthState.allCases where state != .normal {
            let mark = try coverage(of: Self.badged(state))
            XCTAssertNotEqual(mark, plain, "\(state.rawValue) is invisible")
            for (other, otherMark) in inkedPixels {
                XCTAssertNotEqual(
                    mark,
                    otherMark,
                    "\(state.rawValue) and \(other) draw the same mark"
                )
            }
            inkedPixels[state.rawValue] = mark
        }
        XCTAssertEqual(inkedPixels.count, HealthState.allCases.count - 1)
    }

    /// The badge is punched out of the M rather than laid on top of it, so the two read
    /// as two marks. A badged logo therefore inks *less* of its trailing-bottom corner
    /// than a plain one does at the gap, while still inking the corner itself.
    @MainActor
    func testTheBadgeIsSetApartFromTheM() throws {
        let badged = try render(Self.badged(.warning), scale: 2)
        let plain = try render(MectricsGlyph.menuBarImage, scale: 2)
        let width = badged.pixelsWide, height = badged.pixelsHigh

        // The badge lives in the trailing-bottom quarter, and draws something there.
        // Not the corner pixel itself: a triangle leaves its bounding box's corners
        // empty, which is the shape doing its job.
        let quadrant = (width / 2..<width).flatMap { x in
            (height / 2..<height).map { (x, $0) }
        }
        XCTAssertTrue(
            quadrant.contains { alpha(badged, $0.0, $0.1) > 0 },
            "The badge drew nothing"
        )
        // And the M has been cut away around it, so the two read as two marks rather
        // than one blob.
        XCTAssertTrue(
            quadrant.contains {
                alpha(plain, $0.0, $0.1) > 0 && alpha(badged, $0.0, $0.1) == 0
            },
            "The badge was drawn over the M, not set apart from it"
        )
    }

    /// The severity colour belongs to the badge, never to the M.
    ///
    /// Painting the whole mark made the logo *harder* to see exactly when it had
    /// something to say: a template M is drawn near-white on a dark menu bar, and a
    /// solid letter in orange reads as dimmer than the white one it replaced. The M
    /// therefore stays achromatic — the menu bar's own label colour — and only the badge
    /// is tinted. Saturation is the property that says so, in either theme.
    @MainActor
    func testOnlyTheBadgeCarriesTheSeverityColour() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let state = HealthState.critical
            let bitmap = try render(
                MectricsGlyph.menuBarImage(
                    badge: state.symbolName,
                    tint: state.tint,
                    appearance: appearance
                ),
                scale: 2
            )
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh

            // The M, sampled in the leading half and clear of the badge's quadrant.
            let markPixels = (0..<width / 2).flatMap { x in
                (0..<height / 2).compactMap { y -> NSColor? in
                    // `labelColor` is not fully opaque (0.85), so a threshold above
                    // that would find no M at all.
                    guard alpha(bitmap, x, y) > 0.5 else { return nil }
                    return bitmap.colorAt(x: x, y: y)
                }
            }
            XCTAssertFalse(markPixels.isEmpty, "\(name.rawValue): the M drew nothing")
            for colour in markPixels {
                XCTAssertLessThan(
                    colour.saturationComponent,
                    0.2,
                    "\(name.rawValue): the M was painted the severity colour"
                )
            }

            // The badge, in the trailing-bottom quadrant, is where the colour lives.
            let badgePixels = (width / 2..<width).flatMap { x in
                (height / 2..<height).compactMap { y -> NSColor? in
                    guard alpha(bitmap, x, y) > 0.5 else { return nil }
                    return bitmap.colorAt(x: x, y: y)
                }
            }
            XCTAssertTrue(
                badgePixels.contains { $0.saturationComponent > 0.4 },
                "\(name.rawValue): the badge carried no colour"
            )
        }
    }

    /// The mark is drawn for one appearance, so a Mac changing theme has to get a new
    /// one — otherwise a dark-mode M stays white on a light menu bar.
    ///
    /// `.unavailable` is the state that proves it: its tint is `secondaryLabelColor`, a
    /// dynamic colour. Resolving it against whatever appearance happened to be current
    /// rather than the target one drew a light-grey badge onto a light menu bar, where
    /// it all but disappeared. Both themes are checked by what they actually draw, not
    /// by holding two different objects.
    @MainActor
    func testBothColoursAreResolvedForTheTargetAppearance() throws {
        for state in [HealthState.unavailable, .critical] {
            var drawn: [NSAppearance.Name: [NSColor]] = [:]
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let bitmap = try render(
                    MectricsGlyph.menuBarImage(
                        badge: state.symbolName,
                        tint: state.tint,
                        appearance: try XCTUnwrap(NSAppearance(named: name))
                    ),
                    scale: 2
                )
                drawn[name] = (0..<bitmap.pixelsWide).flatMap { x in
                    (0..<bitmap.pixelsHigh).compactMap { y in
                        alpha(bitmap, x, y) > 0.5 ? bitmap.colorAt(x: x, y: y) : nil
                    }
                }
            }
            let light = try XCTUnwrap(drawn[.aqua])
            let dark = try XCTUnwrap(drawn[.darkAqua])
            // The M alone guarantees this: near-black in one theme, near-white in the
            // other. A mark drawn for the wrong appearance would match.
            XCTAssertNotEqual(
                light.map(\.brightnessComponent),
                dark.map(\.brightnessComponent),
                "\(state.rawValue) drew the same mark for both themes"
            )
        }
    }

    // MARK: - Uptime

    /// Uptime counts from boot, sleep included, so it can never be less than the time
    /// the Mac has been awake.
    func testUptimeSinceBootIsPositiveAndNeverBehindTheAwakeTime() throws {
        let bootDate = try XCTUnwrap(SystemUptime.bootDate)
        XCTAssertLessThan(bootDate, Date())

        let awake = ProcessInfo.processInfo.systemUptime
        let sinceBoot = SystemUptime.sinceBoot
        XCTAssertGreaterThan(sinceBoot, 0)
        XCTAssertGreaterThanOrEqual(sinceBoot, awake - 5)
        XCTAssertGreaterThanOrEqual(SystemUptime.sinceBoot, sinceBoot)
    }

    // MARK: - Helpers

    /// The appearance the badged marks are drawn for in these tests.
    private static let appearance =
        NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()

    @MainActor
    private static func badged(_ state: HealthState) -> NSImage {
        MectricsGlyph.menuBarImage(
            badge: state.symbolName,
            tint: state.tint,
            appearance: appearance
        )
    }

    private func render(_ image: NSImage, scale: CGFloat) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((image.size.width * scale).rounded()),
            pixelsHigh: Int((image.size.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = image.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Row 0 is the top row.
    private func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    /// Which pixels an image inks, as a comparable shape independent of colour.
    private func coverage(of image: NSImage) throws -> [Bool] {
        let bitmap = try render(image, scale: 2)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in alpha(bitmap, x, y) > 0 }
        }
    }

    private func assertBox(
        _ box: CGRect,
        equals expected: CGRect,
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(box.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.maxX, expected.maxX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(box.maxY, expected.maxY, accuracy: accuracy, file: file, line: line)
    }
}
