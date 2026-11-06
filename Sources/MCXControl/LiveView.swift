import MCXCore
import SwiftUI

struct LiveView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(0..<4, id: \.self) { SlotTile(slot: $0) }
                }
                SlotDetail(slot: model.selectedSlot)
            }
            .padding(16)
        }
    }
}

struct SlotTile: View {
    @Environment(AppModel.self) private var model
    let slot: Int
    var body: some View {
        let r = model.charger.readings[slot]
        let on = model.selectedSlot == slot
        Button { model.selectedSlot = slot } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text("Slot \(slot + 1)").font(.headline); Spacer(); if let r { chipStyle(r.status) } }
                Text(r.map { "\($0.type?.name ?? "Unknown") · \($0.mode?.name(for: $0.type) ?? "")" } ?? "Waiting for charger").font(.callout).foregroundStyle(.secondary)
                if let r, r.hasCell {
                    Text(Format.volts(r.millivolts)).font(.title.weight(.semibold)).monospacedDigit()
                    Text(r.status.isActive || r.status.isDone ? String(format: "%d mA · %.0f mAh · %.0f °C", r.milliamps, r.capacity, r.temperature) : String(format: "%.0f °C", r.temperature)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("No cell").font(.title.weight(.medium)).foregroundStyle(.secondary)
                    Text(r.map { String(format: "%.0f °C", $0.temperature) } ?? " ").font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: on ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Slot \(slot + 1)")
    }
}

struct SlotDetail: View {
    @Environment(AppModel.self) private var model
    let slot: Int
    var body: some View {
        let r = model.charger.readings[slot]
        let samples = model.live[slot]
        let a = model.liveAnalysis[slot] ?? Analysis.analyze(samples)
        let calc = a.phases.last?.calculatedCapacity
        let current = r.map { $0.status.isActive || $0.status.isDone || $0.status.isFault } ?? false
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("Slot \(slot + 1)").font(.title3.weight(.semibold))
                if let r { Text("\(r.type?.name ?? "") \(r.mode?.name(for: r.type) ?? "")").foregroundStyle(.secondary) }
                Spacer()
                Picker("Cell", selection: Binding(get: { model.slotCell[slot] }, set: { model.setCell($0, slot: slot) })) {
                    Text("Not assigned").tag(Int64?.none)
                    ForEach(model.cells) { Text($0.label).tag(Int64?.some($0.id)) }
                }
                .frame(maxWidth: 200)
                Button("Edit program") { model.draftSlots = [slot]; model.section = .programs }.buttonStyle(.glass)
                Button { model.stop(slot: slot) } label: { Label("Stop slot \(slot + 1)", systemImage: "stop.fill").foregroundStyle(r?.status.isActive == true ? Color.red : Color.secondary) }.buttonStyle(.glass).disabled(r?.status.isActive != true)
            }
            if let r {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Metric(title: "Voltage", value: Format.volts(r.millivolts), note: r.loadedMillivolts.map { "Second reading \(Format.volts($0))" })
                        Metric(title: "Current", value: "\(r.milliamps) mA")
                        Metric(title: "Capacity", value: current ? String(format: r.source == .usb ? "%.1f mAh" : "%.0f mAh", r.capacity) : "–", note: current ? calc.map { String(format: "%.1f calculated", $0) } : nil)
                        Metric(title: "Energy", value: !current ? "–" : r.energyMilliwattHours.map { String(format: "%.3f Wh", Double($0) / 1000) } ?? (a.phases.last.map { String(format: "%.3f Wh", $0.energyWattHours) } ?? "–"), note: !current ? nil : r.energyMilliwattHours != nil ? "Charger measured" : "Calculated")
                        Metric(title: "Temperature", value: String(format: r.source == .usb ? "%.1f °C" : "%.0f °C", r.temperature), note: r.chargerTemperature.map { String(format: "Charger %.1f °C", $0) })
                        Metric(title: "Resistance", value: r.resistanceIsLive ? (r.internalResistance.map { "\($0) mΩ" } ?? "–") : "–")
                        Metric(title: "Elapsed", value: r.status.isActive || r.status.isDone ? Format.clock(r.elapsed) : "–", note: joinedNote(samples))
                    }
                }
            }
            RunCharts(samples: samples, height: 340).equatable()
        }
        .panel()
    }
    private func joinedNote(_ s: [Sample]) -> String? { (s.first?.elapsed ?? 0) > 5 ? "Recording from \(Format.clock(s[0].elapsed))" : nil }
}
