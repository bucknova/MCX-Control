import Charts
import MCXCore
import SwiftUI

struct ChartPoint: Identifiable { let id: Int; let minutes: Double; let volts: Double; let amps: Double; let temp: Double; let segment: String; let status: UInt8 }

func chartPoints(_ raw: [Sample]) -> [ChartPoint] {
    guard let t0 = raw.first?.time else { return [] }
    let s = Analysis.downsample(raw, max: 1500)
    var seg = 0
    var out: [ChartPoint] = []
    for (i, x) in s.enumerated() {
        // A new segment leaves a visible break across a recording gap and colors each phase separately.
        if i > 0, x.time.timeIntervalSince(s[i - 1].time) > Analysis.gapThreshold || x.status != s[i - 1].status { seg += 1 }
        out.append(ChartPoint(id: i, minutes: x.time.timeIntervalSince(t0) / 60, volts: Double(x.millivolts) / 1000, amps: Double(x.milliamps) / 1000, temp: x.temperature, segment: "\(seg)", status: x.status))
    }
    return out
}

private func phaseColor(_ s: UInt8) -> Color { s == 1 ? .blue : s == 2 ? .orange : .gray }

struct RunCharts: View {
    let samples: [Sample]
    var height: CGFloat = 200
    @Local private var metric = "Voltage"
    var body: some View {
        let p = chartPoints(samples)
        VStack(alignment: .leading, spacing: 10) {
            Picker("Chart", selection: $metric) { ForEach(["Voltage", "Current", "Temperature"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            if p.isEmpty {
                ContentUnavailableView("No readings yet", systemImage: "chart.xyaxis.line", description: Text("The chart fills in once a run starts.")).frame(maxWidth: .infinity, minHeight: height)
            } else {
                Chart(p) { x in
                    LineMark(x: .value("Minutes", x.minutes), y: .value(metric, value(x)), series: .value("Segment", x.segment))
                        .foregroundStyle(metric == "Voltage" ? phaseColor(x.status) : metric == "Current" ? Color.secondary : Color.red)
                        .lineStyle(.init(lineWidth: metric == "Current" ? 1 : 2))
                }
                .chartYScale(domain: .automatic(includesZero: metric == "Current"))
                .chartYAxisLabel(metric == "Voltage" ? "V" : metric == "Current" ? "A" : "°C")
                .chartXAxisLabel("Minutes")
                .frame(height: height)
            }
        }
    }
    private func value(_ x: ChartPoint) -> Double { metric == "Voltage" ? x.volts : metric == "Current" ? x.amps : x.temp }
}
