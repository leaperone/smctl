import AppKit
import ProductIdentity
import SMCtlProtocol
import SwiftUI

/// Settings panes, hosted by `SettingsWindowController` in a toolbar-style tab
/// view, like the Settings windows of Apple's apps.
public enum SettingsPane: String, CaseIterable, Sendable {
    case general, curves, automation, service, about

    public var title: String {
        switch self {
        case .general: return "General"
        case .curves: return "Curves"
        case .automation: return "Automation"
        case .service: return "Service"
        case .about: return "About"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .curves: return "chart.xyaxis.line"
        case .automation: return "wand.and.stars"
        case .service: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    /// One fixed size for every pane, so switching tabs doesn't resize the
    /// window (it jumped between very different sizes). Fixed because a
    /// grouped Form has no reliable intrinsic height, and an unsized pane was
    /// laid out empty until the user switched tabs.
    public var size: CGSize { CGSize(width: 780, height: 760) }
}

public struct SettingsView: View {
    let store: PulseStore
    let pane: SettingsPane
    let navigation: SettingsNavigation
    let automation: AutomationController?

    public init(store: PulseStore, pane: SettingsPane, navigation: SettingsNavigation = SettingsNavigation(), automation: AutomationController? = nil) {
        self.store = store
        self.pane = pane
        self.navigation = navigation
        self.automation = automation
    }

    public var body: some View {
        Group {
            switch pane {
            case .general: GeneralSettings(store: store)
            case .curves: CurvesSettings(store: store, navigation: navigation)
            case .automation:
                if let automation {
                    AutomationSettings(store: store, automation: automation)
                } else {
                    ContentUnavailableView("Automation Unavailable", systemImage: "wand.and.stars")
                }
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
    @AppStorage(SettingsKey.safetyNotifications) private var safetyNotifications = true
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
            SamplingSettings(store: store)
            Section {
                Toggle(isOn: $safetyNotifications) {
                    Text("Notify when the temperature limit is reached")
                    Text("If a sensor stays above the safety limit, Pulse hands the fans back to macOS and tells you; another notification follows once it cools down.")
                }
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
        // Two frames per beat, drawn once: the timeline only fires when the
        // frame changes (a 12 fps timeline measured ~11% CPU).
        let rest = MenuBarRenderer.image(base)
        let peak = beats ? MenuBarRenderer.image(Self.frame(base, beat: 1)) : rest
        HStack {
            Spacer()
            TimelineView(BeatSchedule(period: Self.period(base), paused: !beats)) { context in
                Image(nsImage: beats && Self.isPeak(at: context.date, period: Self.period(base)) ? peak : rest)
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

    /// Length of the peak frame, as in `StatusItemController.beatFrames`.
    static let peakDuration: TimeInterval = 0.16

    static func period(_ base: MenuBarDrawing) -> TimeInterval {
        60 / MenuBarState.beatsPerMinute(celsius: base.heatCelsius)
    }

    static func frame(_ base: MenuBarDrawing, beat: Double) -> MenuBarDrawing {
        var frame = base
        frame.beat = beat
        return frame
    }

    /// Whether `date` falls in the peak frame of a beat.
    static func isPeak(at date: Date, period: TimeInterval) -> Bool {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) < peakDuration - 0.001
    }

    /// Fires at the start and end of each beat's peak, nothing in between.
    struct BeatSchedule: TimelineSchedule {
        let period: TimeInterval
        let paused: Bool

        func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
            guard !paused, period > MenuBarPreview.peakDuration else {
                var once = Optional(startDate)
                return AnyIterator { defer { once = nil }; return once }
            }
            let start = startDate.timeIntervalSinceReferenceDate
            var beat = (start / period).rounded(.down)
            var peakEnded = start - beat * period >= MenuBarPreview.peakDuration
            var first = Optional(startDate)
            return AnyIterator {
                if let date = first { first = nil; return date }
                if peakEnded {
                    beat += 1
                    peakEnded = false
                    return Date(timeIntervalSinceReferenceDate: beat * period)
                }
                peakEnded = true
                return Date(timeIntervalSinceReferenceDate: beat * period + MenuBarPreview.peakDuration)
            }
        }
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

    /// Runs an installer action off the main thread (the administrator prompt
    /// can stay open for a while), then brings the settings back to the front:
    /// when the prompt closes, macOS activates the previous app and Pulse,
    /// which has no Dock icon, would be left hidden behind it.
    private func run(_ action: @escaping @Sendable () throws -> Void) {
        working = true
        message = nil
        Task { @MainActor in
            // The password prompt hands activation to the previous app when it
            // closes; the guard brings the settings window straight back.
            let guardian = ActivationGuard {
                NSApp.windows.first { $0.identifier == SettingsWindowController.windowIdentifier }
            }
            do {
                try await Task.detached { try action() }.value
            } catch {
                message = error.localizedDescription
            }
            guardian.finish()
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
