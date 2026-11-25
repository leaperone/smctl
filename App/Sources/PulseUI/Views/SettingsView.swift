import AppKit
import ProductIdentity
import SMCtlProtocol
import SwiftUI

public struct SettingsView: View {
    let store: PulseStore

    public init(store: PulseStore) {
        self.store = store
    }

    public var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ServiceSettings(store: store)
                .tabItem { Label("Service", systemImage: "lock.shield") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460)
        .scenePadding()
    }
}

struct GeneralSettings: View {
    @AppStorage(SettingsKey.menuBarStyle) private var style: MenuBarStyle = .temperatureAndFan
    @AppStorage(SettingsKey.temperatureMetric) private var metric: TemperatureMetric = .cpuAverage
    @AppStorage(SettingsKey.fanSpeedUnit) private var unit: FanSpeedUnit = .rpm
    @State private var launchAtLogin = ServiceInstaller.launchesAtLogin
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Temperature", selection: $metric) {
                    ForEach(TemperatureMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Fan speed", selection: $unit) {
                    ForEach(FanSpeedUnit.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Open Pulse at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try ServiceInstaller.setLaunchesAtLogin(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = ServiceInstaller.launchesAtLogin
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ServiceSettings: View {
    let store: PulseStore
    @State private var working = false
    @State private var message: String?
    @State private var cliLinked = ServiceInstaller.cliLinkInstalled

    var body: some View {
        Form {
            Section("Fan control service") {
                LabeledContent("Status") {
                    switch store.daemonState {
                    case .connected(let version):
                        Label("Running (\(ProductIdentity.daemonName) \(version))", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .unavailable:
                        Label("Not running", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
                    case .connecting:
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                Text("A small privileged service applies fan profiles, even while the app is closed. It hands fans back to macOS if anything goes wrong.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(store.daemonState.isConnected ? "Reinstall…" : "Install…") {
                        run { try ServiceInstaller.installDaemon() }
                    }
                    if store.daemonState.isConnected {
                        Button("Uninstall…", role: .destructive) {
                            run { try ServiceInstaller.uninstallDaemon() }
                        }
                    }
                    if working { ProgressView().controlSize(.small) }
                }
                .disabled(working || !ServiceInstaller.helpersAvailable)
            }
            Section("Command line") {
                LabeledContent("\(ProductIdentity.cliName) command") {
                    if cliLinked {
                        Label(ServiceInstaller.cliLinkPath, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install in \(ServiceInstaller.cliLinkPath)…") {
                            run { try ServiceInstaller.installCLILink() }
                        }
                        .disabled(working || !ServiceInstaller.helpersAvailable)
                    }
                }
                Text("Check temperatures and switch profiles from Terminal or over SSH: \(ProductIdentity.cliName) status, \(ProductIdentity.cliName) fan profile balanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !store.conflicts.isEmpty {
                Section("Other fan controllers") {
                    ForEach(store.conflicts, id: \.product) { conflict in
                        LabeledContent(conflict.product) {
                            Text(conflict.running ? "Running" : "Installed").foregroundStyle(conflict.running ? .orange : .secondary)
                        }
                    }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ action: @escaping () throws -> Void) {
        working = true
        message = nil
        Task { @MainActor in
            do {
                try action()
            } catch {
                message = error.localizedDescription
            }
            cliLinked = ServiceInstaller.cliLinkInstalled
            await store.refresh(forceLists: true)
            working = false
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Pulse").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Temperatures and fan control for Apple silicon Macs.")
                .font(.callout)
            HStack(spacing: 4) {
                Text("Built on")
                Link("smctl", destination: URL(string: "https://github.com/leaperone/smctl")!)
                Text("· MIT License")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Link("github.com/fstormacq/pulse", destination: URL(string: "https://github.com/fstormacq/pulse")!)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
