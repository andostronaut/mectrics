import AppKit
import MetricsKit
import XCTest
@testable import Mectrics

/// The dashboard's and the module detail's readings as text, and where a battery Mac
/// draws its power from.
final class DashboardFormatTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    private let gigabyte = 1024.0 * 1024 * 1024

    // MARK: - Readings

    /// Absence is not zero: without a sample every module shows the dash.
    func testEveryModuleShowsTheDashWithoutASample() {
        XCTAssertEqual(DashboardFormat.missingValue, "\u{2013}")
        for id in MetricID.allCases {
            XCTAssertEqual(
                DashboardFormat.primaryValue(for: id, sample: nil),
                DashboardFormat.missingValue,
                "\(id)"
            )
        }
    }

    func testPrimaryValuesUseEachModulesOwnUnit() {
        XCTAssertEqual(primary(.cpu, 0.789), "78.9%")
        XCTAssertEqual(primary(.memory, 0.5), "50.0%")
        XCTAssertEqual(primary(.disk, 1), "100.0%")
        XCTAssertEqual(primary(.gpu, 0.0314), "3.1%")
        XCTAssertEqual(primary(.battery, 0.826), "83%")
        XCTAssertEqual(primary(.network, 178_176, unit: .bytesPerSecond), "174.0 KB/s")
        XCTAssertEqual(primary(.fans, 0, detail: ["maxRpm": 2400.4]), "2400 RPM")
        XCTAssertEqual(primary(.sensors, 51.6, unit: .celsius), "52°C")
    }

    /// A reading of zero is a reading: an idle CPU shows 0.0%, not a dash.
    func testARealZeroReadingIsShownRatherThanHidden() {
        XCTAssertEqual(primary(.cpu, 0), "0.0%")
        XCTAssertEqual(primary(.battery, 0), "0%")
        XCTAssertEqual(primary(.network, 0, unit: .bytesPerSecond), "0.0 B/s")
        XCTAssertEqual(primary(.fans, 0, detail: ["maxRpm": 0]), "0 RPM")
    }

    /// A fan sample that does not report its speed must not claim the fans stopped.
    func testFansWithoutAReportedSpeedShowTheDashNotZeroRPM() {
        XCTAssertEqual(primary(.fans, 0), DashboardFormat.missingValue)
        XCTAssertEqual(primary(.fans, 1200, detail: ["fanCount": 2]), DashboardFormat.missingValue)
    }

    /// Readings are numeric and symbolic, so a Turkish or German locale must not turn
    /// "78.9%" into "78,9 %" (AGENTS.md §2).
    func testReadingsCarryNoLocaleDecimalSeparator() {
        for id in MetricID.allCases {
            let text = DashboardFormat.primaryValue(
                for: id,
                sample: MetricSample(value: 0.5123, detail: ["maxRpm": 1234.5])
            )
            XCTAssertFalse(text.contains(","), "\(id): \(text)")
        }
        XCTAssertFalse(DashboardFormat.rate(1_234_567).contains(","))
    }

    func testRateShowsTheDashOnlyForAnUnreportedDirection() {
        XCTAssertEqual(DashboardFormat.rate(nil), DashboardFormat.missingValue)
        XCTAssertEqual(DashboardFormat.rate(0), "0.0 B/s")
        XCTAssertEqual(DashboardFormat.rate(1024), "1.0 KB/s")
        XCTAssertEqual(DashboardFormat.rate(5.5 * 1024 * 1024), "5.5 MB/s")
    }

    func testTemperatureRoundsToWholeDegrees() {
        XCTAssertEqual(DashboardFormat.temperature(63.6), "64°C")
        XCTAssertEqual(DashboardFormat.temperature(63.4), "63°C")
        XCTAssertEqual(DashboardFormat.temperature(0), "0°C")
    }

    // MARK: - Used of total

    /// The unit is named once when both sides share it, and the spaces that would
    /// strand a unit on its own line do not break.
    func testUsedOfTotalNamesASharedUnitOnce() {
        XCTAssertEqual(
            DashboardFormat.usedOfTotal(used: 13.6 * gigabyte, total: 16 * gigabyte),
            "13.6\u{00A0}/ 16.0\u{00A0}GB"
        )
    }

    func testUsedOfTotalNamesBothUnitsWhenTheyDiffer() {
        XCTAssertEqual(
            DashboardFormat.usedOfTotal(used: 512 * 1024 * 1024, total: 16 * gigabyte),
            "512.0\u{00A0}MB\u{00A0}/ 16.0\u{00A0}GB"
        )
        XCTAssertEqual(
            DashboardFormat.usedOfTotal(used: 0, total: 494.4 * gigabyte),
            "0.0\u{00A0}B\u{00A0}/ 494.4\u{00A0}GB"
        )
    }

    /// The only place the line may wrap is after the slash.
    func testUsedOfTotalBreaksOnlyAfterTheSlash() {
        for (used, total) in [(13.6 * gigabyte, 16 * gigabyte), (512.0 * 1024 * 1024, 2 * gigabyte * 1024)] {
            let text = DashboardFormat.usedOfTotal(used: used, total: total)
            XCTAssertEqual(text.components(separatedBy: " ").count, 2, text)
            XCTAssertTrue(text.contains("/ "), text)
        }
    }

    func testSplitSeparatesTheNumberFromItsUnit() {
        let rate = DashboardFormat.split("174.0 KB/s")
        XCTAssertEqual(rate.number, "174.0")
        XCTAssertEqual(rate.unit, "KB/s")

        let bytes = DashboardFormat.split(MetricFormat.bytes(16 * gigabyte))
        XCTAssertEqual(bytes.number, "16.0")
        XCTAssertEqual(bytes.unit, "GB")

        // Without a unit the value comes back whole.
        let dash = DashboardFormat.split(DashboardFormat.missingValue)
        XCTAssertEqual(dash.number, DashboardFormat.missingValue)
        XCTAssertEqual(dash.unit, "")

        // The unit is what follows the last space.
        let spaced = DashboardFormat.split("1 2 3")
        XCTAssertEqual(spaced.number, "1 2")
        XCTAssertEqual(spaced.unit, "3")
    }

    // MARK: - Device

    /// About This Mac leaves a zero patch out, and so does the Device card.
    func testSystemVersionOmitsAZeroPatch() {
        XCTAssertEqual(version(26, 0, 0), "26.0")
        XCTAssertEqual(version(26, 0, 1), "26.0.1")
        XCTAssertEqual(version(26, 6, 2), "26.6.2")
        XCTAssertEqual(version(15, 6, 0), "15.6")
        XCTAssertEqual(version(15, 0, 0), "15.0")
    }

    func testThisMacsVersionReadsAsMajorMinorAndAnyPatch() {
        let running = ProcessInfo.processInfo.operatingSystemVersion
        let text = DashboardFormat.systemVersion(running)
        XCTAssertTrue(text.hasPrefix("\(running.majorVersion).\(running.minorVersion)"), text)
        XCTAssertEqual(
            text.split(separator: ".").count,
            running.patchVersion == 0 ? 2 : 3,
            text
        )
    }

    // MARK: - Durations

    func testUptimeInEnglishUsesDaysHoursAndMinutes() {
        XCTAssertEqual(uptime(0), "0m")
        XCTAssertEqual(uptime(12 * 60 + 50), "12m")
        XCTAssertEqual(uptime(3 * 3600 + 5 * 60), "3h 5m")
        XCTAssertEqual(uptime(86_400 + 12 * 3600 + 21 * 60), "1d 12h 21m")
    }

    /// Whole units only, rounded down as a clock is, and a zero unit left out.
    func testUptimeRoundsDownAndLeavesOutZeroUnits() {
        XCTAssertEqual(uptime(59), "0m")
        XCTAssertEqual(uptime(86_400 + 12 * 3600 + 21 * 60 + 59), "1d 12h 21m")
        XCTAssertEqual(uptime(3600), "1h")
        XCTAssertEqual(uptime(86_400), "1d")
        XCTAssertEqual(uptime(86_400 + 5 * 60), "1d 5m")
        XCTAssertEqual(uptime(3 * 86_400), "3d")
        // Never negative, whatever the clock did.
        XCTAssertEqual(uptime(-5), "0m")
    }

    /// Words follow the locale; the numbers are still there.
    func testUptimeFollowsTheLocalesOwnAbbreviations() {
        let seconds: TimeInterval = 86_400 + 12 * 3600 + 21 * 60
        let turkish = DashboardFormat.uptime(seconds, locale: Locale(identifier: "tr_TR"))
        XCTAssertNotEqual(turkish, uptime(seconds))
        for number in ["1", "12", "21"] {
            XCTAssertTrue(turkish.contains(number), turkish)
        }
    }

    func testBatteryEstimatesUseHoursAndMinutesButNeverDays() {
        XCTAssertEqual(duration(0), "0m")
        XCTAssertEqual(duration(45), "45m")
        XCTAssertEqual(duration(60), "1h")
        XCTAssertEqual(duration(135), "2h 15m")
        XCTAssertEqual(duration(135.9), "2h 15m")
        XCTAssertEqual(duration(59.99), "59m")
        XCTAssertEqual(duration(1500), "25h")
    }

    // MARK: - Spoken list

    /// Joined by the catalog's separator rather than a hardcoded ", ", and a "%" in a
    /// part is text, not a format.
    func testSpokenListKeepsEveryPartInOrder() throws {
        XCTAssertEqual(DashboardFormat.spokenList([]), "")
        XCTAssertEqual(DashboardFormat.spokenList(["CPU"]), "CPU")

        let list = DashboardFormat.spokenList(["CPU", "42.0%", "Live"])
        let first = try XCTUnwrap(list.range(of: "CPU"))
        let second = try XCTUnwrap(list.range(of: "42.0%"))
        let third = try XCTUnwrap(list.range(of: "Live"))
        XCTAssertEqual(first.lowerBound, list.startIndex)
        XCTAssertLessThan(first.upperBound, second.lowerBound)
        XCTAssertLessThan(second.upperBound, third.lowerBound)
        XCTAssertEqual(third.upperBound, list.endIndex)
        if Bundle.main.preferredLocalizations.first == "en" {
            XCTAssertEqual(list, "CPU, 42.0%, Live")
        }
    }

    // MARK: - Battery power

    /// Charging wins whatever the power source says.
    func testChargingIsChargingWhateverThePowerSource() {
        for isOnBattery in [true, false, nil] as [Bool?] {
            XCTAssertEqual(
                BatteryPowerStatus.resolve(["charging": 1], isOnBattery: isOnBattery),
                .charging
            )
        }
    }

    /// Held at a charge limit a Mac is not charging, yet it is not on battery either.
    func testNotChargingOnTheAdapterIsPluggedInNotOnBattery() {
        XCTAssertEqual(BatteryPowerStatus.resolve(["charging": 0], isOnBattery: false), .pluggedIn)
        XCTAssertEqual(BatteryPowerStatus.resolve([:], isOnBattery: false), .pluggedIn)
    }

    func testNotChargingOnBatteryIsOnBattery() {
        XCTAssertEqual(BatteryPowerStatus.resolve(["charging": 0], isOnBattery: true), .onBattery)
        XCTAssertEqual(BatteryPowerStatus.resolve([:], isOnBattery: true), .onBattery)
    }

    /// Before the power source is known, the charging flag is all there is to go on.
    func testAnUnknownPowerSourceFallsBackToTheChargingFlag() {
        XCTAssertEqual(BatteryPowerStatus.resolve(["charging": 0], isOnBattery: nil), .onBattery)
        XCTAssertEqual(BatteryPowerStatus.resolve([:], isOnBattery: nil), .onBattery)
        XCTAssertEqual(BatteryPowerStatus.resolve(["charging": 1], isOnBattery: nil), .charging)
    }

    func testEstimatePrefersTheSystemsAndCountsTowardsTheRightEnd() {
        let detail = ["timeToFull": 42.0, "timeToEmpty": 300, "smartTimeRemaining": 120]
        XCTAssertEqual(BatteryPowerStatus.charging.estimate(in: detail), 42)
        XCTAssertEqual(BatteryPowerStatus.onBattery.estimate(in: detail), 300)
    }

    func testEstimateFallsBackToTheSmartBatteryWhenTheSystemHasNone() {
        XCTAssertEqual(
            BatteryPowerStatus.onBattery.estimate(in: ["timeToEmpty": 0, "smartTimeRemaining": 120]),
            120
        )
        XCTAssertEqual(
            BatteryPowerStatus.charging.estimate(in: ["timeToFull": -1, "smartTimeRemaining": 30]),
            30
        )
        // Charging never counts down to empty.
        XCTAssertEqual(
            BatteryPowerStatus.charging.estimate(in: ["timeToEmpty": 300, "smartTimeRemaining": 30]),
            30
        )
    }

    /// "Calculating" is no estimate, not an estimate of zero minutes.
    func testEstimateNeverFabricatesZero() {
        for status in [BatteryPowerStatus.charging, .onBattery] {
            XCTAssertNil(status.estimate(in: [:]), "\(status)")
            XCTAssertNil(
                status.estimate(in: ["timeToFull": 0, "timeToEmpty": 0, "smartTimeRemaining": 0]),
                "\(status)"
            )
            XCTAssertNil(
                status.estimate(in: ["timeToFull": -1, "timeToEmpty": -1, "smartTimeRemaining": -1]),
                "\(status)"
            )
        }
        XCTAssertNil(BatteryPowerStatus.charging.estimate(in: ["timeToEmpty": 300]))
        XCTAssertNil(BatteryPowerStatus.onBattery.estimate(in: ["timeToFull": 42]))
    }

    /// A Mac held on the adapter has nothing to count down to, so it has no estimate
    /// and no label for one.
    func testPluggedInHasNothingToEstimate() {
        let detail = ["timeToFull": 42.0, "timeToEmpty": 300, "smartTimeRemaining": 120]
        XCTAssertNil(BatteryPowerStatus.pluggedIn.estimate(in: detail))
        XCTAssertNil(BatteryPowerStatus.pluggedIn.estimateLabel)
        XCTAssertNotNil(BatteryPowerStatus.charging.estimateLabel)
        XCTAssertNotNil(BatteryPowerStatus.onBattery.estimateLabel)
        XCTAssertNotEqual(
            BatteryPowerStatus.charging.estimateLabel,
            BatteryPowerStatus.onBattery.estimateLabel
        )
    }

    func testEveryPowerStatusHasItsOwnNameAndARealSymbol() {
        let statuses: [BatteryPowerStatus] = [.charging, .pluggedIn, .onBattery]
        let names = statuses.map(\.localizedName)
        XCTAssertFalse(names.contains(where: \.isEmpty))
        XCTAssertEqual(Set(names).count, statuses.count)

        XCTAssertEqual(BatteryPowerStatus.charging.symbolName, "bolt.fill")
        XCTAssertEqual(BatteryPowerStatus.pluggedIn.symbolName, "powerplug.fill")
        XCTAssertNil(BatteryPowerStatus.onBattery.symbolName)
        for symbol in statuses.compactMap(\.symbolName) {
            XCTAssertNotNil(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                "\(symbol) is not an SF Symbol on this macOS"
            )
        }
    }

    // MARK: - Helpers

    private func primary(
        _ id: MetricID,
        _ value: Double,
        unit: MetricUnit = .fraction,
        detail: [String: Double] = [:]
    ) -> String {
        DashboardFormat.primaryValue(
            for: id,
            sample: MetricSample(value: value, unit: unit, detail: detail)
        )
    }

    private func version(_ major: Int, _ minor: Int, _ patch: Int) -> String {
        DashboardFormat.systemVersion(
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        )
    }

    private func uptime(_ seconds: TimeInterval) -> String {
        DashboardFormat.uptime(seconds, locale: english)
    }

    private func duration(_ minutes: Double) -> String {
        DashboardFormat.duration(minutes: minutes, locale: english)
    }
}
