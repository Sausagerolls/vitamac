import Foundation
import ServiceManagement
import MonitorKit

/// Agent-side client for the privileged helper: registers/queries the
/// SMAppService daemon and talks to it over a code-signing-pinned XPC link.
public final class PrivilegedHelperClient: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    private var service: SMAppService {
        SMAppService.daemon(plistName: MonitorHelperInfo.daemonPlistName)
    }

    public var status: SMAppService.Status { service.status }
    public var isEnabled: Bool { service.status == .enabled }

    /// Registers the daemon. The user must then approve it in System Settings →
    /// General → Login Items (status becomes `.enabled`).
    public func register() throws { try service.register() }
    public func unregister() async throws { try await service.unregister() }

    public func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    private func makeConnection() -> NSXPCConnection {
        lock.lock(); defer { lock.unlock() }
        if let existing = connection { return existing }
        let c = NSXPCConnection(machServiceName: MonitorHelperInfo.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: MonitorHelperProtocol.self)
        c.setCodeSigningRequirement(MonitorHelperInfo.codeSigningRequirement)
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.connection = nil; self.lock.unlock()
        }
        c.resume()
        connection = c
        return c
    }

    /// One-shot continuation guard usable from XPC reply/error blocks (which
    /// run on arbitrary threads).
    private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let cont: CheckedContinuation<T, Never>
        init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
        func resume(_ value: T) {
            lock.lock(); defer { lock.unlock() }
            if !done { done = true; cont.resume(returning: value) }
        }
    }

    public func ping() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(cont)
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { _ in once.resume(nil) }
            guard let helper = proxy as? MonitorHelperProtocol else { once.resume(nil); return }
            helper.ping { once.resume($0) }
        }
    }

    public func kill(pid: pid_t, signal: MonitorSignal) async -> (Bool, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
            let once = ResumeOnce(cont)
            let proxy = makeConnection().remoteObjectProxyWithErrorHandler { error in
                once.resume((false, "helper unavailable: \(error.localizedDescription)"))
            }
            guard let helper = proxy as? MonitorHelperProtocol else {
                once.resume((false, "helper unavailable"))
                return
            }
            helper.kill(pid: Int32(pid), signal: signal.rawValue) { ok, msg in once.resume((ok, msg)) }
        }
    }
}
