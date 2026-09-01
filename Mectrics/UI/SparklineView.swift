import SwiftUI
import MetricsKit

/// How a sparkline's y-axis is scaled.
///
/// A chart normalized purely against its own window maximum is right for the modules whose
/// samples are already 0...1, and wrong for the ones carrying a raw rate: the axis then
/// re-fits itself to whatever the quietest minute contained, so a few KB/s of background
/// chatter is stretched to full height and reads as heavy traffic. A floor pins the top of
/// the axis until real traffic exceeds it.
enum SparklineScale {
    /// Network throughput has no ceiling to normalize against, so the axis is anchored at
    /// 1 MB/s. Below that the curve stays visibly flat — an idle Mac looks idle — and a
    /// real transfer still scales the chart to its own peak.
    static let networkFloor: Double = 1_000_000

    static func floor(for id: MetricID) -> Double {
        id == .network ? networkFloor : 0
    }

    /// Top of the y-axis: the window maximum, never below `floor`, never zero.
    static func maximum(of values: [Double], floor: Double = 0) -> Double {
        max(values.max() ?? 0, floor, 0.0001)
    }
}

/// Simple SwiftUI sparkline — draws history in popovers and panels.
struct SparklineView: View {
    let values: [Double]     // normalized 0...1
    var accent: Color = .accentColor
    /// Lower bound for the y-axis, in the values' own units — see `SparklineScale`.
    var scaleFloor: Double = 0

    var body: some View {
        GeometryReader { geo in
            let maxV = SparklineScale.maximum(of: values, floor: scaleFloor)
            let count = values.count
            ZStack {
                if count > 1 {
                    let path = linePath(in: geo.size, maxV: maxV, count: count)
                    path.fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(ExperienceChart.fillOpacity),
                                accent.opacity(0.02)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    strokePath(in: geo.size, maxV: maxV, count: count)
                        .stroke(
                            accent,
                            style: StrokeStyle(
                                lineWidth: ExperienceChart.compactStrokeWidth,
                                lineJoin: .round
                            )
                        )
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(
            String(localized: "chart.recentTrend", defaultValue: "Recent trend")
        )
        .accessibilityValue(accessibilitySummary)
    }

    private func x(_ i: Int, width: CGFloat, count: Int) -> CGFloat {
        CGFloat(i) / CGFloat(max(count - 1, 1)) * width
    }

    private func y(_ i: Int, height: CGFloat, maxV: Double) -> CGFloat {
        height - CGFloat(values[i] / maxV) * height
    }

    private func strokePath(in size: CGSize, maxV: Double, count: Int) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: x(0, width: size.width, count: count),
                           y: y(0, height: size.height, maxV: maxV)))
        for i in 1..<count {
            p.addLine(to: CGPoint(x: x(i, width: size.width, count: count),
                                  y: y(i, height: size.height, maxV: maxV)))
        }
        return p
    }

    private func linePath(in size: CGSize, maxV: Double, count: Int) -> Path {
        var p = strokePath(in: size, maxV: maxV, count: count)
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }

    private var accessibilitySummary: String {
        guard let minimum = values.min(),
              let maximum = values.max(),
              let latest = values.last
        else {
            return String(localized: "chart.noReadings", defaultValue: "No readings")
        }
        let format = String(
            localized: "chart.summary",
            defaultValue: "%lld readings, minimum %.0f%%, maximum %.0f%%, latest %.0f%%"
        )
        return String(
            format: format,
            Int64(values.count),
            minimum * 100,
            maximum * 100,
            latest * 100
        )
    }
}
