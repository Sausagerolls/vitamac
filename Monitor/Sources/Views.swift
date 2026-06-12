import SwiftUI
import Charts
import MonitorKit

// MARK: - Root

struct ContentView: View {
    @StateObject private var vm = MonitorViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch vm.screen {
            case .discovery: DiscoveryView(vm: vm)
            case .pairing: PairingView(vm: vm)
            case .dashboard: MainView(vm: vm)
            }
        }
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
        .onAppear {
            // `-demoScreenshots` boots straight into Demo Mode for App Store capture.
            if ProcessInfo.processInfo.arguments.contains("-demoScreenshots") {
                vm.startDemo()
            } else {
                vm.startup()   // discovery + auto-reconnect to the last paired Mac
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active { vm.appBecameActive() }
        }
    }
}

// MARK: - Discovery

struct DiscoveryView: View {
    @ObservedObject var vm: MonitorViewModel

    var body: some View {
        NavigationStack {
            VStack {
                if let banner = vm.banner {
                    Text(banner)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                if vm.services.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Looking for Macs").font(.headline)
                        Text("Open VitaMac Agent on a Mac on the same Wi-Fi network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    List(vm.services) { service in
                        Button {
                            vm.choose(service)
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer")
                                Text(service.name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Button {
                    vm.startDemo()
                } label: {
                    Label("Try a Demo", systemImage: "play.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .padding(.bottom, 30)
            }
            .navigationTitle("VitaMac")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { ProgressView() } }
            .overlay(alignment: .bottom) {
                Text(vm.status).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Pairing

struct PairingView: View {
    @ObservedObject var vm: MonitorViewModel
    @State private var code: String = ""
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(vm.pendingService?.name ?? "Mac")
                        .font(.headline)
                } header: {
                    Text("Connecting to")
                }
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Pairing code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                } header: {
                    Text("…or enter the code")
                } footer: {
                    Text("The QR code and the code are shown in the VitaMac Agent menu-bar window on the Mac.")
                }
                Button("Connect") {
                    vm.connect(code: code)
                }
                .disabled(MonitorPairing.normalize(code).count < 4)
            }
            .navigationTitle("Pair")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { vm.screen = .discovery }
                }
            }
            .onAppear { if code.isEmpty { code = vm.savedCode } }
            .sheet(isPresented: $showScanner) {
                NavigationStack {
                    QRScannerView { scanned in
                        MainActor.assumeIsolated {
                            showScanner = false
                            if let c = MonitorPairing.extractCode(fromScanned: scanned) {
                                code = c
                                vm.connect(code: c)
                            }
                        }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Scan QR code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showScanner = false }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Main (adaptive: sidebar on iPad, tabs on iPhone)

enum MonitorTab: String, CaseIterable, Identifiable {
    case dashboard, processes, controls
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .processes: return "Processes"
        case .controls: return "Mac Controls"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .processes: return "list.bullet"
        case .controls: return "switch.2"
        }
    }
    /// Initial tab, overridable via `-demoTab <raw>` for App Store capture.
    static var initialSelection: MonitorTab {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-demoTab"), i + 1 < args.count,
           let tab = MonitorTab(rawValue: args[i + 1]) { return tab }
        return .dashboard
    }
}

struct MainView: View {
    @ObservedObject var vm: MonitorViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: MonitorTab = MonitorTab.initialSelection

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: sidebar + detail. Explicit Button rows drive the
                // selection (reliable across OS versions).
                NavigationSplitView {
                    List {
                        ForEach(MonitorTab.allCases) { tab in
                            Button { selection = tab } label: {
                                Label(tab.label, systemImage: tab.icon)
                                    .foregroundStyle(selection == tab ? Color.accentColor : Color.primary)
                            }
                            .listRowBackground(selection == tab ? Color.accentColor.opacity(0.12) : Color.clear)
                        }
                    }
                    .navigationTitle(vm.system?.hostName ?? "Mac")
                    .listStyle(.sidebar)
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            Button("Disconnect") { vm.disconnect() }
                        }
                    }
                } detail: {
                    NavigationStack { section(selection) }
                }
            } else {
                // iPhone: tab bar
                TabView(selection: $selection) {
                    ForEach(MonitorTab.allCases) { tab in
                        NavigationStack { section(tab) }
                            .tabItem { Label(tab.label, systemImage: tab.icon) }
                            .tag(tab)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let banner = vm.banner,
               !ProcessInfo.processInfo.arguments.contains("-demoScreenshots") {
                Text(banner).font(.caption).padding(8)
                    .background(.red.opacity(0.15), in: Capsule())
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func section(_ tab: MonitorTab) -> some View {
        switch tab {
        case .dashboard: DashboardSection(vm: vm)
        case .processes: ProcessesSection(vm: vm)
        case .controls: ControlsSection(vm: vm)
        }
    }
}

struct ConnectionDot: View {
    @ObservedObject var vm: MonitorViewModel
    var body: some View {
        switch vm.link {
        case .connecting, .reconnecting: ProgressView().controlSize(.small)
        case .live: Image(systemName: "circle.fill").font(.system(size: 10)).foregroundStyle(Brand.green)
        case .disconnected: EmptyView()
        }
    }
}

// MARK: - Dashboard section

struct DashboardSection: View {
    @ObservedObject var vm: MonitorViewModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            if let sys = vm.system {
                LazyVGrid(columns: columns, spacing: 12) {
                    StatTile(title: "CPU", value: String(format: "%.0f%%", sys.cpu.busyPercent),
                             tint: Brand.blue, subtitle: "\(sys.cpu.perCore.count) cores")
                    StatTile(title: "Memory", value: String(format: "%.0f%%", sys.memory.pressurePercent),
                             tint: Brand.green, subtitle: "\(sys.memory.usedBytes.shortBytes) / \(sys.memory.totalBytes.shortBytes)")
                    if let gpu = sys.gpu {
                        StatTile(title: "GPU", value: String(format: "%.0f%%", gpu.utilizationPercent),
                                 tint: Brand.cyan, subtitle: gpu.name)
                    }
                    StatTile(title: "Network ↓", value: rate(sys.network.bytesInPerSec), tint: Brand.teal)
                    StatTile(title: "Network ↑", value: rate(sys.network.bytesOutPerSec), tint: Brand.green)
                    StatTile(title: "Processes", value: "\(sys.processCount)", tint: Brand.slate,
                             subtitle: "load \(sys.loadAverage.map { String(format: "%.1f", $0) }.joined(separator: " "))")
                }
                .padding()

                if vm.cpuHistory.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("CPU history").font(.caption).foregroundStyle(.secondary)
                        Chart(Array(vm.cpuHistory.enumerated()), id: \.offset) { index, value in
                            LineMark(x: .value("t", index), y: .value("CPU", value))
                                .interpolationMethod(.catmullRom).foregroundStyle(Brand.cyan)
                            AreaMark(x: .value("t", index), y: .value("CPU", value))
                                .interpolationMethod(.catmullRom)
                                .foregroundStyle(LinearGradient(colors: [Brand.cyan.opacity(0.30), Brand.cyan.opacity(0.02)],
                                                                startPoint: .top, endPoint: .bottom))
                        }
                        .chartYScale(domain: 0...100)
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 120)
                    }
                    .padding(.horizontal)
                }
            } else {
                ProgressView("Connecting…").padding(.top, 60)
            }
        }
        .background(Brand.navy.ignoresSafeArea())
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionDot(vm: vm) } }
    }
}

// MARK: - Processes section

struct ProcessesSection: View {
    @ObservedObject var vm: MonitorViewModel
    @State private var actionTarget: ProcessSample?

    var body: some View {
        List {
            ForEach(vm.sortedProcesses) { process in
                ProcessRow(process: process,
                           icon: vm.icons[process.executablePath ?? ""],
                           pinned: vm.isPinned(process))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Brand.separator)
                    .contentShape(Rectangle())
                    .onTapGesture { actionTarget = process }
                    .onAppear { vm.iconNeeded(for: process.executablePath) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Brand.navy.ignoresSafeArea())
        .searchable(text: $vm.searchText, prompt: "Filter processes")
        .navigationTitle("Processes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Picker("Sort", selection: $vm.sortKey) {
                    ForEach(MonitorViewModel.SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ToolbarItem(placement: .topBarTrailing) { ConnectionDot(vm: vm) }
        }
        .confirmationDialog(
            actionTarget.map { "\($0.name) · pid \($0.pid)" } ?? "",
            isPresented: Binding(get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = actionTarget {
                Button(vm.isPinned(target) ? "Unpin from top" : "Pin to top") {
                    vm.togglePin(target); actionTarget = nil
                }
                if target.canKill {
                    Button("Quit") { vm.kill(target, signal: .term); actionTarget = nil }
                    Button("Force Kill", role: .destructive) { vm.kill(target, signal: .kill); actionTarget = nil }
                }
                Button("Cancel", role: .cancel) { actionTarget = nil }
            }
        }
    }
}

// MARK: - Mac controls section

struct ControlsSection: View {
    @ObservedObject var vm: MonitorViewModel
    @State private var confirmAction: MacControlAction?

    var body: some View {
        List {
            Section {
                ForEach(MacControlAction.allCases) { action in
                    Button {
                        if action.isDestructive { confirmAction = action } else { vm.sendControl(action) }
                    } label: {
                        Label(action.label, systemImage: action.systemImage)
                            .foregroundStyle(action.isDestructive ? Color.red : Color.primary)
                    }
                    .listRowBackground(Brand.card)
                }
            } header: {
                Text("Power & Display")
            } footer: {
                Text("Restart and Shut Down ask for confirmation. The first use may prompt the Mac to allow controlling System Events.")
            }
            Section {
                Button("Disconnect", role: .cancel) { vm.disconnect() }
                    .listRowBackground(Brand.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.navy.ignoresSafeArea())
        .navigationTitle("Mac Controls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionDot(vm: vm) } }
        .confirmationDialog(
            confirmAction?.label ?? "",
            isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = confirmAction {
                Button("\(action.label) Mac", role: .destructive) { vm.sendControl(action); confirmAction = nil }
                Button("Cancel", role: .cancel) { confirmAction = nil }
            }
        }
    }
}

/// Shared byte-rate formatter.
private func rate(_ bytesPerSec: Double) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var v = bytesPerSec, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@/s" : "%.1f %@/s", v, units[i])
}

struct StatTile: View {
    let title: String
    let value: String
    let tint: Color
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }
}

struct ProcessRow: View {
    let process: ProcessSample
    var icon: UIImage?
    var pinned: Bool = false

    var body: some View {
        HStack {
            Group {
                if let icon {
                    Image(uiImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).lineLimit(1)
                Text(ownerLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.statsAvailable ? String(format: "%.1f%%", process.cpuPercent) : "—")
                    .monospacedDigit()
                Text(process.statsAvailable ? process.memoryFootprint.shortBytes : "restricted")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
            }
            if process.canKill {
                Image(systemName: "xmark.circle").foregroundStyle(.red.opacity(0.6))
            } else {
                Image(systemName: "lock").foregroundStyle(.tertiary)
            }
        }
    }

    private var ownerLabel: String {
        process.isCurrentUser ? "pid \(process.pid)" : "pid \(process.pid) · uid \(process.uid)"
    }
}

private extension UInt64 {
    var shortBytes: String {
        let units = ["B", "KB", "MB", "GB"]
        var v = Double(self), i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.0f %@", v, units[i])
    }
}
