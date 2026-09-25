import AppKit
import MetricsKit
import XCTest
@testable import Mectrics

/// The dashboard grid's layout and what each card states besides its large reading.
final class DashboardCardTests: XCTestCase {
    private let gigabyte = 1024.0 * 1024 * 1024

    // MARK: - Layout

    /// With nothing chosen the grid says why it is empty instead of showing nothing.
    func testNoModulesShowTheDeviceBesideTheEmptyHint() {
        XCTAssertEqual(DashboardLayout.cards(for: []), [.device, .emptyHint])
        XCTAssertEqual(DashboardLayout.rows(for: []), [[.device, .emptyHint]])
    }

    func testTheDeviceFollowsTheChosenModulesInTheirOrder() {
        XCTAssertEqual(
            DashboardLayout.cards(for: [.cpu, .network, .memory]),
            [.module(.cpu), .module(.network), .module(.memory), .device]
        )
        XCTAssertEqual(
            DashboardLayout.rows(for: [.cpu]),
            [[.module(.cpu), .device]]
        )
    }

    /// An odd number of cards leaves the last row one card short, so its second cell
    /// stays empty rather than stretching the card.
    func testAnOddCardCountLeavesTheLastCellEmpty() {
        XCTAssertEqual(
            DashboardLayout.rows(for: [.cpu, .memory]),
            [[.module(.cpu), .module(.memory)], [.device]]
        )
        XCTAssertEqual(
            DashboardLayout.rows(for: MenuBarStyle.defaultDashboardModules),
            [
                [.module(.cpu), .module(.memory)],
                [.module(.battery), .module(.network)],
                [.module(.disk), .device]
            ]
        )
    }

    func testRowsHoldEveryCardOnceInOrderAndOnlyTheLastRowMayBeShort() {
        let modules: [MetricID] = [.cpu, .memory, .battery, .network, .disk, .gpu, .fans]
        for count in 0...modules.count {
            let chosen = Array(modules.prefix(count))
            let cards = DashboardLayout.cards(for: chosen)
            let rows = DashboardLayout.rows(for: chosen)

            XCTAssertEqual(rows.flatMap { $0 }, cards, "\(count) modules")
            XCTAssertEqual(rows.count, (cards.count + 1) / 2, "\(count) modules")
            for row in rows.dropLast() {
                XCTAssertEqual(row.count, 2, "\(count) modules")
            }
            XCTAssertTrue((1...2).contains(rows.last?.count ?? 0), "\(count) modules")
            XCTAssertEqual(cards.filter { $0 == .device }.count, 1, "\(count) modules")
            XCTAssertEqual(cards.contains(.emptyHint), chosen.isEmpty, "\(count) modules")
            if !chosen.isEmpty {
                XCTAssertEqual(cards.last, .device, "\(count) modules")
            }
        }
    }

    /// Two columns and the gap between them fill the popover inside its padding.
    @MainActor
    func testTwoCardsAndTheirGapFillThePopoverWidth() {
        XCTAssertEqual(DashboardPopoverView.width, 320)
        XCTAssertEqual(
            2 * DashboardPopoverView.cardWidth
                + DashboardPopoverView.cardSpacing
                + 2 * DashboardPopoverView.padding,
            DashboardPopoverView.width,
            accuracy: 0.001
        )
    }

    // MARK: - Absence is not zero

    /// A sample whose detail carries nothing yields no fact at all: no "0 cores", no
    /// "0.0 B / 0.0 B", no "0m" left, no "0%" health.
    func testMissingDetailKeysYieldNoFabricatedFacts() {
        for id in MetricID.allCases where id != .battery {
            XCTAssertEqual(facts(id), DashboardCardFacts(), "\(id)")
        }
        // Battery always knows where its power comes from, and nothing else here.
        let battery = facts(.battery)
        XCTAssertEqual(battery.caption, [BatteryPowerStatus.onBattery.localizedName])
        XCTAssertEqual(battery.chips, [])
        XCTAssertEqual(battery.footer, [])
    }

    /// Zero cores, zero fans, or zero bytes of GPU memory are not facts worth stating.
    func testZeroCountsAreLeftOutRatherThanStated() {
        XCTAssertEqual(facts(.cpu, ["coreCount": 0]), DashboardCardFacts())
        XCTAssertEqual(facts(.fans, ["fanCount": 0]), DashboardCardFacts())
        XCTAssertEqual(facts(.gpu, ["inUseMemory": 0]), DashboardCardFacts())
        // Without a total there is nothing to be a share of.
        XCTAssertEqual(facts(.memory, ["used": 8 * gigabyte, "total": 0]), DashboardCardFacts())
        XCTAssertEqual(facts(.disk, ["used": 8 * gigabyte]), DashboardCardFacts())
        XCTAssertEqual(facts(.disk, ["total": 8 * gigabyte]), DashboardCardFacts())
    }

    // MARK: - Facts per module

    func testCPUStatesItsCoresAndATemperatureOnlyWhenRead() {
        let cores = facts(.cpu, ["coreCount": 10])
        XCTAssertEqual(cores.caption.count, 1)
        XCTAssertTrue(cores.caption[0].contains("10"), cores.caption[0])

        let warm = facts(.cpu, ["coreCount": 10], temperature: 63.6)
        XCTAssertEqual(warm.caption.count, 2)
        XCTAssertEqual(warm.caption.last, "64°C")
        XCTAssertEqual(warm.captionText, "\(warm.caption[0]) · 64°C")

        XCTAssertEqual(facts(.cpu, temperature: 41).caption, ["41°C"])
    }

    func testGPUStatesMemoryInUseAndItsTemperature() {
        let gpu = facts(.gpu, ["inUseMemory": 1.5 * gigabyte], temperature: 52.2)
        XCTAssertEqual(gpu.caption.count, 2)
        XCTAssertTrue(gpu.caption[0].contains("1.5 GB"), gpu.caption[0])
        XCTAssertEqual(gpu.caption[1], "52°C")
    }

    func testMemoryStatesUsedOfTotalPressureAndSwap() throws {
        let memory = facts(.memory, [
            "used": 13.6 * gigabyte,
            "total": 16 * gigabyte,
            "pressureLevel": Double(MemoryPressureLevel.warning.rawValue),
            "swapTotal": 2 * gigabyte,
            "swapUsed": 512 * 1024 * 1024
        ])
        XCTAssertEqual(
            memory.caption,
            [DashboardFormat.usedOfTotal(used: 13.6 * gigabyte, total: 16 * gigabyte)]
        )
        XCTAssertEqual(memory.chips.map(\.text), [
            MemoryPressureLevel.warning.localizedName,
            "512.0 MB"
        ])
        for chip in memory.chips {
            let label = try XCTUnwrap(chip.label)
            XCTAssertEqual(chip.spoken, DashboardFormat.spokenList([label, chip.text]))
        }
    }

    /// A pressure level the kernel does not define is not guessed at, and swap is
    /// only stated when there is a swap file to be using.
    func testMemoryLeavesOutUndefinedPressureAndAbsentSwap() {
        XCTAssertEqual(facts(.memory, ["pressureLevel": 0]).chips, [])
        XCTAssertEqual(facts(.memory, ["pressureLevel": 3]).chips, [])
        XCTAssertEqual(facts(.memory, ["swapTotal": 0, "swapUsed": 0]).chips, [])
        XCTAssertEqual(facts(.memory, ["swapTotal": 2 * gigabyte]).chips, [])
        XCTAssertEqual(facts(.memory, ["swapUsed": 1024]).chips, [])
        // Swap that exists but is unused is a fact: none of it in use.
        XCTAssertEqual(
            facts(.memory, ["swapTotal": 2 * gigabyte, "swapUsed": 0]).chips.map(\.text),
            ["0.0 B"]
        )
    }

    func testDiskStatesUsedOfTotalAndTheStartupVolumeWhenKnown() {
        let detail = ["used": 200 * gigabyte, "total": 494.4 * gigabyte]
        let named = facts(
            .disk,
            detail,
            systemInfo: DashboardSystemInfo(startupVolumeName: "Macintosh HD")
        )
        XCTAssertEqual(
            named.caption,
            [DashboardFormat.usedOfTotal(used: 200 * gigabyte, total: 494.4 * gigabyte)]
        )
        XCTAssertEqual(named.chips, [DashboardChipFact(text: "Macintosh HD")])
        XCTAssertEqual(named.chips[0].spoken, "Macintosh HD")

        XCTAssertEqual(facts(.disk, detail).chips, [])
    }

    func testBatteryStatesItsStatusEstimateAndHealth() throws {
        let charging = facts(
            .battery,
            ["charging": 1, "timeToFull": 135, "healthPercent": 87],
            isOnBattery: false
        )
        XCTAssertEqual(charging.caption, [BatteryPowerStatus.charging.localizedName])
        XCTAssertEqual(charging.chips.count, 2)
        XCTAssertEqual(charging.chips[0].text, DashboardFormat.duration(minutes: 135))
        XCTAssertEqual(charging.chips[0].label, BatteryPowerStatus.charging.estimateLabel)
        XCTAssertEqual(charging.chips[1].text, "87%")
        XCTAssertNotNil(charging.chips[1].label)

        let draining = facts(.battery, ["timeToEmpty": 300], isOnBattery: true)
        XCTAssertEqual(draining.caption, [BatteryPowerStatus.onBattery.localizedName])
        XCTAssertEqual(draining.chips.map(\.text), [DashboardFormat.duration(minutes: 300)])
        XCTAssertEqual(draining.chips[0].label, BatteryPowerStatus.onBattery.estimateLabel)
    }

    /// "Calculating" and a Mac held at its charge limit both have no estimate chip —
    /// never one reading "0m".
    func testBatteryWithoutAnEstimateShowsNoEstimateChip() {
        let calculating = facts(
            .battery,
            ["timeToEmpty": 0, "smartTimeRemaining": 0],
            isOnBattery: true
        )
        XCTAssertEqual(calculating.chips, [])

        let held = facts(
            .battery,
            ["charging": 0, "timeToFull": 30, "smartTimeRemaining": 30],
            isOnBattery: false
        )
        XCTAssertEqual(held.caption, [BatteryPowerStatus.pluggedIn.localizedName])
        XCTAssertEqual(held.chips, [])
    }

    func testNetworkNamesTheInterfaceAndLocalAddressBelowTheRates() {
        let wifi = DashboardSystemInfo(
            localAddress: "192.168.1.20",
            interfaceName: "Wi-Fi",
            interfaceSymbol: "wifi"
        )
        let named = facts(.network, ["down": 1024, "up": 512], systemInfo: wifi)
        XCTAssertEqual(named.footer, ["Wi-Fi", "192.168.1.20"])
        XCTAssertEqual(named.caption, [])
        XCTAssertEqual(named.chips, [])
        XCTAssertEqual(named.spoken, ["Wi-Fi", "192.168.1.20"])

        let unnamed = facts(
            .network,
            systemInfo: DashboardSystemInfo(localAddress: "10.0.0.2")
        )
        XCTAssertEqual(unnamed.footer, ["10.0.0.2"])

        // An interface without an address says nothing.
        let offline = facts(
            .network,
            systemInfo: DashboardSystemInfo(interfaceName: "Wi-Fi")
        )
        XCTAssertEqual(offline.footer, [])
    }

    func testFansStateHowManyThereAre() {
        let fans = facts(.fans, ["fanCount": 2, "maxRpm": 2400])
        XCTAssertEqual(fans.caption.count, 1)
        XCTAssertTrue(fans.caption[0].contains("2"), fans.caption[0])
        XCTAssertEqual(fans.chips, [])
    }

    // MARK: - Reading order

    /// VoiceOver reads exactly what the card draws: caption, then chips, then footer.
    func testSpokenFactsFollowTheCardsReadingOrder() {
        let facts = DashboardCardFacts(
            caption: ["10 cores", "64°C"],
            chips: [
                DashboardChipFact(text: "Macintosh HD"),
                DashboardChipFact(symbol: "heart", text: "87%", label: "Health")
            ],
            footer: ["Wi-Fi", "192.168.1.20"]
        )
        XCTAssertEqual(facts.captionText, "10 cores · 64°C")
        XCTAssertEqual(facts.spoken, [
            "10 cores",
            "64°C",
            "Macintosh HD",
            DashboardFormat.spokenList(["Health", "87%"]),
            "Wi-Fi",
            "192.168.1.20"
        ])
        XCTAssertNil(DashboardCardFacts().captionText)
        XCTAssertEqual(DashboardCardFacts().spoken, [])
    }

    /// A chip symbol that does not exist draws nothing, leaving a gap before its text.
    func testEveryChipSymbolIsARealSFSymbol() {
        var chips: [DashboardChipFact] = []
        for level in MemoryPressureLevel.allCases {
            chips += facts(.memory, [
                "pressureLevel": Double(level.rawValue),
                "swapTotal": gigabyte,
                "swapUsed": 1024
            ]).chips
        }
        chips += facts(
            .battery,
            ["charging": 1, "timeToFull": 30, "healthPercent": 90],
            isOnBattery: false
        ).chips
        chips += facts(.battery, ["timeToEmpty": 30], isOnBattery: true).chips

        let symbols = Set(chips.compactMap(\.symbol))
        XCTAssertGreaterThanOrEqual(symbols.count, 5)
        for symbol in symbols.union([DashboardSystemInfo().interfaceSymbol]) {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) is not an SF Symbol on this macOS"
            )
        }
    }

    // MARK: - System info

    /// Nothing is known until the popover reads it.
    func testSystemInfoStartsEmpty() {
        let info = DashboardSystemInfo()
        XCTAssertNil(info.localAddress)
        XCTAssertNil(info.interfaceName)
        XCTAssertNil(info.startupVolumeName)
        XCTAssertEqual(info.interfaceSymbol, "network")
    }

    /// Read-only system facts: an address always comes with the interface it is on,
    /// and the startup volume has a name.
    @MainActor
    func testSystemInfoNamesTheInterfaceOfEveryAddressItFinds() throws {
        let info = DashboardSystemInfo.read()
        if info.localAddress != nil {
            let name = try XCTUnwrap(info.interfaceName)
            XCTAssertFalse(name.isEmpty)
        } else {
            XCTAssertNil(info.interfaceName)
        }
        let volume = try XCTUnwrap(info.startupVolumeName)
        XCTAssertFalse(volume.isEmpty)
    }

    // MARK: - Helpers

    private func facts(
        _ id: MetricID,
        _ detail: [String: Double] = [:],
        temperature: Double? = nil,
        systemInfo: DashboardSystemInfo = DashboardSystemInfo(),
        isOnBattery: Bool? = nil
    ) -> DashboardCardFacts {
        DashboardCardFacts.make(
            for: id,
            sample: MetricSample(value: 0.5, detail: detail),
            temperature: temperature,
            systemInfo: systemInfo,
            isOnBattery: isOnBattery
        )
    }
}
