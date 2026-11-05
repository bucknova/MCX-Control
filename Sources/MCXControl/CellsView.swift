import Charts
import MCXCore
import SwiftUI

struct CellRow: Identifiable { let cell: Cell; let run: RunRecord?; var id: Int64 { cell.id }
    var capacity: Double? { run?.dischargeCapacity }
    var health: Analysis.Health? { capacity.map { Analysis.health(capacity: $0, rated: cell.rated) } }
}

struct CellsView: View {
    @Environment(AppModel.self) private var model
    @Local private var selection: Int64?
    @Local private var showAdd = false
    var body: some View {
        let rows = model.cells.map { CellRow(cell: $0, run: model.latest(for: $0)) }
        VStack(spacing: 16) {
            HStack {
                Text("\(model.cells.count) cell\(model.cells.count == 1 ? "" : "s")").font(.headline)
                Spacer()
                Button("Delete cell", systemImage: "trash") { if let s = selection { model.store.delete(cell: s); selection = nil; model.reload() } }.buttonStyle(.glass).disabled(selection == nil)
                Button("Add cell", systemImage: "plus") { showAdd = true }.buttonStyle(.glass)
            }
            Table(rows, selection: $selection) {
                TableColumn("Label") { Text($0.cell.label).fontWeight(.semibold) }
                TableColumn("Type") { Text($0.cell.type.name) }
                TableColumn("Rated") { Text("\($0.cell.rated) mAh").monospacedDigit() }
                TableColumn("Last capacity") { Text($0.capacity.map { String(format: "%.0f mAh", $0) } ?? "–").monospacedDigit() }
                TableColumn("Of rated") { r in Text(r.capacity.map { String(format: "%.1f%%", $0 / Double(max(r.cell.rated, 1)) * 100) } ?? "–").monospacedDigit() }
                TableColumn("Resistance") { Text($0.run?.resistance.map { "\($0) mΩ" } ?? "–").monospacedDigit() }
                TableColumn("Health") { r in
                    if let h = r.health { Text(h.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 1).background(h == .good ? Color.green : h == .watch ? .orange : .red, in: .capsule) } else { Text("Not tested").foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 240)
            if let c = model.cells.first(where: { $0.id == selection }) { CellTrends(cell: c) }
            else { Text(model.cells.isEmpty ? "Add a cell to start tracking its history." : "Select a cell to see its trends.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
        }
        .padding(16)
        .sheet(isPresented: $showAdd) { AddCell().environment(model) }
    }
}

struct CellTrends: View {
    @Environment(AppModel.self) private var model
    let cell: Cell
    var body: some View {
        let tests = model.store.runs(cell: cell.id).filter { ($0.dischargeCapacity ?? 0) > 0 }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(cell.label) over \(tests.count) discharge test\(tests.count == 1 ? "" : "s")").font(.headline)
            if tests.isEmpty { Text("No completed discharge tests yet.").foregroundStyle(.secondary) } else {
                HStack(spacing: 20) {
                    trend("Capacity", unit: "mAh", tests.enumerated().map { ($0.offset + 1, $0.element.dischargeCapacity ?? 0) }, .orange)
                    trend("Internal resistance", unit: "mΩ", tests.enumerated().compactMap { i, r in r.resistance.map { (i + 1, Double($0)) } }, .secondary)
                }
            }
        }
        .panel()
    }
    private func trend(_ title: String, unit: String, _ pts: [(Int, Double)], _ c: Color) -> some View {
        VStack(alignment: .leading) {
            Text(title).fontWeight(.semibold)
            Chart(pts, id: \.0) { p in
                LineMark(x: .value("Test", p.0), y: .value(unit, p.1)).foregroundStyle(c)
                PointMark(x: .value("Test", p.0), y: .value(unit, p.1)).foregroundStyle(c)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel(unit).chartXAxisLabel("Test").frame(height: 170)
        }
    }
}

struct AddCell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Local private var label = ""
    @Local private var type = BatteryType.nimh
    @Local private var rated = 2450
    @Local private var notes = ""
    var body: some View {
        Form {
            TextField("Label", text: $label, prompt: Text("E-01"))
            Picker("Type", selection: $type) { ForEach(BatteryType.allCases) { Text($0.name).tag($0) } }
            TextField("Rated capacity (mAh)", value: $rated, format: .number.grouping(.never))
            TextField("Notes", text: $notes)
        }
        .formStyle(.grouped).frame(width: 400, height: 280)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { if model.store.save(Cell(label: label.trimmingCharacters(in: .whitespaces), type: type, rated: rated, notes: notes)) { model.reload(); dismiss() } }
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || rated <= 0)
            }
        }
    }
}

struct MatchView: View {
    @Environment(AppModel.self) private var model
    @Local private var type = BatteryType.nimh
    @Local private var size = 4
    var body: some View {
        let tested: [Analysis.MatchCell] = model.cells.filter { $0.type == type }.compactMap { c in
            guard let r = model.latest(for: c), let cap = r.dischargeCapacity else { return nil }
            return Analysis.MatchCell(id: c.id, label: c.label, capacity: cap, resistance: r.resistance)
        }
        let matches = Analysis.packMatches(tested, size: size)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Picker("Type", selection: $type) { ForEach(BatteryType.allCases.filter { $0.isNickel || $0.isLithium }) { Text($0.name).tag($0) } }.frame(maxWidth: 220)
                    Picker("Cells in pack", selection: $size) { ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) } }.frame(maxWidth: 170)
                    Spacer()
                    Text("\(tested.count) tested").foregroundStyle(.secondary)
                }
                if matches.isEmpty {
                    ContentUnavailableView("Not enough tested cells", systemImage: "square.grid.2x2", description: Text("A pack of \(size) needs \(size) cells with a completed discharge test.")).frame(minHeight: 300)
                }
                ForEach(Array(matches.enumerated()), id: \.offset) { i, m in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(i == 0 ? "Best match" : "Also close").font(.headline); Spacer()
                            Text(m.cells.map(\.label).joined(separator: ", ")).fontWeight(.semibold)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 16) {
                            GridRow {
                                Metric(title: "Capacity spread", value: String(format: "%.0f mAh", m.capacitySpread), note: String(format: "%.1f%%", m.capacitySpread / max(m.limitedBy.capacity, 1) * 100))
                                Metric(title: "Resistance spread", value: m.resistanceSpread.map { "\($0) mΩ" } ?? "–")
                                Metric(title: "Pack limited by", value: String(format: "%.0f mAh", m.limitedBy.capacity), note: m.limitedBy.label)
                            }
                        }
                    }
                    .panel()
                }
            }
            .padding(16)
        }
    }
}
