import AppKit
import MetricsKit
import XCTest
@testable import Mectrics

/// The single-icon style's pure pieces: which modules each style watches, when the
/// menu bar has to be rebuilt, the logo item's slot, and the logo itself.
///
/// Nothing here creates a status item or an `AppModel`: either would touch the real
/// menu bar or the user's real preferences.
final class SingleIconMenuBarTests: XCTestCase {
    private let laptop: [MetricID] = [.cpu, .memory, .battery, .network, .disk, .gpu, .fans]
    private let desktop: [MetricID] = [.cpu, .memory, .network, .disk, .gpu]

    // MARK: - MenuBarStyle

    /// The raw values are what `"menuBarStyle"` holds, so renaming a case would reset
    /// everyone's choice on update.
    func testRawValuesArePersistedAndThereforeNeverChange() {
        XCTAssertEqual(MenuBarStyle.items.rawValue, "items")
        XCTAssertEqual(MenuBarStyle.singleIcon.rawValue, "singleIcon")
        XCTAssertEqual(MenuBarStyle(rawValue: "items"), .items)
        XCTAssertEqual(MenuBarStyle(rawValue: "singleIcon"), .singleIcon)
        // An absent or unknown value has no style; AppModel then falls back to items.
        XCTAssertNil(MenuBarStyle(rawValue: ""))
        XCTAssertNil(MenuBarStyle(rawValue: "SingleIcon"))
        for style in MenuBarStyle.allCases {
            XCTAssertEqual(style.id, style.rawValue)
        }
    }

    /// Separate items come first: it is the default and the Settings picker's order.
    func testSeparateItemsLeadTheStylesBecauseTheyAreTheDefault() {
        XCTAssertEqual(MenuBarStyle.allCases, [.items, .singleIcon])
    }

    func testEveryStyleHasItsOwnNameAndDescription() {
        let names = MenuBarStyle.allCases.map(\.localizedName)
        let descriptions = MenuBarStyle.allCases.map(\.localizedDescription)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertFalse(descriptions.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, MenuBarStyle.allCases.count)
        XCTAssertEqual(Set(descriptions).count, MenuBarStyle.allCases.count)
    }

    func testSeparateItemsWatchModulesWithAComponentAndIgnoreTheDashboard() {
        let watched = MenuBarStyle.watchedModules(
            style: .items,
            available: desktop,
            enabledComponents: [
                .cpu: [.value],
                .memory: [],
                .network: [.netActivity, .netDown],
                // Not on this Mac: a stored component never makes it watched.
                .battery: [.batteryIcon]
            ],
            dashboardModules: [.disk, .gpu]
        )
        XCTAssertEqual(watched, [.cpu, .network])
    }

    func testTheSingleIconWatchesTheDashboardAndIgnoresComponents() {
        let watched = MenuBarStyle.watchedModules(
            style: .singleIcon,
            available: desktop,
            enabledComponents: [.cpu: [.value], .memory: [.value]],
            // Battery and Fans are not on this desktop.
            dashboardModules: [.disk, .gpu, .battery, .fans]
        )
        XCTAssertEqual(watched, [.disk, .gpu])
    }

    /// An empty dashboard is a choice: the components left over from separate items
    /// must not start being sampled behind it.
    func testAnEmptyDashboardWatchesNothingWhateverTheComponentsSay() {
        XCTAssertEqual(
            MenuBarStyle.watchedModules(
                style: .singleIcon,
                available: laptop,
                enabledComponents: [.cpu: [.value], .battery: [.batteryIcon]],
                dashboardModules: []
            ),
            []
        )
        XCTAssertEqual(
            MenuBarStyle.watchedModules(
                style: .items,
                available: laptop,
                enabledComponents: [:],
                dashboardModules: Set(laptop)
            ),
            []
        )
    }

    func testSeparateItemKeysNameEachModuleAndComponentInDisplayOrder() {
        let items: [(module: MetricID, component: MenuBarComponent)] = [
            (.cpu, .value),
            (.cpu, .temperature),
            (.network, .netActivity),
            (.battery, .batteryIcon)
        ]
        XCTAssertEqual(
            MenuBarStyle.itemKeys(style: .items, orderedItems: items),
            ["cpu|value", "cpu|temperature", "network|netActivity", "battery|batteryIcon"]
        )
        XCTAssertEqual(MenuBarStyle.itemKeys(style: .items, orderedItems: []), [])
    }

    /// The logo is not a metric item, so under the single icon a component appearing
    /// (a temperature discovered mid-session) must never rebuild the menu bar.
    func testTheSingleIconHasNoMetricItemsBecauseTheLogoIsNotOne() {
        let before: [(module: MetricID, component: MenuBarComponent)] = [(.cpu, .value)]
        let after = before + [(module: MetricID.cpu, component: MenuBarComponent.temperature)]
        XCTAssertEqual(MenuBarStyle.itemKeys(style: .singleIcon, orderedItems: before), [])
        XCTAssertEqual(
            MenuBarStyle.itemKeys(style: .singleIcon, orderedItems: before),
            MenuBarStyle.itemKeys(style: .singleIcon, orderedItems: after)
        )
        XCTAssertNotEqual(
            MenuBarStyle.itemKeys(style: .items, orderedItems: before),
            MenuBarStyle.itemKeys(style: .items, orderedItems: after)
        )
    }

    /// GPU and Fans are `.heavy` SMC/IOKit providers, so the dashboard offers them but
    /// never turns them on for someone who has not chosen.
    func testDefaultDashboardModulesLeaveOutTheHeavyProviders() {
        XCTAssertEqual(
            MenuBarStyle.defaultDashboardModules,
            [.cpu, .memory, .battery, .network, .disk]
        )
        XCTAssertEqual(
            Set(MenuBarStyle.defaultDashboardModules).count,
            MenuBarStyle.defaultDashboardModules.count,
            "No module may appear twice"
        )
        for heavy in [MetricID.gpu, .fans, .sensors] {
            XCTAssertFalse(MenuBarStyle.defaultDashboardModules.contains(heavy), "\(heavy)")
        }

        let defaultProviders: [any MetricProvider] = [
            CPUProvider(), MemoryProvider(), BatteryProvider(), NetworkProvider(), DiskProvider()
        ]
        XCTAssertEqual(defaultProviders.map(\.id), MenuBarStyle.defaultDashboardModules)
        for provider in defaultProviders {
            XCTAssertNotEqual(provider.cost, .heavy, "\(provider.id) is sampled as heavy")
        }
        XCTAssertEqual(GPUProvider().cost, .heavy)
    }

    func testNothingStoredMeansTheDefaultsThisMacCanReport() {
        XCTAssertEqual(
            MenuBarStyle.dashboardModules(stored: nil, available: laptop),
            [.cpu, .memory, .battery, .network, .disk]
        )
        // No battery on a desktop, and GPU is available but never a default.
        XCTAssertEqual(
            MenuBarStyle.dashboardModules(stored: nil, available: desktop),
            [.cpu, .memory, .network, .disk]
        )
        XCTAssertEqual(MenuBarStyle.dashboardModules(stored: nil, available: []), [])
    }

    func testStoredModulesDropUnknownAndUnavailableValues() {
        XCTAssertEqual(
            MenuBarStyle.dashboardModules(
                stored: ["gpu", "battery", "bogus", "CPU", "", "disk", "disk"],
                available: desktop
            ),
            [.gpu, .disk]
        )
    }

    /// Turning every card off must survive a relaunch rather than bring the defaults
    /// back.
    func testAnEmptyStoredListStaysEmptyBecauseItIsAChoice() {
        XCTAssertEqual(MenuBarStyle.dashboardModules(stored: [], available: laptop), [])
    }

    /// AppModel stores the set as sorted raw values; reading that back through a real
    /// defaults domain has to give the same set.
    func testDashboardModulesRoundTripThroughTheStoredFormat() throws {
        let suiteName = "SingleIconMenuBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for chosen: Set<MetricID> in [[], [.gpu], [.cpu, .fans, .network], Set(laptop)] {
            defaults.set(chosen.map(\.rawValue).sorted(), forKey: "dashboardModules")
            XCTAssertEqual(
                MenuBarStyle.dashboardModules(
                    stored: defaults.array(forKey: "dashboardModules") as? [String],
                    available: laptop
                ),
                chosen
            )
        }
        defaults.removeObject(forKey: "dashboardModules")
        XCTAssertEqual(
            MenuBarStyle.dashboardModules(
                stored: defaults.array(forKey: "dashboardModules") as? [String],
                available: laptop
            ),
            Set(MenuBarStyle.defaultDashboardModules)
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
        for state in CompactHealthState.allCases where state != .normal {
            let badged = MectricsGlyph.menuBarImage(badge: state.symbolName)
            XCTAssertEqual(badged.size, plain, "\(state.rawValue)")
            XCTAssertTrue(badged.isTemplate, "\(state.rawValue)")
        }
    }

    /// No state, no badge: nothing is wrong, so the mark is the plain shared logo and
    /// not a second image that merely looks like it.
    @MainActor
    func testNoBadgeIsThePlainSharedLogo() {
        XCTAssertIdentical(
            MectricsGlyph.menuBarImage(badge: nil),
            MectricsGlyph.menuBarImage
        )
    }

    /// Built once per symbol. The badge changes on a severity transition, not on a
    /// sampling cycle, so this stays off the per-cycle path either way — but drawing it
    /// again on every read would undo that.
    @MainActor
    func testBadgedLogosAreBuiltOncePerState() {
        let symbol = CompactHealthState.critical.symbolName
        XCTAssertIdentical(
            MectricsGlyph.menuBarImage(badge: symbol),
            MectricsGlyph.menuBarImage(badge: symbol)
        )
    }

    /// Each state has to be legible as a shape, because colour alone is not a signal
    /// someone with any colour vision, or a tinted menu bar, can rely on. Every badged
    /// mark differs from the plain logo, and no two states draw the same thing.
    @MainActor
    func testEveryHealthStateDrawsItsOwnMark() throws {
        var inkedPixels: [String: [Bool]] = [:]
        let plain = try coverage(of: MectricsGlyph.menuBarImage)
        for state in CompactHealthState.allCases where state != .normal {
            let mark = try coverage(
                of: MectricsGlyph.menuBarImage(badge: state.symbolName)
            )
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
        XCTAssertEqual(inkedPixels.count, CompactHealthState.allCases.count - 1)
    }

    /// The badge is punched out of the M rather than laid on top of it, so the two read
    /// as two marks. A badged logo therefore inks *less* of its trailing-bottom corner
    /// than a plain one does at the gap, while still inking the corner itself.
    @MainActor
    func testTheBadgeIsSetApartFromTheM() throws {
        let badged = try render(
            MectricsGlyph.menuBarImage(badge: CompactHealthState.warning.symbolName),
            scale: 2
        )
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
