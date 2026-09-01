import MetricsKit
import XCTest
@testable import Mectrics

/// Network can be charted in the menu bar, and its chart is scaled rather than purely
/// max-normalized.
///
/// The width-stability property is covered for free by `MenuBarTemplateTests`, which walks
/// every component `available(for:)` returns. What is checked here is the pairing itself —
/// a graphless variant beside a graphed one, the way CPU/Memory/GPU are — and the scale
/// floor that keeps an idle Mac from drawing a full-height chart out of background chatter.
final class NetworkGraphTests: XCTestCase {

    private static let sample = MetricSample(
        value: 1_500_000,
        unit: .bytesPerSecond,
        detail: ["down": 1_200_000, "up": 300_000]
    )

    func testNetworkOffersBothAGraphlessAndAGraphedActivityComponent() {
        let available = MenuBarComponent.available(for: .network)
        XCTAssertTrue(available.contains(.netActivity))
        XCTAssertTrue(available.contains(.netActivityGraph))

        XCTAssertFalse(MenuBarComponent.netActivity.drawsSparkline)
        XCTAssertTrue(MenuBarComponent.netActivityGraph.drawsSparkline)

        // The graphed variant must not become the default: an existing menu bar would
        // silently widen on update.
        XCTAssertEqual(MenuBarComponent.default(for: .network), .netActivity)
    }

    /// Both variants draw the same stacked ↓/↑ text in the same small two-line font, so
    /// they must also reserve the same slot — the graph is added beside it, not inside it.
    func testTheGraphedVariantRendersTheSameTextInTheSameSlot() {
        guard case .text(let plain) = MenuBarText.visual(
            for: .network,
            component: .netActivity,
            sample: Self.sample
        ), case .textGraph(let charted) = MenuBarText.visual(
            for: .network,
            component: .netActivityGraph,
            sample: Self.sample
        ) else {
            return XCTFail("Network activity must render as text, charted or not")
        }

        XCTAssertEqual(plain, charted)
        XCTAssertTrue(charted.contains("\n"), "Rates stay stacked so the item stays narrow")
        XCTAssertTrue(MenuBarComponent.netActivityGraph.drawsStackedRates)
        XCTAssertEqual(
            MetricStatusItem.reservedTextWidth(for: .netActivityGraph, module: .network),
            MetricStatusItem.reservedTextWidth(for: .netActivity, module: .network)
        )
    }

    /// Throughput has no ceiling to normalize against, so a quiet window must not be
    /// stretched to fill the chart.
    func testIdleTrafficStaysBelowTheNetworkFloor() {
        let floor = SparklineScale.floor(for: .network)
        XCTAssertEqual(floor, SparklineScale.networkFloor)

        let idle = [3_000.0, 5_000, 2_000, 8_000]
        XCTAssertEqual(SparklineScale.maximum(of: idle, floor: floor), floor)
        // 8 KB/s against a 1 MB/s axis draws under 1% of the height.
        XCTAssertLessThan(idle.max()! / SparklineScale.maximum(of: idle, floor: floor), 0.01)
    }

    /// Real traffic still scales the chart to its own peak.
    func testRealTrafficOverridesTheFloor() {
        let busy = [12_000_000.0, 50_000_000, 31_000_000]
        XCTAssertEqual(
            SparklineScale.maximum(of: busy, floor: SparklineScale.floor(for: .network)),
            50_000_000
        )
    }

    /// Modules whose samples are already 0...1 keep the plain max-normalized scale.
    func testNormalizedModulesAreNotFloored() {
        for id in [MetricID.cpu, .memory, .gpu, .disk, .battery] {
            XCTAssertEqual(SparklineScale.floor(for: id), 0)
        }
        XCTAssertEqual(SparklineScale.maximum(of: [0.2, 0.9, 0.5]), 0.9)
    }

    /// An empty history must not divide by zero.
    func testEmptyHistoryYieldsANonZeroAxis() {
        XCTAssertGreaterThan(SparklineScale.maximum(of: []), 0)
        XCTAssertGreaterThan(SparklineScale.maximum(of: [0, 0, 0]), 0)
    }
}
