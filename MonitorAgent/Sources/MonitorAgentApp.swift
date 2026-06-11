import SwiftUI
import AppKit
import CoreImage
import ServiceManagement
import AgentCore
import MonitorKit

/// Renders a QR code (crisp, no interpolation) for the pairing payload.
func makeQRImage(_ string: String, scale: CGFloat = 6) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(string.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
    let rep = NSCIImageRep(ciImage: ci)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

@main
struct MonitorAgentApp: App {
    @StateObject private var model = AgentModel()

    var body: some Scene {
        MenuBarExtra("VitaMac Agent", systemImage: "gauge.with.dots.needle.bottom.50percent") {
            MenuContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Owns the network server and a light local sampler for the menu preview.
/// Server callbacks arrive on a background queue and are hopped to the main
/// actor before touching @Published state.
@MainActor
final class AgentModel: ObservableObject {
    @Published var pairingCode: String
    @Published var serverStatus = "Starting…"
    @Published var connectedClients = 0
    @Published var pairedDevices: [PairedDevice] = []
    @Published var connectedDeviceIDs: Set<String> = []
    @Published var helperStatusText = "System-process access: off"
    @Published var helperEnabled = false
    @Published var launchAtLogin = false

    private let server: MonitorServer
    private let helper = PrivilegedHelperClient()
    private var timer: Timer?

    private static let codeKey = "pairingCode"

    init() {
        // Persist the pairing code so the phone doesn't re-pair every launch.
        let code: String
        if let saved = UserDefaults.standard.string(forKey: Self.codeKey), !saved.isEmpty {
            code = saved
        } else {
            code = MonitorPairing.generateCode()
            UserDefaults.standard.set(code, forKey: Self.codeKey)
        }
        pairingCode = code
        server = MonitorServer(pairingCode: code)

        configureServer()
        startStatusTimer()
        refreshHelperStatus()
        pairedDevices = server.pairedDevices()
        server.start(advertiseBonjour: true)

        // Launch at login: enable by default on first run; the user can toggle it.
        refreshLaunchAtLogin()
        let loginSetupKey = "didSetupLoginItem"
        if !UserDefaults.standard.bool(forKey: loginSetupKey) {
            UserDefaults.standard.set(true, forKey: loginSetupKey)
            setLaunchAtLogin(true)
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Leave the toggle reflecting the real status on failure.
        }
        refreshLaunchAtLogin()
    }

    func refreshHelperStatus() {
        switch helper.status {
        case .enabled:
            helperEnabled = true
            helperStatusText = "System-process access: on"
        case .requiresApproval:
            helperEnabled = false
            helperStatusText = "Approve “VitaMac Agent” in System Settings → Login Items"
        case .notRegistered:
            helperEnabled = false
            helperStatusText = "System-process access: off"
        case .notFound:
            helperEnabled = false
            helperStatusText = "Helper not found (rebuild/reinstall the app)"
        @unknown default:
            helperEnabled = false
            helperStatusText = "System-process access: unknown"
        }
    }

    /// Registers the root helper so root/system processes become killable.
    /// macOS prompts the user to approve it once in Login Items.
    func enableSystemProcessAccess() {
        do {
            try helper.register()
        } catch {
            helperStatusText = "Enable failed: \(error.localizedDescription)"
        }
        refreshHelperStatus()
        if helper.status == .requiresApproval {
            helper.openSystemSettingsLoginItems()
        }
    }

    private func configureServer() {
        server.onState = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .stopped: self.serverStatus = "Stopped"
                case .starting: self.serverStatus = "Starting…"
                case .ready(let port): self.serverStatus = "Listening · port \(port)"
                case .failed(let msg): self.serverStatus = "Failed: \(msg)"
                }
            }
        }
        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in self?.connectedClients = count }
        }
        server.onDevicesChanged = { [weak self] devices, connected in
            Task { @MainActor in
                self?.pairedDevices = devices
                self?.connectedDeviceIDs = connected
            }
        }
    }

    private func startStatusTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshHelperStatus()
                self?.refreshLaunchAtLogin()
            }
        }
    }

    /// Revokes a paired device: it's dropped + disconnected. (It can re-pair if
    /// it still has the code — use "New Code" to fully lock devices out.)
    func revoke(_ device: PairedDevice) {
        server.revoke(deviceID: device.id)
        pairedDevices = server.pairedDevices()
    }

    func regenerateCode() {
        let code = MonitorPairing.generateCode()
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        pairingCode = code
        server.stop()
        server.setPairingCode(code)
        server.start(advertiseBonjour: true)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AgentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                Text("VitaMac Agent").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                    Text(model.pairingCode)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .textSelection(.enabled)

                    if let qr = makeQRImage(MonitorPairing.makePairingURLString(
                        code: model.pairingCode, host: ProcessInfo.processInfo.hostName)) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 128, height: 128)
                            .frame(maxWidth: .infinity)
                        Text("Scan with VitaMac on your iPhone to pair")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }

                    Text(model.serverStatus).font(.caption2).foregroundStyle(.secondary)
                    Text("\(model.connectedClients) device(s) connected")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Image(systemName: model.helperEnabled ? "lock.open" : "lock")
                    .foregroundStyle(model.helperEnabled ? .green : .secondary)
                Text(model.helperStatusText).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if !model.helperEnabled {
                    Button("Enable") { model.enableSystemProcessAccess() }
                        .controlSize(.small)
                }
            }

            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)

            Divider()
            Text("Paired devices").font(.caption).foregroundStyle(.secondary)
            if model.pairedDevices.isEmpty {
                Text("None yet — scan the QR from VitaMac on your iPhone.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(model.pairedDevices) { device in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.connectedDeviceIDs.contains(device.id) ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.caption).lineLimit(1)
                            Text(model.connectedDeviceIDs.contains(device.id)
                                 ? "Connected"
                                 : "Last seen \(device.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { model.revoke(device) }
                            .controlSize(.small)
                    }
                }
            }

            Divider()
            HStack {
                Button("New Code") { model.regenerateCode() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}
