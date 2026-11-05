import MCXCore
import SwiftUI

struct ProgramView: View {
    @Environment(AppModel.self) private var model
    @Local private var showCheck = false
    @Local private var showSave = false
    @Local private var presetName = ""
    var body: some View {
        @Bindable var model = model
        let issues = Limits.validate(model.draft, ratedCapacity: model.draftRated)
        let blocked = issues.contains { $0.severity == .blocker }
        let p = model.draft
        Form {
            Section {
                Picker("Battery type", selection: Binding(get: { model.draft.type }, set: { apply(type: $0) })) { ForEach(BatteryType.allCases.filter(\.canProgram)) { Text($0.name).tag($0) } }
                Picker("Mode", selection: Binding(get: { model.draft.mode }, set: { m in
                    // Break-in has its own slow currents, so entering it starts from those. You can still change them.
                    if m == .storageOrBreakIn && model.draft.type.isNickel { model.draft = Limits.suggested(type: model.draft.type, mode: m, rated: model.draftRated) } else { model.draft.mode = m }
                })) { ForEach(ChargeMode.allCases) { Text($0.name(for: model.draft.type)).tag($0) } }
                field("Rated capacity", value: $model.draftRated, unit: "mAh", hint: "1C = \(model.draftRated) mA")
                HStack {
                    Text("Set currents").foregroundStyle(.secondary)
                    ForEach([0.2, 0.5, 1.0], id: \.self) { c in Button(String(format: "%.1fC", c)) { setRate(c) }.buttonStyle(.glass) }
                }
            }
            if p.mode.charges {
                Section("Charge") {
                    field("Current", value: $model.draft.chargeCurrent, unit: "mA", hint: "\(Limits.minCurrent)–\(Limits.maxChargeCurrent) mA · \(rate(p.chargeCurrent))", issues: issues, key: "Charge current")
                    voltage("Stop voltage", value: $model.draft.chargeStopMillivolts, hint: Limits.voltages(for: p.type).map { "Up to \(Format.volts($0.chargeStop.upperBound))" }, issues: issues, key: "Charge stop")
                    if p.type.isNickel { field("-dV", value: $model.draft.negativeDeltaMillivolts, unit: "mV", issues: issues, key: "-dV") }
                    else { field("End current", value: $model.draft.chargeEndCurrent, unit: "mA") }
                    field("Rest after charge", value: $model.draft.chargeRestMinutes, unit: "min")
                }
            }
            if p.mode.discharges {
                Section("Discharge") {
                    field("Current", value: Binding(get: { model.draft.dischargeCurrent }, set: { model.draft.dischargeCurrent = $0; model.draft.dischargeEndCurrent = $0 }), unit: "mA", hint: "\(Limits.minCurrent)–\(Limits.maxDischargeCurrent) mA · \(rate(p.dischargeCurrent))", issues: issues, key: "Discharge current")
                    voltage("Stop voltage", value: $model.draft.dischargeStopMillivolts, issues: issues, key: "Discharge stop")
                    field("Rest after discharge", value: $model.draft.dischargeRestMinutes, unit: "min")
                }
            }
            if p.mode == .cycle {
                Section("Cycle") {
                    field("Cycles", value: $model.draft.cycles, unit: "", issues: issues, key: "Cycles")
                    Picker("Order", selection: $model.draft.cycleMode) { Text("Charge > Discharge").tag(0); Text("Charge > Discharge > Charge").tag(1); Text("Discharge > Charge").tag(2); Text("Discharge > Charge > Discharge").tag(3) }
                }
            }
            Section("Backstops") {
                field("Capacity limit", value: $model.draft.capacityLimit, unit: "mAh", hint: "Ends the run at this capacity. 0 is off.", issues: issues, key: "Capacity limit")
                field("Temperature cutoff", value: $model.draft.temperatureCutoff, unit: "°C", issues: issues, key: "Temperature cutoff")
                field("Time limit, whole program", value: $model.draft.timeLimitMinutes, unit: "min", hint: "0 is off.", issues: issues, key: "Time limit")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                Text("Send to").fontWeight(.medium)
                ForEach(0..<4, id: \.self) { s in
                    Toggle("Slot \(s + 1)", isOn: Binding(get: { model.draftSlots.contains(s) }, set: { if $0 { model.draftSlots.insert(s) } else { model.draftSlots.remove(s) } }))
                        .disabled(model.charger.readings[s]?.status.isActive == true)
                }
                Spacer()
                // Not every problem belongs to a field on screen, and a disabled button should say why.
                if let b = issues.first(where: { $0.severity == .blocker }) { Text(b.message).font(.callout).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 320, alignment: .trailing) }
                Menu("Presets") {
                    ForEach(model.presets) { n in Button(n.name) { model.draft = n.program; model.draftRated = n.rated } }
                    Divider()
                    Button("Save as preset…") { showSave = true }
                }
                .menuStyle(.button).buttonStyle(.glass).fixedSize()
                Button("Write and check") { showCheck = true }
                    .buttonStyle(.glassProminent)
                    .disabled(blocked || model.draftSlots.isEmpty || model.charger.connection == .replay)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(12)
        }
        .sheet(isPresented: $showCheck) { CheckSheet(program: model.draft, slots: model.draftSlots.sorted()).environment(model) }
        .alert("Save preset", isPresented: $showSave) {
            TextField("Name", text: $presetName)
            Button("Save") { model.store.save(preset: NamedProgram(name: presetName, rated: model.draftRated, program: model.draft)); model.reload(); presetName = "" }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func apply(type: BatteryType) {
        let mode = model.draft.mode
        model.draft = Limits.suggested(type: type, mode: mode, rated: model.draftRated)
    }
    private func setRate(_ c: Double) {
        let i = Int((Double(model.draftRated) * c).rounded())
        model.draft.chargeCurrent = min(i, Limits.maxChargeCurrent)
        let d = min(i, Limits.maxDischargeCurrent)
        model.draft.dischargeCurrent = d; model.draft.dischargeEndCurrent = d
        // The backstops follow the currents, or a slower rate would hit the old time limit partway through.
        if model.draft.timeLimitMinutes > 0 { model.draft.timeLimitMinutes = Limits.suggestedTimeLimit(model.draft, rated: model.draftRated) }
    }
    private func rate(_ i: Int) -> String { model.draftRated > 0 ? String(format: "%.1fC", Double(i) / Double(model.draftRated)) : "" }

    private func message(_ issues: [ProgramIssue], _ key: String?) -> ProgramIssue? { key.flatMap { k in issues.first { $0.field == k && $0.severity == .blocker } ?? issues.first { $0.field == k } } }

    @ViewBuilder private func field(_ title: String, value: Binding<Int>, unit: String, hint: String? = nil, issues: [ProgramIssue] = [], key: String? = nil) -> some View {
        let m = message(issues, key)
        LabeledContent {
            HStack { TextField(title, value: value, format: .number.grouping(.never)).labelsHidden().multilineTextAlignment(.trailing).frame(width: 90).monospacedDigit(); Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading) }
        } label: {
            Text(title)
            if let m { Text(m.message).foregroundStyle(m.severity == .blocker ? Color.red : Color.orange) } else if let hint { Text(hint).foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private func voltage(_ title: String, value: Binding<Int>, hint: String? = nil, issues: [ProgramIssue], key: String) -> some View {
        let volts = Binding<Double>(get: { Double(value.wrappedValue) / 1000 }, set: { value.wrappedValue = $0.isFinite ? Int((min(max($0, -1000), 1000) * 1000).rounded()) : -1 })
        let m = message(issues, key)
        LabeledContent {
            HStack { TextField(title, value: volts, format: .number.precision(.fractionLength(3))).labelsHidden().multilineTextAlignment(.trailing).frame(width: 90).monospacedDigit(); Text("V").foregroundStyle(.secondary).frame(width: 34, alignment: .leading) }
        } label: {
            Text(title)
            if let m { Text(m.message).foregroundStyle(m.severity == .blocker ? Color.red : Color.orange) } else if let hint { Text(hint).foregroundStyle(.secondary) }
        }
    }
}

struct CheckSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let program: Program
    let slots: [Int]
    @Local private var checks: [SlotCheck] = []
    @Local private var phase = Phase.writing
    @Local private var message: String?
    @Local private var others: [OtherSlotOnStart] = []
    enum Phase { case writing, checked, starting, global, done }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(phase == .writing ? "Writing to the charger…" : "Check before start").font(.title2.weight(.semibold))
            if phase == .writing { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(checks) { CheckCard(check: $0) }
                    if phase == .global { GlobalWarning(others: others) }
                }
            }
            if let message { Text(message).foregroundStyle(.red) }
            HStack {
                Button(phase == .done ? "Close" : "Cancel") { dismiss() }.buttonStyle(.glass)
                Spacer()
                if phase == .checked || phase == .starting {
                    let n = checks.filter(\.canStart).map { "\($0.slot + 1)" }.joined(separator: ", ")
                    Button(checks.contains { $0.outcome == .unverifiedBluetooth } ? "Start slot \(n) without read-back" : "Start slot \(n)") { start() }
                        .buttonStyle(.glassProminent).disabled(phase == .starting || !checks.contains(where: \.canStart))
                }
                if phase == .global {
                    Button("Start every loaded slot") { startAll() }.buttonStyle(.glassProminent).tint(.red).disabled(others.contains { $0.problem != nil })
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 600)
        .task {
            checks = await model.charger.writeAndCheck(program, slots: slots)
            phase = .checked
        }
    }
    private func start() {
        phase = .starting; message = nil
        model.willStart(checks: checks)
        Task {
            switch await model.charger.start(checks: checks) {
            case .started: model.section = .live; dismiss()
            case .failed(let m): model.startFailed(checks: checks); message = m; phase = .checked
            case .needsGlobalConfirmation(let o): others = o; phase = .global
            }
        }
    }
    private func startAll() {
        model.willStart(checks: checks)
        Task {
            switch await model.charger.startAllOverUSB(checks: checks, others: others) {
            case .started: model.section = .live; dismiss()
            case .failed(let m): model.startFailed(checks: checks); message = m
            case .needsGlobalConfirmation(let o): others = o; message = "Something changed on the charger. Check this list again."
            }
        }
    }
}

struct GlobalWarning: View {
    let others: [OtherSlotOnStart]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bluetooth can't be reached").font(.headline)
            Text("USB can only start every loaded slot at once.").foregroundStyle(.secondary)
            if others.isEmpty { Text("No other slot has a cell in it.") }
            ForEach(others) { o in
                if let p = o.problem { Label("Slot \(o.slot + 1): \(p)", systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
                else if let g = o.program { Label("Slot \(o.slot + 1) would also start: \(g.type.name) \(g.mode.name(for: g.type)), \(g.chargeCurrent) mA", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
        }
        .panel()
    }
}

struct CheckCard: View {
    let check: SlotCheck
    @Local private var showAll = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Slot \(check.slot + 1)").font(.headline)
                Spacer()
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2).background(color, in: .capsule)
            }
            Text(explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let sent = check.sent.fields
            let got = check.onCharger?.fields
            if check.outcome == .mismatch, let got {
                table(zip(sent, got).filter { $0.value != $1.value }.map { ($0.name, $0.value, $1.value) }, red: true)
            } else if check.outcome == .verified && showAll, let got {
                table(zip(sent, got).map { ($0.name, $0.value, $1.value) }, red: false)
            }
            if check.outcome == .verified { Button(showAll ? "Hide fields" : "Show all \(sent.count) fields") { showAll.toggle() }.buttonStyle(.link) }
            if check.outcome == .unverifiedBluetooth { Text("The app will watch the first readings after the start and stop the slot if its type or mode is wrong, or a limit is passed.").font(.callout) }
        }
        .panel()
    }
    private var title: String {
        switch check.outcome { case .verified: "All \(check.sent.fields.count) fields match"; case .mismatch: "Program doesn't match"; case .writeFailed: "Write failed"; case .unverifiedBluetooth: "Sent, can't read back"; case .notAllowed: "Not sent" }
    }
    private var color: Color { switch check.outcome { case .verified: .green; case .mismatch, .writeFailed: .red; case .unverifiedBluetooth, .notAllowed: .orange } }
    private var explanation: String {
        switch check.outcome {
        case .verified: "The charger holds exactly what was sent. Starting one slot switches to Bluetooth, so logging pauses on every slot for about 5–7 seconds, and the gap is marked."
        case .mismatch:
            if check.onCharger?.type != check.sent.type { "The charger replaced this program with different defaults. Starting it could damage the cell, so Start is off for this slot." } else { "What's on the charger differs from what was sent, so Start is off for this slot." }
        case .writeFailed: "The charger didn't accept this program, or the slot is busy. Its stored program may be unchanged. Try again."
        case .notAllowed(let reason): reason
        case .unverifiedBluetooth: "The charger acknowledged it. Reading a program back needs the USB cable, so what's stored can't be confirmed."
        }
    }
    private func table(_ rows: [(String, String, String)], red: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow { Text("Setting"); Text("Sent"); Text("On charger") }.font(.callout).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { r in GridRow { Text(r.0); Text(r.1).monospacedDigit(); Text(r.2).monospacedDigit().fontWeight(.medium).foregroundStyle(red ? Color.red : Color.primary) } }
        }
    }
}
