import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Automation: rules that switch the fan profile on their own.
struct AutomationSettings: View {
    let store: PulseStore
    @Bindable var automation: AutomationController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $automation.enabled) {
                    Text("Switch profiles automatically")
                    Text("Pulse changes the fan profile when a rule below applies, and goes back to the profile you chose once it no longer does. Picking a profile yourself always wins until the rule's condition goes away. Rules run while Pulse is open.")
                }
                if automation.enabled {
                    statusLine
                }
            }
            Section {
                if automation.rules.isEmpty {
                    Text("No rules yet. Add one to switch to Performance while a game is open, for example.")
                        .foregroundStyle(.secondary)
                }
                ForEach(automation.rules) { rule in
                    RuleRow(rule: rule, automation: automation, choices: store.profileChoices.filter { $0.name != "manual" })
                }
            } header: {
                Text("Rules")
            } footer: {
                HStack {
                    Menu("Add Rule") {
                        Button("When an App or Game Is Open…") { chooseApps() }
                        Button("In Low Power Mode") { add(.lowPowerMode, profile: "silent") }
                        if automation.hasBattery {
                            Button("On Battery") { add(.onBattery, profile: "silent") }
                            Button("On Power Adapter") { add(.onPowerAdapter, profile: "balanced") }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    if automation.rules.count > 1 {
                        Text("The first rule that applies wins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!automation.enabled)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLine: some View {
        if automation.suspendedForSafety {
            Label("Paused after the temperature limit was reached. Choose a profile to resume.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        } else if let rule = automation.activeRule {
            Label("Now: \(store.title(forProfile: rule.profile)), because \(AutomationController.describe(rule.condition).lowercasedFirst).",
                  systemImage: "bolt.fill")
                .font(.callout)
        } else if !automation.rules.isEmpty {
            Label("No rule applies right now: \(store.title(forProfile: store.activeProfile)) stays.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func add(_ condition: AutomationCondition, profile: String) {
        automation.add(AutomationRule(condition: condition, profile: profile))
    }

    private func chooseApps() {
        let panel = NSOpenPanel()
        panel.message = "Choose the games or apps that should switch the fan profile while they are open."
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.flatMap(Self.bundleIdentifiers)
        guard !ids.isEmpty else { return }
        add(.appsRunning(Array(NSOrderedSet(array: ids)) as? [String] ?? ids), profile: "performance")
    }

    /// The app's identifier, plus those of apps nested in it: a launcher such
    /// as `Game Launcher.app/Contents/Game.app` runs the inner one.
    static func bundleIdentifiers(of url: URL) -> [String] {
        var ids = [Bundle(url: url)?.bundleIdentifier].compactMap { $0 }
        let contents = url.appendingPathComponent("Contents")
        let nested = (try? FileManager.default.contentsOfDirectory(at: contents, includingPropertiesForKeys: nil)) ?? []
        ids += nested.filter { $0.pathExtension == "app" }.compactMap { Bundle(url: $0)?.bundleIdentifier }
        return ids
    }
}

private struct RuleRow: View {
    let rule: AutomationRule
    let automation: AutomationController
    let choices: [ProfileChoice]

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("When \(AutomationController.describe(rule.condition).lowercasedFirst)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if automation.activeRule?.id == rule.id {
                    Text("Applies now").font(.caption).foregroundStyle(.green)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text("use").foregroundStyle(.secondary)
            Picker("Use", selection: Binding(get: { rule.profile }, set: { profile in
                var changed = rule
                changed.profile = profile
                automation.update(changed)
            })) {
                ForEach(choices) { Text($0.title).tag($0.name) }
                if !choices.contains(where: { $0.name == rule.profile }) {
                    Text(rule.profile.capitalized).tag(rule.profile)
                }
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { enabled in
                var changed = rule
                changed.enabled = enabled
                automation.update(changed)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            Menu {
                Button("Move Up") { automation.move(rule.id, by: -1) }
                    .disabled(automation.rules.first?.id == rule.id)
                Button("Move Down") { automation.move(rule.id, by: 1) }
                    .disabled(automation.rules.last?.id == rule.id)
                Divider()
                Button("Delete Rule", role: .destructive) { automation.remove(rule.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch rule.condition {
        case .appsRunning(let ids):
            if let id = ids.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "gamecontroller").foregroundStyle(.secondary)
            }
        case .lowPowerMode:
            Image(systemName: "leaf").foregroundStyle(.green)
        case .onBattery:
            Image(systemName: "battery.75percent").foregroundStyle(.secondary)
        case .onPowerAdapter:
            Image(systemName: "powerplug").foregroundStyle(.secondary)
        }
    }
}

extension String {
    /// "Low Power Mode is on" stays; "On battery" → "on battery".
    var lowercasedFirst: String {
        guard let first, first.isUppercase, !hasPrefix("Low Power") else { return self }
        // App names keep their capital ("War Thunder is open").
        if contains(" is open") { return self }
        return first.lowercased() + dropFirst()
    }
}
