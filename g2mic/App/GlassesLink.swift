import CoreBluetooth
import Foundation
import G2Core

/// Talks to both arms of the G2 over Bluetooth LE and streams the glasses' microphone.
///
/// Sequence (from the community reverse engineering in g2-kit):
///  1. Connect both arms, subscribe to command-notify (5402) and render-notify (6402).
///  2. Send the app-launch prelude to the right arm.
///  3. Create a small startup page (brings up the "plugin task" the mic depends on).
///  4. Heartbeat every 5 s, or the firmware kills the task (and the mic) after ~10 s.
///  5. AudioControl(enable) -> 205-byte LC3 packets arrive on render-notify (left arm).
///
/// All CoreBluetooth callbacks run on the main queue; this class is main-thread only.
final class GlassesLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case connected
        case micStarting
        case micOn
        case failed(String)

        var label: String {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .unauthorized: return "Bluetooth permission needed"
            case .searching: return "Looking for G2…"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .micStarting: return "Starting glasses mic…"
            case .micOn: return "Glasses mic on"
            case .failed(let why): return "Problem: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var armNames: [String] = []
    @Published private(set) var log: [String] = []

    /// Raw 205-byte mic packets.
    var onAudioPacket: (([UInt8]) -> Void)?

    private final class Arm {
        let side: G2Arm
        let peripheral: CBPeripheral
        var write: CBCharacteristic?
        var commandNotifyReady = false
        var renderNotifyReady = false
        var reassembler = EnvelopeReassembler()
        var queue: [Data] = []
        init(side: G2Arm, peripheral: CBPeripheral) {
            self.side = side
            self.peripheral = peripheral
        }
        var ready: Bool { write != nil && commandNotifyReady }
    }

    private var central: CBCentralManager!
    private var arms: [G2Arm: Arm] = [:]
    private var transportSeq: UInt8 = 0x40
    private var magicCounter: UInt8 = 100
    private var pageCounter = 0
    private var waiters: [String: (EnvelopeMessage?) -> Void] = [:]
    private var heartbeatTimer: Timer?
    private var watchdogTimer: Timer?
    private var missedHeartbeats = 0
    private var preludeDone = false
    private var pluginAlive = false
    private var settingUp = false
    private var micWanted = false
    private var lastAudioAt = Date.distantPast
    private var micStartedAt = Date.distantPast

    private let savedIDsKey = "g2.peripheralIDs"
    private let commandService = CBUUID(string: G2UUID.commandService)
    private let renderService = CBUUID(string: G2UUID.renderService)
    private let commandWrite = CBUUID(string: G2UUID.commandWrite)
    private let commandNotify = CBUUID(string: G2UUID.commandNotify)
    private let renderNotify = CBUUID(string: G2UUID.renderNotify)

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isMicOn: Bool { status == .micOn }

    // MARK: Public control

    /// Ask for the glasses mic. Connects first if needed; safe to call repeatedly.
    func startMic() {
        micWanted = true
        micStartedAt = Date()
        if bothArmsReady { bringUpMic() } else { connect() }
        startWatchdog()
    }

    /// Turn the glasses mic off and let the glasses return to normal.
    func stopMic() {
        micWanted = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        guard bothArmsReady else { return }
        send(sid: EvenHub.sid, payload: EvenHub.audioControl(enable: false, magic: nextMagic()), timeout: 1.5) { _ in }
        // Stop heartbeats; the firmware drops our page after ~10 s and the HUD returns to normal.
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        pluginAlive = false
        if status == .micOn || status == .micStarting { status = .connected }
    }

    func connect() {
        guard central.state == .poweredOn else { return }
        if bothArmsReady { return }
        status = .searching
        var candidates: [CBPeripheral] = []
        let saved = UserDefaults.standard.dictionary(forKey: savedIDsKey) as? [String: String] ?? [:]
        let savedIDs = saved.keys.compactMap(UUID.init(uuidString:))
        for p in central.retrievePeripherals(withIdentifiers: savedIDs) {
            consider(p, name: p.name, knownSide: saved[p.identifier.uuidString].flatMap(G2Arm.init(rawValue:)))
        }
        candidates += central.retrieveConnectedPeripherals(withServices: [commandService])
        for p in candidates { consider(p, name: p.name) }
        if arms.count < 2 {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.arms.count < 2, self.central.isScanning else { return }
                self.central.stopScan()
                if self.arms.isEmpty { self.status = .failed("glasses not found — are they on and nearby?") }
            }
        }
    }

    func forgetGlasses() {
        stopMic()
        for arm in arms.values { central.cancelPeripheralConnection(arm.peripheral) }
        arms.removeAll()
        UserDefaults.standard.removeObject(forKey: savedIDsKey)
        preludeDone = false
        armNames = []
        status = .searching
    }

    // MARK: Session setup

    private var bothArmsReady: Bool {
        guard let l = arms[.left], let r = arms[.right] else { return false }
        return l.ready && r.ready
    }

    private func bringUpMic() {
        guard micWanted, !settingUp else { return }
        settingUp = true
        status = .micStarting
        ensurePluginTask { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.settingUp = false
                self.status = .failed("glasses didn't accept the session")
                return
            }
            self.send(sid: EvenHub.sid, payload: EvenHub.audioControl(enable: true, magic: self.nextMagic()), timeout: 3) { reply in
                self.settingUp = false
                if let reply, let stat = EvenHub.audioStatus(from: reply) {
                    self.note("mic enable acked (status \(stat))")
                } else {
                    self.note("mic enable not acked; waiting for audio anyway")
                }
                if self.micWanted, self.status == .micStarting {
                    // Becomes .micOn on the first audio packet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.micWanted, self.status == .micStarting, Date().timeIntervalSince(self.lastAudioAt) > 3 {
                            self.status = .failed("no audio from glasses")
                        }
                    }
                }
            }
        }
    }

    private func ensurePluginTask(_ done: @escaping (Bool) -> Void) {
        if pluginAlive { return done(true) }
        let createPage = { [weak self] in
            guard let self else { return }
            // A fresh name each time: re-CREATE of an existing name never acks.
            self.pageCounter = (self.pageCounter + 1) % 1000
            let name = "g2mic\(self.pageCounter)"
            let payload = EvenHub.createStartupPage(name: name, items: ["G2 Mic · listening"], magic: self.nextMagic())
            self.send(sid: EvenHub.sid, payload: payload, timeout: 3) { reply in
                if reply == nil { self.note("page create not acked; continuing") }
                self.pluginAlive = true
                self.startHeartbeat()
                done(true)
            }
        }
        if preludeDone { return createPage() }
        let frames = Envelope.frame(payload: AppLaunch.preludePayload, seq: AppLaunch.preludeSeq, sid: AppLaunch.sid)
        expectReply(sid: AppLaunch.sid, magic: AppLaunch.preludeMagic, timeout: 5) { [weak self] reply in
            guard let self else { return }
            if reply == nil {
                self.note("prelude not acked")
                return done(false)
            }
            self.preludeDone = true
            createPage()
        }
        enqueue(frames, on: .right)
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        missedHeartbeats = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.send(sid: EvenHub.sid, payload: EvenHub.heartbeat(magic: self.nextMagic()), timeout: 1.5) { reply in
                if reply == nil {
                    self.missedHeartbeats += 1
                    if self.missedHeartbeats >= 3 {
                        self.note("heartbeats lost; restarting session")
                        self.pluginAlive = false
                        self.preludeDone = false
                        self.heartbeatTimer?.invalidate()
                        if self.micWanted { self.bringUpMic() }
                    }
                } else {
                    self.missedHeartbeats = 0
                }
            }
        }
    }

    /// Restarts the mic if audio stops while we still want it.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.micWanted, self.bothArmsReady, !self.settingUp else { return }
            let quietFor = Date().timeIntervalSince(max(self.lastAudioAt, self.micStartedAt))
            if quietFor > 4 {
                self.note("no audio for \(Int(quietFor)) s; re-arming mic")
                self.micStartedAt = Date()
                self.pluginAlive = false
                self.bringUpMic()
            }
        }
    }

    // MARK: Messaging

    private func nextMagic() -> UInt8 {
        magicCounter = magicCounter >= 250 ? 100 : magicCounter + 1
        return magicCounter
    }

    private func send(sid: UInt8, payload: [UInt8], timeout: TimeInterval, arm: G2Arm = .right,
                      completion: @escaping (EnvelopeMessage?) -> Void) {
        // Magic is field 2 of every EvenHub request; the reply echoes it.
        let magic = ProtoReader.fields(payload).flatMap { ProtoReader.firstVarint($0, 2) }.map { UInt32(truncatingIfNeeded: $0) } ?? 0
        transportSeq &+= 1
        let chunk = min(Envelope.defaultChunkSize, max(32, maxWrite(arm) - Envelope.headerSize))
        let frames = Envelope.frame(payload: payload, seq: transportSeq, sid: sid, chunkSize: chunk)
        expectReply(sid: sid, magic: magic, timeout: timeout, completion)
        enqueue(frames, on: arm)
    }

    private func expectReply(sid: UInt8, magic: UInt32, timeout: TimeInterval, _ completion: @escaping (EnvelopeMessage?) -> Void) {
        let key = "\(sid):\(magic)"
        waiters[key] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let w = self?.waiters.removeValue(forKey: key) { w(nil) }
        }
    }

    private func maxWrite(_ side: G2Arm) -> Int {
        arms[side]?.peripheral.maximumWriteValueLength(for: .withoutResponse) ?? 240
    }

    private func enqueue(_ frames: [[UInt8]], on side: G2Arm) {
        guard let arm = arms[side] else { return }
        arm.queue += frames.map { Data($0) }
        flush(arm)
    }

    private func flush(_ arm: Arm) {
        guard let write = arm.write else { return }
        while !arm.queue.isEmpty, arm.peripheral.canSendWriteWithoutResponse {
            arm.peripheral.writeValue(arm.queue.removeFirst(), for: write, type: .withoutResponse)
        }
    }

    private func handle(_ message: EnvelopeMessage) {
        guard let magic = message.magic else { return }
        if let w = waiters.removeValue(forKey: "\(message.sid):\(magic)") { w(message) }
    }

    private func note(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: Discovery bookkeeping

    private func consider(_ p: CBPeripheral, name: String?, knownSide: G2Arm? = nil) {
        guard let side = G2Arm.from(advertisedName: name ?? p.name) ?? knownSide else { return }
        if let existing = arms[side], existing.peripheral.identifier == p.identifier { return }
        // Don't mix arms from two different pairs: keep the first pair we see.
        arms[side] = Arm(side: side, peripheral: p)
        p.delegate = self
        armNames = arms.values.map { $0.peripheral.name ?? $0.side.rawValue }.sorted()
        status = .connecting
        central.connect(p, options: nil)
        if arms.count == 2 {
            central.stopScan()
            var saved: [String: String] = [:]
            for arm in arms.values { saved[arm.peripheral.identifier.uuidString] = arm.side.rawValue }
            UserDefaults.standard.set(saved, forKey: savedIDsKey)
        }
    }

    private func arm(for p: CBPeripheral) -> Arm? {
        arms.values.first { $0.peripheral.identifier == p.identifier }
    }

    private func armBecameReady() {
        guard bothArmsReady, status == .connecting || status == .searching else { return }
        status = .connected
        note("both arms ready")
        if micWanted {
            // Give the link a moment to settle, as the reference implementation does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.bringUpMic() }
        }
    }
}

extension GlassesLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: connect()
        case .unauthorized: status = .unauthorized
        case .poweredOff: status = .bluetoothOff
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        consider(peripheral, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([commandService, renderService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        note("connect failed: \(error?.localizedDescription ?? "unknown")")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let arm = arm(for: peripheral) else { return }
        note("\(arm.side.rawValue) arm disconnected")
        arm.write = nil
        arm.commandNotifyReady = false
        arm.renderNotifyReady = false
        arm.queue.removeAll()
        preludeDone = false
        pluginAlive = false
        settingUp = false
        heartbeatTimer?.invalidate()
        status = .connecting
        // Pending connects never time out: this reconnects whenever the glasses come back.
        central.connect(peripheral, options: nil)
    }
}

extension GlassesLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let arm = arm(for: peripheral) else { return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case commandWrite: arm.write = c
            case commandNotify, renderNotify: peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let arm = arm(for: peripheral) else { return }
        if let error { note("\(arm.side.rawValue) notify failed: \(error.localizedDescription)") }
        if characteristic.uuid == commandNotify { arm.commandNotifyReady = characteristic.isNotifying }
        if characteristic.uuid == renderNotify { arm.renderNotifyReady = characteristic.isNotifying }
        armBecameReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let arm = arm(for: peripheral), let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        if characteristic.uuid == renderNotify {
            guard bytes.count == G2AudioFormat.packetBytes else { return }
            lastAudioAt = Date()
            if micWanted, status != .micOn { status = .micOn }
            onAudioPacket?(bytes)
        } else if characteristic.uuid == commandNotify {
            if let msg = arm.reassembler.push(bytes) { handle(msg) }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if let arm = arm(for: peripheral) { flush(arm) }
    }
}
