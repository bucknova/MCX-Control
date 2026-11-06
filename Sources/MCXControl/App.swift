import AppKit
import MCXCore
import SwiftUI

@main struct MCXControlApp: App {
    @Local private var model = AppModel()
    var body: some Scene {
        WindowGroup("MC-X Control") {
            RootView().environment(model).frame(minWidth: 1000, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 860)
    }
}

/// A slightly tinted window, so the glass controls have something to sit on and the white panels stand out.
private let windowTint = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1) : NSColor(red: 0.89, green: 0.906, blue: 0.93, alpha: 1) })

struct RootView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 0) {
            SideNav()
            VStack(spacing: 0) {
                TopBar().zIndex(1)
                Group {
                    switch model.section {
                    case .live: LiveView()
                    case .programs: ProgramView()
                    case .tests: TestsView()
                    case .cells: CellsView()
                    case .match: MatchView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped() // Forms and lists otherwise draw up under the title and toolbar.
                .overlay(alignment: .top) { BannerView() } // Floats over the content, so a long message can never change the layout.
            }
        }
        .background(windowTint)
        .ignoresSafeArea()
        // A real toolbar sets the window buttons down inside the sidebar panel, and native toolbar items always get their clicks.
        .toolbar {
            // This window has no split view to push items right, so a flexible spacer does it.
            ToolbarSpacer(.flexible)
            ToolbarItem { ConnectionChip() }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                // Always red and always live: stopping is the one control that should never look unavailable.
                Button("Stop all slots", systemImage: "stop.fill") { model.stopAll() }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.glassProminent).tint(.red)
                    .help("Stops every slot immediately")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// The floating glass sidebar. The window's traffic lights sit in the space at the top.
struct SideNav: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.frame(height: 34)
            ForEach(AppSection.allCases) { s in
                let on = model.section == s
                Button { model.section = s } label: {
                    HStack(spacing: 8) { Image(systemName: s.icon).frame(width: 20); Text(s.rawValue) }
                        .fontWeight(on ? .semibold : .regular)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(on ? Color.accentColor : Color.clear, in: .rect(cornerRadius: 11))
                        .contentShape(.rect(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.leading, 10).padding(.vertical, 10)
    }
}

/// The screen title, level with the toolbar's controls.
struct TopBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            Text(model.section.rawValue).font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

struct ConnectionChip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let c = model.charger.connection
        HStack(spacing: 6) {
            Circle().fill(c == .none ? Color.orange : c == .switching ? Color.yellow : Color.green).frame(width: 8, height: 8)
            Text(c.label)
            if let f = model.charger.firmware { Text("· Firmware \(f)").foregroundStyle(.secondary) }
        }
        .font(.callout).padding(.horizontal, 8)
        .contextMenu {
            if model.charger.isPaired { Button("Forget paired Bluetooth charger") { model.charger.forgetPairing() } }
        }
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 6) {
            if !model.charger.isPaired && !model.charger.candidates.isEmpty { PairingBar() }
            if model.charger.identity?.isFahrenheit == true {
                bar("The charger is set to °F. Programs are locked and temperatures may be in °F, not the °C shown. Change it to °C on the charger.", dismiss: nil)
            }
            if model.charger.bluetoothDenied {
                bar("Bluetooth access is off for this app. Turn it on in System Settings › Privacy & Security › Bluetooth to use it.", dismiss: nil)
            }
            if let b = model.banner { bar(b) { model.banner = nil } }
        }
    }
    private func bar(_ t: String, dismiss: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(t).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.glass) }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16).padding(.top, 6)
    }
}

/// Bluetooth has no way to tell chargers apart by itself, so you choose which one this Mac controls.
struct PairingBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose your charger for Bluetooth control").fontWeight(.semibold)
            Text(model.charger.candidates.count > 1 ? "More than one is nearby. The strongest signal is usually the closest." : "Only pair with a charger you own.").font(.callout).foregroundStyle(.secondary)
            HStack {
                ForEach(model.charger.candidates) { c in
                    Button("\(c.name) ···\(c.id.uuidString.suffix(4)) · \(c.signal) dBm") { model.charger.pair(with: c.id) }.buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(.horizontal, 16).padding(.top, 6)
    }
}

// MARK: Shared pieces
struct Metric: View {
    let title: String; let value: String; var note: String? = nil; var noteColor: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if let note { Text(note).font(.caption).foregroundStyle(noteColor) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Readings sit on a solid surface; glass is for the controls above them.
    /// The same surface without inner padding, for lists and tables that manage their own.
    func listPanel() -> some View { scrollContentBackground(.hidden).background(Color(nsColor: .textBackgroundColor)).clipShape(.rect(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08))) }
    func panel() -> some View { padding(16).background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08))) }
}

func statusColor(_ s: SlotStatus) -> Color {
    if s.isFault { return s.isExpectedCutoff ? .orange : .red }
    switch s.raw { case 1: return .blue; case 2: return .orange; case 3: return .gray; case 4: return .green; default: return .secondary }
}
func chipStyle(_ s: SlotStatus) -> some View { Text(s.label).font(.caption.weight(.semibold)).foregroundStyle(s.isIdle ? Color.secondary : Color.white).padding(.horizontal, 8).padding(.vertical, 2).background(s.isIdle ? Color.secondary.opacity(0.15) : statusColor(s), in: .capsule) }

/// Same job as SwiftUI's @State. @State's macro plugin ships with Xcode, and this builds with the Command Line Tools alone.
final class LocalBox<T>: ObservableObject { @Published var value: T; init(_ v: T) { value = v } }
@propertyWrapper struct Local<T>: DynamicProperty {
    @StateObject private var box: LocalBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: LocalBox(wrappedValue)) }
    var wrappedValue: T { get { box.value } nonmutating set { box.value = newValue } }
    var projectedValue: Binding<T> { $box.value }
}
