import AppKit
import MCXCore
import SwiftUI
import UniformTypeIdentifiers

struct TestsView: View {
    @Environment(AppModel.self) private var model
    @Local private var selection: Int64?
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            List(model.runs, selection: $selection) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("\(model.cell(r.cellID)?.label ?? "Slot \(r.slot + 1)") · \(r.mode?.name(for: r.type) ?? "Run")").fontWeight(.semibold)
                        Spacer()
                        Text(capText(r)).monospacedDigit()
                    }
                    Text("\(r.started.formatted(date: .abbreviated, time: .shortened)) · Slot \(r.slot + 1)\(r.ended == nil ? " · Recording" : "")").font(.callout).foregroundStyle(.secondary)
                }
                .tag(r.id)
            }
            .listPanel()
            .frame(width: 300)
            Group {
                if let r = model.runs.first(where: { $0.id == selection }) { RunReport(run: r).id(r.id) }
                else { ContentUnavailableView("Select a test", systemImage: "list.bullet.rectangle", description: Text(model.runs.isEmpty ? "Tests appear here once the charger runs one." : "Choose one from the list.")) }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding([.horizontal, .bottom], 16)
    }
    private func capText(_ r: RunRecord) -> String {
        if let d = r.dischargeCapacity, d > 0 { return String(format: "%.0f mAh", d) }
        if let c = r.chargeCapacity, c > 0 { return String(format: "%.0f mAh", c) }
        return ""
    }
}

struct RunReport: View {
    @Environment(AppModel.self) private var model
    let run: RunRecord
    @Local private var confirmDelete = false
    var body: some View {
        let (samples, a) = model.analysis(of: run)
        let rated = model.cell(run.cellID)?.rated ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.type?.name ?? "Unknown") \(run.mode?.name(for: run.type) ?? "")").font(.title3.weight(.semibold))
                            Text(subtitle(a)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Cell", selection: Binding(get: { run.cellID }, set: { model.assign(run: run, cell: $0) })) {
                            Text("Not assigned").tag(Int64?.none)
                            ForEach(model.cells) { Text($0.label).tag(Int64?.some($0.id)) }
                        }.frame(maxWidth: 190)
                        Button("Export CSV") { export(samples) }.buttonStyle(.glass)
                        Button("Delete", role: .destructive) { confirmDelete = true }.buttonStyle(.glass)
                            .disabled(run.id == model.currentRun[run.slot])
                            .help(run.id == model.currentRun[run.slot] ? "This test is still recording." : "Delete this test")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16) {
                        GridRow {
                            if let d = a.dischargeCapacity {
                                Metric(title: "Discharge capacity", value: String(format: "%.0f mAh", d), note: rated > 0 ? String(format: "%.1f%% of rated", d / Double(rated) * 100) : nil)
                            } else { Metric(title: "Charge capacity", value: String(format: "%.0f mAh", a.chargeCapacity)) }
                            Metric(title: a.dischargeCapacity != nil ? "Energy out" : "Energy in", value: String(format: "%.2f Wh", a.dischargeCapacity != nil ? a.dischargeEnergy : a.chargeEnergy), note: a.phases.filter { $0.kind == .discharge }.count > 1 ? "All discharges" : nil)
                            Metric(title: "Energy efficiency", value: a.efficiency.map { String(format: "%.1f%%", $0 * 100) } ?? "–", note: a.efficiency != nil ? "Last charge and discharge" : a.dischargeCapacity != nil ? "Needs discharge, charge, discharge" : nil)
                            Metric(title: "Internal resistance", value: a.internalResistance.map { "\($0) mΩ" } ?? "–")
                            Metric(title: "Data coverage", value: String(format: "%.1f%%", a.coverage * 100), note: a.gapCount > 0 ? "\(a.gapCount) gap\(a.gapCount == 1 ? "" : "s"), \(Format.clock(Int(a.gapSeconds)))" : (run.joinedAt > 5 ? "Joined at \(Format.clock(run.joinedAt))" : nil), noteColor: .orange)
                        }
                    }
                    RunCharts(samples: samples, height: 340)
                }.panel()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Phases").font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow { ForEach(["Phase", "Duration", "Average current", "Capacity", "Calculated", "Energy", "Voltage range", "Peak temp"], id: \.self) { Text($0) } }.font(.callout).foregroundStyle(.secondary)
                        ForEach(a.phases) { p in
                            GridRow {
                                Text(p.kind.rawValue)
                                Text(Format.clock(Int(p.duration)))
                                Text(p.kind == .rest ? "–" : "\(p.averageCurrent) mA")
                                Text(p.kind == .rest ? "–" : String(format: "%.1f mAh", p.chargerCapacity))
                                Text(p.kind == .rest ? "–" : String(format: "%.1f mAh", p.calculatedCapacity))
                                Text(p.kind == .rest ? "–" : String(format: "%.3f Wh", p.energyWattHours))
                                Text("\(Format.volts(p.voltageRange.lowerBound)) – \(Format.volts(p.voltageRange.upperBound))")
                                Text(String(format: "%.1f °C", p.peakTemperature))
                            }.monospacedDigit()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }
        }
        .confirmationDialog("Delete this test and its recorded data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(run: run) }
        } message: { Text("This can't be undone.") }
    }
    private func subtitle(_ a: RunAnalysis) -> String {
        var parts = ["Slot \(run.slot + 1)", run.started.formatted(date: .abbreviated, time: .shortened)]
        if let e = run.ended { parts.append(Format.clock(Int(e.timeIntervalSince(run.started)))) }
        switch run.endReason {
        case "finished": parts.append("Finished normally")
        case "stopped": parts.append(stopText)
        case .some: parts.append(SlotStatus(raw: run.endStatus ?? 0).label)
        case .none: parts.append("Recording")
        }
        return parts.joined(separator: " · ")
    }
    private var stopText: String {
        guard let stop = run.stop else { return "Stopped" } // Saved before stops were tracked.
        guard let time = stop.time else { return "Stopped, \(stop.source.label)" }
        return "Stopped by the \(stop.source.label) at \(time.formatted(date: .omitted, time: .standard))"
    }
    private func export(_ s: [Sample]) {
        let p = NSSavePanel(); p.allowedContentTypes = [.commaSeparatedText]
        p.nameFieldStringValue = "\(model.cell(run.cellID)?.label ?? "slot-\(run.slot + 1)")-\(run.started.formatted(.iso8601.year().month().day())).csv"
        if p.runModal() == .OK, let u = p.url { try? Analysis.csv(s).write(to: u, atomically: true, encoding: .utf8) }
    }
}
