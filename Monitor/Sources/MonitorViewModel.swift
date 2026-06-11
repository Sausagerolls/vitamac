import Foundation
import Network
import SwiftUI
import UIKit
import MonitorKit

/// Drives the whole iOS app: Bonjour discovery, pairing, the live connection
/// (with automatic reconnect), and the latest samples. All @Published state is
/// mutated on the main actor; network callbacks hop here.
@MainActor
final class MonitorViewModel: ObservableObject {
    struct Service: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    enum Screen: Equatable { case discovery, pairing, dashboard }
    enum Link: Equatable { case connecting, live, reconnecting, disconnected }
    enum SortKey: String, CaseIterable, Identifiable { case cpu = "CPU", memory = "Memory", name = "Name"; var id: String { rawValue } }

    @Published var services: [Service] = []
    @Published var screen: Screen = .discovery
    @Published var link: Link = .disconnected
    @Published var status = "Searching for Macs…"
    @Published var system: SystemSample?
    @Published private(set) var processes: [ProcessSample] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published var isDemo = false
    @Published var banner: String?
    @Published var pendingService: Service?
    @Published var sortKey: SortKey = .cpu
    @Published var searchText = ""
    @Published var pinnedKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedProcessKeys") ?? [])
    @Published var savedCode = UserDefaults.standard.string(forKey: "lastCode") ?? ""

    private var browser: NWBrowser?
    private var client: MonitorClient?
    private var consumeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// Stable per-install ID so the Mac can list/revoke this device.
    private let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()

    private var activeService: Service?
    private var activeCode: String?
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var sessionNonce: UInt64 = 0
    /// The client whose drop we last acted on — dedupes the two callbacks a
    /// single disconnect produces (onState .failed + stream finish).
    private var lastDroppedClient: MonitorClient?

    private var demoTimer: Timer?
    private var demoBusy = 30.0

    private var requestedIconPaths: Set<String> = []
    private var pendingIconPaths: Set<String> = []
    private var diskCheckedPaths: Set<String> = []
    private var iconFlushScheduled = false
    private var didPreloadIcons = false

    private let cpuHistoryLimit = 60

    var sortedProcesses: [ProcessSample] {
        var list = processes
        if !searchText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortKey {
        case .cpu: list.sort { $0.cpuPercent > $1.cpuPercent }
        case .memory: list.sort { $0.memoryFootprint > $1.memoryFootprint }
        case .name: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        // Pinned processes float to the top, keeping their relative sort order.
        let pinned = list.filter { pinnedKeys.contains(processKey($0)) }
        let rest = list.filter { !pinnedKeys.contains(processKey($0)) }
        return pinned + rest
    }

    func processKey(_ process: ProcessSample) -> String { process.executablePath ?? process.name }
    func isPinned(_ process: ProcessSample) -> Bool { pinnedKeys.contains(processKey(process)) }

    func togglePin(_ process: ProcessSample) {
        let key = processKey(process)
        if pinnedKeys.contains(key) { pinnedKeys.remove(key) } else { pinnedKeys.insert(key) }
        UserDefaults.standard.set(Array(pinnedKeys), forKey: "pinnedProcessKeys")
    }

    // MARK: - Startup

    /// Called once on launch: starts discovery and, if we paired with a Mac
    /// before, immediately tries to reconnect to it (reconstructing the Bonjour
    /// endpoint by name) so the user doesn't re-enter the code. Falls back to the
    /// discovery list if that Mac isn't reachable.
    func startup() {
        preloadIcons()
        startDiscovery()
        guard let name = UserDefaults.standard.string(forKey: "lastServiceName"),
              !name.isEmpty, !savedCode.isEmpty else { return }
        let endpoint = NWEndpoint.service(name: name, type: kMonitorBonjourServiceType,
                                          domain: "local.", interface: nil)
        pendingService = Service(id: "saved:\(name)", name: name, endpoint: endpoint)
        status = "Reconnecting to \(name)…"
        connect(code: savedCode)
    }

    // MARK: - Demo mode (reviewable without the Mac agent)

    func startDemo() {
        intentionalDisconnect = true
        client?.cancel(); client = nil
        consumeTask?.cancel(); reconnectTask?.cancel()
        browser?.cancel()
        isDemo = true
        demoBusy = 30
        processes = Demo.processes()
        cpuHistory = []
        system = Demo.system(busy: demoBusy)
        link = .live
        banner = "Demo mode — data is simulated"
        screen = .dashboard
        demoTimer?.invalidate()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.demoTick() }
        }
    }

    private func demoTick() {
        guard isDemo else { return }
        demoBusy = max(5, min(95, demoBusy + Double.random(in: -8...8)))
        system = Demo.system(busy: demoBusy)
        processes = Demo.jitter(processes)
        cpuHistory.append(demoBusy)
        if cpuHistory.count > cpuHistoryLimit { cpuHistory.removeFirst(cpuHistory.count - cpuHistoryLimit) }
    }

    private func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil
        isDemo = false
    }

    // MARK: - Discovery

    func startDiscovery() {
        screen = .discovery
        browser?.cancel()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: kMonitorBonjourServiceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let e) = state { self.status = "Discovery failed: \(e.localizedDescription)" }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.services = results.map { result in
                    var name = "\(result.endpoint)"
                    if case let .service(svcName, _, _, _) = result.endpoint { name = svcName }
                    return Service(id: "\(result.endpoint)", name: name, endpoint: result.endpoint)
                }
                self.status = self.services.isEmpty ? "Searching for Macs…" : "\(self.services.count) Mac(s) found"
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func choose(_ service: Service) {
        pendingService = service
        banner = nil
        screen = .pairing
    }

    // MARK: - Connect / pair

    func connect(code: String) {
        guard let service = pendingService else { return }
        let normalized = MonitorPairing.normalize(code)
        savedCode = normalized
        UserDefaults.standard.set(normalized, forKey: "lastCode")

        activeService = service
        activeCode = normalized
        intentionalDisconnect = false
        reconnectAttempt = 0
        cpuHistory = []
        link = .connecting
        status = "Connecting to \(service.name)…"
        establish()
    }

    /// Builds a fresh client to the active service and starts streaming. Called
    /// for the initial connect and every reconnect attempt.
    private func establish() {
        guard let service = activeService, let code = activeCode else { return }

        // Allow icon re-requests on the new connection (cached images persist).
        requestedIconPaths.removeAll()
        pendingIconPaths.removeAll()

        client?.onState = nil      // detach the old client's callbacks first
        client?.cancel()
        consumeTask?.cancel()

        let deviceName = UIDevice.current.name
        let client = MonitorClient(endpoint: service.endpoint, code: code)
        self.client = client

        // Callbacks are tagged with `client`; connectionDropped/handle ignore
        // any that don't belong to the current connection, so a dying old
        // connection can't tear down a freshly-established one.
        client.onState = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if case .failed = st { self.connectionDropped(from: client) }
            }
        }

        consumeTask = Task { [weak self] in
            for await msg in client.messages {
                await MainActor.run {
                    guard let self, self.client === client else { return }
                    self.handle(msg)
                }
            }
            await MainActor.run { self?.connectionDropped(from: client) }
        }

        client.start()
        client.send(.hello(clientName: deviceName, deviceID: deviceID,
                           protocolVersion: kMonitorProtocolVersion, pairingCode: code))
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .helloAck(_, _, _, nonce):
            sessionNonce = nonce
            reconnectAttempt = 0
            lastDroppedClient = nil
            link = .live
            screen = .dashboard
            banner = nil
            // Remember this Mac so we can auto-reconnect on the next launch.
            if let name = activeService?.name {
                UserDefaults.standard.set(name, forKey: "lastServiceName")
            }
        case .system(let s):
            system = s
            link = .live
            cpuHistory.append(s.cpu.busyPercent)
            if cpuHistory.count > cpuHistoryLimit { cpuHistory.removeFirst(cpuHistory.count - cpuHistoryLimit) }
        case .snapshot(let p):
            processes = p
        case .killResult(_, let ok, let m):
            banner = ok ? nil : m
        case .controlResult(_, _, let message):
            banner = message.isEmpty ? nil : message
        case .icons(let entries):
            for entry in entries where icons[entry.path] == nil {
                if let image = UIImage(data: entry.png) {
                    icons[entry.path] = image
                    IconCache.save(entry.png, for: entry.path)   // persist for next launch
                }
            }
        case .error(let e):
            banner = e
        case .pairingFailed(let reason):
            fail("Pairing failed: \(reason)")
        default:
            break
        }
    }

    /// Connection lost. If we were paired on the dashboard, keep the stale data
    /// visible and reconnect with capped backoff. If we never paired (bad code),
    /// fail back to discovery.
    ///
    /// `client` is the connection that dropped. We ignore drops from a client
    /// that is no longer current (a superseded connection), and dedupe the two
    /// callbacks a single disconnect fires (onState .failed + stream finish).
    private func connectionDropped(from client: MonitorClient) {
        guard !intentionalDisconnect else { return }
        guard client === self.client else { return }          // superseded connection
        guard client !== lastDroppedClient else { return }    // same drop, already handled
        lastDroppedClient = client

        if screen == .pairing {
            fail("Pairing failed — check the code and try again")
            return
        }
        guard screen == .dashboard else { return }

        link = .reconnecting
        reconnectAttempt += 1
        let delay = min(8.0, pow(2.0, Double(min(reconnectAttempt, 3))))   // 2,4,8,8…
        banner = "Reconnecting to \(activeService?.name ?? "Mac")…"

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                guard !self.intentionalDisconnect, self.link == .reconnecting else { return }
                self.establish()
            }
        }
    }

    private func fail(_ message: String) {
        intentionalDisconnect = true
        banner = message
        link = .disconnected
        client?.cancel(); client = nil
        consumeTask?.cancel(); reconnectTask?.cancel()
        screen = .discovery
        startDiscovery()
    }

    // MARK: - Lifecycle

    /// Called when the app returns to the foreground. iOS suspends sockets in
    /// the background, so kick an immediate reconnect rather than waiting out
    /// the backoff.
    func appBecameActive() {
        guard !intentionalDisconnect, screen == .dashboard, link != .live else { return }
        reconnectTask?.cancel()
        link = .reconnecting
        establish()
    }

    // MARK: - Actions

    func kill(_ process: ProcessSample, signal: MonitorSignal) {
        if isDemo {
            processes.removeAll { $0.pid == process.pid }
            banner = "Demo — “\(process.name)” quit (simulated)"
            return
        }
        client?.send(.kill(pid: process.pid, signal: signal.rawValue,
                           startTime: process.startTime, sessionNonce: sessionNonce))
    }

    func sendControl(_ action: MacControlAction) {
        if isDemo { banner = "Demo — \(action.label) not sent"; return }
        client?.send(.control(action: action, sessionNonce: sessionNonce))
    }

    /// Loads the persisted icon cache from disk into memory once, so icons are
    /// present on launch instead of popping in over the network.
    private func preloadIcons() {
        guard !didPreloadIcons else { return }
        didPreloadIcons = true
        let paths = IconCache.manifestPaths()
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var datas: [String: Data] = [:]
            for path in paths { if let data = IconCache.loadData(for: path) { datas[path] = data } }
            await MainActor.run { [datas] in
                guard let self else { return }
                for (path, data) in datas where self.icons[path] == nil {
                    if let image = UIImage(data: data) { self.icons[path] = image }
                    self.diskCheckedPaths.insert(path)
                }
            }
        }
    }

    /// Called as a row appears. Resolves its icon memory → disk → network, so a
    /// cached icon never triggers a network fetch.
    func iconNeeded(for path: String?) {
        guard !isDemo else { return }   // demo has no agent to fetch icons from
        guard let path, !path.isEmpty, icons[path] == nil, !requestedIconPaths.contains(path) else { return }
        if !diskCheckedPaths.contains(path) {
            diskCheckedPaths.insert(path)
            if let data = IconCache.loadData(for: path), let image = UIImage(data: data) {
                icons[path] = image
                return
            }
        }
        pendingIconPaths.insert(path)
        guard !iconFlushScheduled else { return }
        iconFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.iconFlushScheduled = false
            let batch = Array(self.pendingIconPaths.prefix(100))
            self.pendingIconPaths.subtract(batch)
            guard !batch.isEmpty else { return }
            batch.forEach { self.requestedIconPaths.insert($0) }
            self.client?.send(.requestIcons(paths: batch))
        }
    }

    func disconnect() {
        stopDemo()
        intentionalDisconnect = true
        client?.cancel(); client = nil
        consumeTask?.cancel(); reconnectTask?.cancel()
        activeService = nil; activeCode = nil
        link = .disconnected
        system = nil
        processes = []
        cpuHistory = []
        screen = .discovery
        startDiscovery()
    }
}
