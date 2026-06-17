import Foundation
import Network
import MonitorKit

/// A device that has paired with this agent, for the agent's paired-devices list.
public struct PairedDevice: Codable, Sendable, Identifiable, Hashable {
    public let id: String      // stable per-install device ID from `hello`
    public var name: String
    public var lastSeen: Date
}

/// The agent's network face. Advertises via Bonjour and pushes system + process
/// snapshots to every paired client; traffic is sealed with `SecureChannel`
/// (ChaChaPoly over plain TCP). Handles kill requests against the live `Killer`.
///
/// All state (samplers, connections, timer, registries) is confined to `queue`,
/// so the type is `@unchecked Sendable`: every member is only touched on it.
public final class MonitorServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped, starting, ready(port: UInt16), failed(String)
    }

    public var onState: (@Sendable (State) -> Void)?
    public var onClientCountChanged: (@Sendable (Int) -> Void)?
    /// Reports the persisted paired devices and the subset currently connected.
    public var onDevicesChanged: (@Sendable ([PairedDevice], Set<String>) -> Void)?
    public private(set) var pairingCode: String

    private let queue = DispatchQueue(label: "com.jakewatts.monitor.server")
    private let processSampler = ProcessSampler()
    private let systemSampler = SystemSampler()
    private let killer = Killer()
    private let helper = PrivilegedHelperClient()
    private let controller = MacController()

    private var channel = SecureChannel(code: "")
    private var listener: NWListener?
    private let sleepGuard = SleepAssertion()
    private var timer: DispatchSourceTimer?
    private var connections: [ObjectIdentifier: Conn] = [:]
    private var tick = 0
    private var lastProcCount = 0

    private var paired: [String: PairedDevice] = [:]
    private var revoked: Set<String> = []
    private var iconCache: [String: Data] = [:]   // executable path → PNG
    private static let pairedKey = "monitor.pairedDevices"
    private static let revokedKey = "monitor.revokedDevices"

    /// Per-connection state: the socket plus its own reassembly buffer.
    /// Only ever touched on the server `queue`, hence `@unchecked Sendable`.
    private final class Conn: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var greeted = false
        var sessionNonce: UInt64 = 0
        var deviceID: String?
        init(_ c: NWConnection) { connection = c }
    }

    public init(pairingCode: String? = nil) {
        self.pairingCode = pairingCode ?? MonitorPairing.generateCode()
        loadRegistry()
    }

    // MARK: - Paired device registry

    /// Snapshot of paired devices (most-recently-seen first). Safe to call from
    /// any thread.
    public func pairedDevices() -> [PairedDevice] {
        queue.sync { paired.values.sorted { $0.lastSeen > $1.lastSeen } }
    }

    /// Revokes a device: drops it from the paired list, blocks it from re-serving,
    /// and disconnects it now. (It can re-pair if it still has the code — rotate
    /// the code with a new pairing code to fully lock it out.)
    public func revoke(deviceID: String) {
        queue.async {
            self.revoked.insert(deviceID)
            self.paired.removeValue(forKey: deviceID)
            let toDrop = self.connections.filter { $0.value.deviceID == deviceID }.map { $0.key }
            for id in toDrop {
                self.connections[id]?.connection.cancel()
                self.connections.removeValue(forKey: id)
            }
            self.saveRegistry()
            self.emitDevices()
        }
    }

    private func upsertPaired(deviceID: String, name: String) {
        var device = paired[deviceID] ?? PairedDevice(id: deviceID, name: name, lastSeen: Date())
        device.name = name
        device.lastSeen = Date()
        paired[deviceID] = device
        saveRegistry()
        emitDevices()
    }

    private func emitDevices() {
        let list = paired.values.sorted { $0.lastSeen > $1.lastSeen }
        let connected = Set(connections.values.compactMap { $0.deviceID })
        onDevicesChanged?(list, connected)
    }

    private func loadRegistry() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.pairedKey),
           let arr = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            paired = Dictionary(uniqueKeysWithValues: arr.map { ($0.id, $0) })
        }
        if let r = defaults.array(forKey: Self.revokedKey) as? [String] { revoked = Set(r) }
    }

    private func saveRegistry() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(Array(paired.values)) {
            defaults.set(data, forKey: Self.pairedKey)
        }
        defaults.set(Array(revoked), forKey: Self.revokedKey)
    }

    /// Rotates the pairing code. Requires a restart to take effect (the channel
    /// key is derived from the code at start).
    public func setPairingCode(_ code: String) {
        queue.sync { self.pairingCode = code }
    }

    public func start(port: UInt16? = nil, advertiseBonjour: Bool = true) {
        queue.async { self._start(port: port, advertiseBonjour: advertiseBonjour) }
    }

    public func stop() {
        queue.async {
            self.teardown()
            self.onState?(.stopped)
        }
    }

    /// Cancels the timer, all connections, and the listener. Must run on `queue`.
    private func teardown() {
        timer?.cancel(); timer = nil
        for conn in connections.values { conn.connection.cancel() }
        connections.removeAll()
        listener?.cancel(); listener = nil
        sleepGuard.release()   // let the Mac sleep normally once we stop serving
    }

    // MARK: - Listener

    private func _start(port: UInt16?, advertiseBonjour: Bool) {
        onState?(.starting)
        channel = SecureChannel(code: pairingCode)
        let params = MonitorTransport.parameters()

        let listener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: params, on: nwPort)
            } else {
                listener = try NWListener(using: params)
            }
        } catch {
            onState?(.failed(error.localizedDescription))
            return
        }

        if advertiseBonjour {
            listener.service = NWListener.Service(name: nil, type: kMonitorBonjourServiceType, domain: nil)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let p = self.listener?.port?.rawValue ?? 0
                // Keep the Mac awake while serving so idle sleep can't drop the
                // connection and close the paired app.
                self.sleepGuard.acquire()
                self.onState?(.ready(port: p))
                self.startBroadcastTimer()
            case .failed(let error):
                // Tear down so the timer/connections/socket don't leak while the
                // UI shows "failed".
                self.teardown()
                self.onState?(.failed(error.localizedDescription))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        let conn = Conn(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connections[ObjectIdentifier(conn)] = conn
                self.onClientCountChanged?(self.connections.count)
                self.receive(conn)
            case .failed, .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
                self.onClientCountChanged?(self.connections.count)
                self.emitDevices()   // a device may have just disconnected
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    // MARK: - Receive / handle

    private func receive(_ conn: Conn) {
        conn.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                conn.buffer.append(data)
                do {
                    while let payload = try MonitorFraming.nextPayload(from: &conn.buffer) {
                        if let msg = try? self.channel.open(ClientMessage.self, from: payload) {
                            self.handle(msg, on: conn)
                        } else {
                            // A frame we can't decrypt means the peer doesn't hold
                            // the pairing key. Reject the connection outright.
                            conn.connection.cancel()
                            return
                        }
                    }
                } catch {
                    // Oversized length prefix (would buffer gigabytes) → drop.
                    conn.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                conn.connection.cancel()
                return
            }
            self.receive(conn)
        }
    }

    private func handle(_ message: ClientMessage, on conn: Conn) {
        switch message {
        case let .hello(name, deviceID, version, _):
            guard !revoked.contains(deviceID) else {
                send(.pairingFailed(reason: "Access for this device was revoked on the Mac."), to: conn)
                conn.connection.cancel()
                return
            }
            conn.greeted = true
            conn.deviceID = deviceID
            upsertPaired(deviceID: deviceID, name: name)
            // Fresh per-connection nonce; the client echoes it on kills so a
            // captured kill frame from another session is rejected.
            let nonce = UInt64.random(in: UInt64.min...UInt64.max)
            conn.sessionNonce = nonce
            send(.helloAck(serverName: ProcessInfo.processInfo.hostName,
                           protocolVersion: kMonitorProtocolVersion,
                           paired: true,
                           sessionNonce: nonce), to: conn)
            if version != kMonitorProtocolVersion {
                send(.error("Protocol mismatch: agent v\(kMonitorProtocolVersion), client v\(version)"), to: conn)
            }
            // Send an immediate snapshot so the client isn't blank for ~1s.
            pushSnapshot(to: conn)

        case .requestSnapshot:
            pushSnapshot(to: conn)

        case let .kill(pid, signal, startTime, sessionNonce):
            // Must be paired this session and carry this session's nonce
            // (blocks replays from another session).
            guard conn.greeted, sessionNonce == conn.sessionNonce else {
                send(.killResult(pid: pid, success: false, message: "Unauthorized or stale kill request"), to: conn)
                break
            }
            // The live process must still be the incarnation the client saw
            // (blocks killing the wrong process after PID reuse).
            if let live = processSampler.currentStartTime(of: pid), live != startTime {
                send(.killResult(pid: pid, success: false, message: "pid \(pid) is no longer the process you selected"), to: conn)
                break
            }
            let sig = MonitorSignal(rawValue: signal) ?? .term
            let result = killer.kill(pid: pid, signal: sig)
            if result.success {
                send(.killResult(pid: pid, success: true, message: result.message), to: conn)
            } else if helper.isEnabled {
                // Local kill failed (typically EPERM on a root/other-user
                // process). Route through the privileged helper, then reply on
                // our queue if the connection is still alive.
                let connID = ObjectIdentifier(conn)
                let nonce = conn.sessionNonce
                let helper = self.helper
                Task { [weak self] in
                    let (ok, msg) = await helper.kill(pid: pid, signal: sig)
                    guard let self else { return }
                    self.queue.async {
                        guard let c = self.connections[connID], c.sessionNonce == nonce else { return }
                        self.send(.killResult(pid: pid, success: ok,
                                              message: ok ? "[via helper] \(msg)" : msg), to: c)
                    }
                }
            } else {
                send(.killResult(pid: pid, success: false, message: result.message), to: conn)
            }

        case let .requestIcons(paths):
            var entries: [IconEntry] = []
            for path in paths.prefix(120) where !path.isEmpty {
                let png: Data
                if let cached = iconCache[path] {
                    png = cached
                } else if let data = IconProvider.pngIcon(forExecutablePath: path) {
                    iconCache[path] = data
                    png = data
                } else {
                    continue
                }
                entries.append(IconEntry(path: path, png: png))
            }
            if !entries.isEmpty { send(.icons(entries), to: conn) }

        case let .control(action, sessionNonce):
            guard conn.greeted, sessionNonce == conn.sessionNonce else {
                send(.controlResult(action: action, success: false, message: "Unauthorized or stale request"), to: conn)
                break
            }
            let result = controller.perform(action)
            send(.controlResult(action: action, success: result.success, message: result.message), to: conn)

        case .ping:
            send(.pong, to: conn)
        }
    }

    // MARK: - Broadcast

    private func startBroadcastTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.broadcast() }
        t.resume()
        timer = t
    }

    private func broadcast() {
        let greeted = connections.values.filter { $0.greeted }
        guard !greeted.isEmpty else { return }
        tick &+= 1

        // System stats are cheap → push every tick (1s). The full process
        // snapshot is the bandwidth-dominant payload → push every other tick
        // (2s), which roughly halves traffic while keeping gauges responsive.
        if tick % 2 == 0 {
            let procs = processSampler.sample(helperAvailable: helper.isEnabled)
            lastProcCount = procs.count
            if let snapData = try? channel.seal(ServerMessage.snapshot(procs)) {
                for conn in greeted {
                    conn.connection.send(content: snapData, completion: .contentProcessed { _ in })
                }
            }
        }

        let sys = systemSampler.sample(processCount: lastProcCount)
        if let sysData = try? channel.seal(ServerMessage.system(sys)) {
            for conn in greeted {
                conn.connection.send(content: sysData, completion: .contentProcessed { _ in })
            }
        }
    }

    private func pushSnapshot(to conn: Conn) {
        let procs = processSampler.sample(helperAvailable: helper.isEnabled)
        let sys = systemSampler.sample(processCount: procs.count)
        send(.system(sys), to: conn)
        send(.snapshot(procs), to: conn)
    }

    private func send(_ message: ServerMessage, to conn: Conn) {
        guard let data = try? channel.seal(message) else { return }
        conn.connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
