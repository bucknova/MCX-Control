import CoreBluetooth
import Foundation
import IOKit.hid
import MCXCore

/// One request at a time on a link.
@MainActor final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async { if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true } }
    func release() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
}

@MainActor final class USBLink {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let lock = AsyncLock()
    private var pending: (match: ([UInt8]) -> Bool, k: CheckedContinuation<[UInt8]?, Never>)?
    private var requestID = 0
    var present: Bool { device != nil }
    var onChange: (() -> Void)?

    func start() {
        // Vendor ID 0 is what this charger reports; the product name check keeps other devices out.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0, kIOHIDProductIDKey: 1] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { c, _, _, d in
            let s = Unmanaged<USBLink>.fromOpaque(c!).takeUnretainedValue()
            MainActor.assumeIsolated { s.attach(d) }
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { c, _, _, d in
            let s = Unmanaged<USBLink>.fromOpaque(c!).takeUnretainedValue()
            MainActor.assumeIsolated { s.detach(d) }
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, 0)
    }
    private func attach(_ d: IOHIDDevice) {
        guard (IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String) == "STM32 Custm HID", device == nil else { return }
        guard IOHIDDeviceOpen(d, 0) == kIOReturnSuccess else { return }
        device = d
        IOHIDDeviceRegisterInputReportCallback(d, buffer, 64, { c, _, _, _, _, r, n in
            let s = Unmanaged<USBLink>.fromOpaque(c!).takeUnretainedValue()
            let a = (0..<n).map { r[$0] }
            MainActor.assumeIsolated { s.received(a) }
        }, Unmanaged.passUnretained(self).toOpaque())
        onChange?()
    }
    private func detach(_ d: IOHIDDevice) { if d == device { device = nil; onChange?() } }
    private func received(_ r: [UInt8]) { if let p = pending, p.match(r) { pending = nil; p.k.resume(returning: r) } }

    @discardableResult func send(_ head: [UInt8]) -> Bool {
        guard let device else { return false }
        var p = [UInt8](repeating: 0, count: 64); p.replaceSubrange(0..<head.count, with: head)
        return p.withUnsafeBufferPointer { IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, 64) } == kIOReturnSuccess
    }
    func request(_ head: [UInt8], timeout: Double, match: @escaping ([UInt8]) -> Bool) async -> [UInt8]? {
        await lock.acquire(); defer { lock.release() }
        requestID &+= 1
        let id = requestID
        return await withCheckedContinuation { k in
            pending = (match, k)
            guard send(head) else { pending = nil; k.resume(returning: nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Only this request's own timeout may end it; an earlier one's timer must not cancel a later request.
                MainActor.assumeIsolated { if let self, self.requestID == id, let p = self.pending { self.pending = nil; p.k.resume(returning: nil) } }
            }
        }
    }
}

@MainActor final class BluetoothLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let names: Set<String> = ["Charger", "SimpleBLEPeripheral", "HitecCharger"]
    private static let savedKey = "chargerBluetoothID"
    private let service = CBUUID(string: "FFE0"), characteristicID = CBUUID(string: "FFE1")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var readyK: [CheckedContinuation<Bool, Never>] = []
    private var downK: CheckedContinuation<Void, Never>?
    private var pending: (match: ([UInt8]) -> Bool, k: CheckedContinuation<[UInt8]?, Never>)?
    private var collecting: [UInt8]?
    private var requestID = 0
    private var discoveryTries = 0
    private let lock = AsyncLock()
    private(set) var isConnected = false
    private(set) var unauthorized = false
    var poweredOn: Bool { central?.state == .poweredOn }
    var onDisconnect: (() -> Void)?

    func start() { central = CBCentralManager(delegate: self, queue: .main) }

    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) { MainActor.assumeIsolated { unauthorized = c.state == .unauthorized } }
    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            // Other devices advertise the same service (an FNB58 meter does), so the name has to match too.
            let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
            guard Self.names.contains(name), peripheral == nil else { return }
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.savedKey)
            peripheral = p; p.delegate = self; c.stopScan(); c.connect(p)
        }
    }
    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([CBUUID(string: "FFE0")]) }
    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { MainActor.assumeIsolated { finishConnect(false) } }
    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            isConnected = false; characteristic = nil
            if let k = downK { downK = nil; k.resume() } else { onDisconnect?() }
            finishConnect(false)
            if let w = pending { pending = nil; w.k.resume(returning: nil) }
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices e: Error?) {
        if let s = p.services?.first(where: { $0.uuid == CBUUID(string: "FFE0") }) { p.discoverCharacteristics([CBUUID(string: "FFE1")], for: s) }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let c = s.characteristics?.first(where: { $0.uuid == characteristicID }) else { discoveryTries += 1; central.cancelPeripheralConnection(p); return }
            characteristic = c; p.setNotifyValue(true, for: c)
        }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { if c.isNotifying { isConnected = true; finishConnect(true) } }
    }
    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value else { return }
        let a = [UInt8](v)
        MainActor.assumeIsolated {
            if collecting != nil { collecting!.append(contentsOf: a); return }
            if let w = pending, w.match(a) { pending = nil; w.k.resume(returning: a) }
        }
    }
    private func finishConnect(_ ok: Bool) { let w = readyK; readyK = []; w.forEach { $0.resume(returning: ok) } }

    func connect(timeout: Double) async -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        if isConnected { return true }
        return await withCheckedContinuation { k in
            readyK.append(k)
            if let p = peripheral { central.connect(p) }
            else if let s = UserDefaults.standard.string(forKey: Self.savedKey), let id = UUID(uuidString: s), let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                peripheral = p; p.delegate = self; central.connect(p)
            } else { central.scanForPeripherals(withServices: [service]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.readyK.isEmpty else { return }
                    central.stopScan()
                    if !self.isConnected, let p = self.peripheral { central.cancelPeripheralConnection(p) }
                    self.finishConnect(false)
                }
            }
        }
    }
    func disconnect() async {
        guard let p = peripheral, isConnected else { return }
        await withCheckedContinuation { downK = $0; central.cancelPeripheralConnection(p) }
    }
    private func write(_ b: [UInt8]) { if let c = characteristic { peripheral?.writeValue(Data(b), for: c, type: .withoutResponse) } }

    func request(_ b: [UInt8], timeout: Double, match: @escaping ([UInt8]) -> Bool) async -> [UInt8]? {
        await lock.acquire(); defer { lock.release() }
        return await replyAfter(write: b, timeout: timeout, match: match)
    }
    private func replyAfter(write b: [UInt8], timeout: Double, match: @escaping ([UInt8]) -> Bool) async -> [UInt8]? {
        requestID &+= 1
        let id = requestID
        return await withCheckedContinuation { k in
            pending = (match, k); write(b)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                // Only this request's own timeout may end it; an earlier one's timer must not cancel a later request.
                MainActor.assumeIsolated { if let self, self.requestID == id, let w = self.pending { self.pending = nil; w.k.resume(returning: nil) } }
            }
        }
    }
    /// Programs go out as two 20-byte chunks about 50 ms apart.
    func writeProgram(_ frame: [UInt8], slot: Int) async -> Bool {
        await lock.acquire(); defer { lock.release() }
        write(Array(frame[0..<20]))
        try? await Task.sleep(nanoseconds: 50_000_000)
        return await replyAfter(write: Array(frame[20..<40]), timeout: 3) { Wire.isAck($0, op: 0x11, slot: slot) } != nil
    }
}
