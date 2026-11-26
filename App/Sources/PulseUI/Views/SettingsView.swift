import AppKit
import ProductIdentity
import SMCtlProtocol
import SwiftUI

/// Settings panes, hosted by `SettingsWindowController` in a toolbar-style tab
/// view, like the Settings windows of Apple's apps.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, service, about

    public var title: String {
        switch self {
        case .general: return "General"
        case .service: return "Service"
        case .about: return "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .service: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    /// Fixed sizes: a grouped Form has no reliable intrinsic height, and an
    /// unsized pane was laid out empty until the user switched tabs.
    public var size: CGSize {
        switch self {
        case .general: return CGSize(width: 500, height: 720)
        case .service: return CGSize(width: 500, height: 420)
        case .about: return CGSize(width: 500, height: 300)
        }
    }
}

public struct SettingsView: View {
    let store: PulseStore
    let pane: SettingsPane

    public init(store: PulseStore, pane: SettingsPane) {
        self.store = store
        self.pane = pane
    }

    public var body: some View {
        Group {
            switch pane {
            case .general: GeneralSettings(store: store)
            case .service: ServiceSettings(store: store)
            case .about: AboutView()
            }
        }
        .frame(width: pane.size.width, height: pane.size.height)
    }
}

struct GeneralSettings: View {
    let store: PulseStore
    @AppStorage(SettingsKey.menuBarIcon) private var icon: MenuBarIcon = .pulse
    @AppStorage(SettingsKey.menuBarHeartbeat) private var heartbeat: HeartbeatMode = .whenWarm
    @AppStorage(SettingsKey.menuBarMonochrome) private var monochrome = false
    @AppStorage(SettingsKey.menuBarShowsReadings) private var showsReadings = true
    @AppStorage(SettingsKey.menuBarLayout) private var layout: MenuBarLayout = .stacked
    @AppStorage(SettingsKey.menuBarItems) private var itemsText = MenuBarConfiguration.encodeItems(MenuBarConfiguration.defaultItems)
    @AppStorage(SettingsKey.temperatureMetric) private var metric: TemperatureMetric = .cpuAverage
    @AppStorage(SettingsKey.fanSpeedUnit) private var unit: FanSpeedUnit = .rpm
    @State private var launchAtLogin = ServiceInstaller.launchesAtLogin
    @State private var loginError: String?

    private var configuration: MenuBarConfiguration {
        MenuBarConfiguration(icon: icon, heartbeat: heartbeat, monochrome: monochrome, showsReadings: showsReadings, layout: layout,
                             items: MenuBarConfiguration.decodeItems(itemsText), metric: metric, unit: unit)
    }

    private var heartbeatHelp: String {
        var text = icon == .pulse && !monochrome ? "The dot turns from green to yellow, orange and red as the CPU warms up. " : ""
        switch heartbeat {
        case .off: text += "The icon stays still."
        case .whenWarm: text += "It starts beating above \(Int(HeartbeatMode.warmThresholdCelsius)) °C, faster as the Mac heats up (40 to 120 beats per minute). Still at rest, so it costs nothing."
        case .always: text += "It beats all the time, faster as the Mac heats up (40 to 120 beats per minute). Each beat redraws the menu bar, which costs about 2–3% CPU."
        }
        return text
    }

    private func binding(for item: MenuBarItem) -> Binding<Bool> {
        Binding {
            MenuBarConfiguration.decodeItems(itemsText).contains(item)
        } set: { enabled in
            var items = MenuBarConfiguration.decodeItems(itemsText)
            if enabled { items.append(item) } else { items.removeAll { $0 == item } }
            itemsText = MenuBarConfiguration.encodeItems(items)
        }
    }

    var body: some View {
        Form {
            Section {
                MenuBarPreview(state: store.menuBar, configuration: configuration)
            }
            Section("Icon") {
                Picker("Icon", selection: $icon) {
                    ForEach(MenuBarIcon.allCases) { Text($0.title).tag($0) }
                }
                if icon == .pulse {
                    Toggle("Monochrome", isOn: $monochrome)
                }
                if icon.canAnimate {
                    Picker("Heartbeat", selection: $heartbeat) {
                        ForEach(HeartbeatMode.allCases) { Text($0.title).tag($0) }
                    }
                    Text(heartbeatHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Readings") {
                Toggle("Show readings", isOn: $showsReadings)
                if showsReadings {
                    Picker("Layout", selection: $layout) {
                        ForEach(MenuBarLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(MenuBarItem.allCases) { item in
                        Toggle(item.title, isOn: binding(for: item))
                    }
                    Picker("Temperature", selection: $metric) {
                        ForEach(TemperatureMetric.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Fan speed", selection: $unit) {
                        ForEach(FanSpeedUnit.allCases) { Text($0.title).tag($0) }
                    }
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

/// The menu bar item as it will look, beating like the real one, on a menu
/// bar-like strip.
public struct MenuBarPreview: View {
    let state: MenuBarState
    let configuration: MenuBarConfiguration
    let animated: Bool

    public init(state: MenuBarState, configuration: MenuBarConfiguration, animated: Bool = true) {
        self.state = state
        self.configuration = configuration
        self.animated = animated
    }

    public var body: some View {
        let entries = state.entries(configuration)
        let base = MenuBarDrawing(
            icon: configuration.effectiveIcon(hasReadings: !entries.isEmpty),
            layout: configuration.layout,
            entries: entries,
            heatCelsius: state.heatCelsius,
            latched: state.latched,
            fanSymbol: state.symbol,
            monochrome: configuration.monochrome
        )
        // The preview beats whenever the mode is not off, so the effect is visible.
        let beats = animated && configuration.heartbeat != .off && base.icon.canAnimate
        HStack {
            Spacer()
            TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !beats)) { context in
                Image(nsImage: MenuBarRenderer.image(Self.frame(base, at: context.date, beating: beats)))
                    .renderingMode(base.isTemplate ? .template : .original)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Spacer()
        }
        .accessibilityLabel("Menu bar preview")
    }

    /// The status item's beat envelope, evaluated at `date`.
    static func frame(_ base: MenuBarDrawing, at date: Date, beating: Bool) -> MenuBarDrawing {
        guard beating else { return base }
        var frame = base
        let period = 60 / MenuBarState.beatsPerMinute(celsius: base.heatCelsius)
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        frame.beat = phase < 0.16 ? 1 : 0
        return frame
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
