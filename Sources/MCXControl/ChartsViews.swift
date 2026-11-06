import Charts
import MCXCore
import SwiftUI

struct ChartPoint: Identifiable { let id: Int; let minutes: Double; let volts: Double; let amps: Double; let temp: Double; let segment: String; let status: UInt8 }

func chartPoints(_ raw: [Sample]) -> [ChartPoint] {
    guard let t0 = raw.first?.time else { return [] }
    return Analysis.chartSegments(raw, max: 1500).enumerated().map { i, p in
        let x = p.sample
        return ChartPoint(id: i, minutes: x.time.timeIntervalSince(t0) / 60, volts: Double(x.millivolts) / 1000, amps: Double(x.milliamps) / 1000, temp: x.temperature, segment: "\(p.segment)", status: x.status)
    }
}

private func phaseColor(_ s: UInt8) -> Color { s == 1 ? .blue : s == 2 ? .orange : .gray }

struct RunCharts: View, Equatable {
    let samples: [Sample]
    var height: CGFloat = 200
    /// Redraws for a new reading, not every time something else on the screen changes.
    static func == (a: RunCharts, b: RunCharts) -> Bool { a.height == b.height && a.samples.count == b.samples.count && a.samples.last?.time == b.samples.last?.time && a.samples.first?.time == b.samples.first?.time }
    @Local private var metric = "Voltage"
    var body: some View {
        let p = chartPoints(samples)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart", selection: $metric) { ForEach(["Voltage", "Current", "Temperature"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            if p.isEmpty {
                ContentUnavailableView("No readings yet", systemImage: "chart.xyaxis.line", description: Text("The chart fills in once a run starts.")).frame(maxWidth: .infinity, minHeight: height)
            } else {
                // Long runs read better in hours than in hundreds of minutes.
                let inHours = (p.last?.minutes ?? 0) >= 120
                Chart(p) { x in
                    LineMark(x: .value(inHours ? "Hours" : "Minutes", inHours ? x.minutes / 60 : x.minutes), y: .value(metric, value(x)), series: .value("Segment", x.segment))
                        .foregroundStyle(phaseColor(x.status))
                        // The charger's pulsed charge current packs the line tight, so a thin one keeps it from filling in solid.
                        .lineStyle(.init(lineWidth: metric == "Current" ? 0.75 : 2))
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 10)) }
                .chartYScale(domain: .automatic(includesZero: metric == "Current"))
                .chartYAxisLabel(metric == "Voltage" ? "V" : metric == "Current" ? "A" : "°C")
                .chartXAxisLabel(inHours ? "Hours" : "Minutes")
                .frame(height: height)
                HStack(spacing: 14) {
                    ForEach(legend(p), id: \.0) { name, color in
                        HStack(spacing: 5) { Capsule().fill(color).frame(width: 14, height: 3); Text(name) }
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
    private func legend(_ p: [ChartPoint]) -> [(String, Color)] {
        let seen = Set(p.map(\.status))
        var out: [(String, Color)] = []
        if seen.contains(1) { out.append(("Charge", phaseColor(1))) }
        if seen.contains(2) { out.append(("Discharge", phaseColor(2))) }
        if !seen.subtracting([1, 2]).isEmpty { out.append(("Rest or done", phaseColor(0))) }
        return out
    }
    private func value(_ x: ChartPoint) -> Double { metric == "Voltage" ? x.volts : metric == "Current" ? x.amps : x.temp }
}
