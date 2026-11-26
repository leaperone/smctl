import PolicyEngine
import ProductIdentity
import SMCtlProtocol
import SwiftUI

/// The Curves pane: built-in presets and user curves on the left, the selected
/// curve on the right.
struct CurvesSettings: View {
    let store: PulseStore
    @Bindable var navigation: SettingsNavigation
    @State private var renaming: FanCurveSpec?
    @State private var renameText = ""
    @State private var deleting: String?

    private var entries: [FanCurveEntryDTO] { store.curveEntries }
    private var presets: [FanCurveEntryDTO] { entries.filter(\.builtin) }
    private var userCurves: [FanCurveEntryDTO] { entries.filter { !$0.builtin } }
    private var invalidNames: [String] { store.invalidCurves.keys.sorted() }

    private var selectedEntry: FanCurveEntryDTO? {
        entries.first { $0.spec.name == navigation.selectedCurve }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await store.refresh(forceLists: true)
            ensureSelection()
        }
        .onChange(of: entries.map(\.spec.name)) { ensureSelection() }
        .alert("Rename Curve", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let spec = renaming {
                    Task { await store.rename(curve: spec.name, to: renameText) }
                }
            }
            .disabled(CurveNaming.cleanLabel(renameText) == nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let spec = renaming {
                Text("The command line keeps using “\(spec.name)”.")
            }
        }
        .confirmationDialog(
            "Delete “\(deleting.map(title(forName:)) ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let name = deleting { delete(name) }
            }
        } message: {
            if deleting == store.activeProfile {
                Text("It is the active profile: fans go back to automatic control.")
            } else {
                Text("This cannot be undone.")
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $navigation.selectedCurve) {
            Section("Presets") {
                ForEach(presets, id: \.spec.name) { row($0) }
            }
            Section("My Curves") {
                if userCurves.isEmpty {
                    Text("Duplicate a preset or click + to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(userCurves, id: \.spec.name) { row($0) }
            }
            if !invalidNames.isEmpty {
                Section("Unreadable") {
                    ForEach(invalidNames, id: \.self) { name in
                        Label(name, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .tag(name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 2) {
                Button {
                    Task {
                        if let name = await store.createCurve() { navigation.selectedCurve = name }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .help("New curve")
                Button {
                    deleting = navigation.selectedCurve
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .help("Delete curve")
                .disabled(!canDelete(navigation.selectedCurve))
                Spacer()
            }
            .buttonStyle(.borderless)
            .disabled(!store.canEditCurves)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .overlay(alignment: .top) {
                Rectangle().fill(.separator).frame(height: 1)
            }
        }
    }

    private func row(_ entry: FanCurveEntryDTO) -> some View {
        let spec = entry.spec
        return HStack {
            Label(spec.label ?? spec.name.capitalized, systemImage: PulseStore.symbol(for: spec.name, builtin: entry.builtin))
            Spacer()
            if store.activeProfile == spec.name {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Active")
            }
        }
        .tag(spec.name)
        .contextMenu { actions(for: entry) }
    }

    @ViewBuilder
    private func actions(for entry: FanCurveEntryDTO) -> some View {
        Button("Activate") { Task { await store.activate(entry.spec.name) } }
            .disabled(!store.canControlFans || store.activeProfile == entry.spec.name)
        Button("Duplicate") { duplicate(entry.spec) }
            .disabled(!store.canEditCurves)
        if !entry.builtin {
            Divider()
            Button("Rename…") { startRename(entry.spec) }
                .disabled(!store.canEditCurves)
            Button("Delete…", role: .destructive) { deleting = entry.spec.name }
                .disabled(!store.canEditCurves)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !store.canEditCurves {
                serviceBanner
            }
            if let entry = selectedEntry {
                CurveDetail(store: store, entry: entry,
                            duplicate: { duplicate(entry.spec) },
                            rename: { startRename(entry.spec) },
                            delete: { deleting = entry.spec.name })
            } else if let name = navigation.selectedCurve, let reason = store.invalidCurves[name] {
                InvalidCurveDetail(name: name, reason: reason, canDelete: store.canEditCurves) { deleting = name }
            } else {
                ContentUnavailableView("No Curve Selected", systemImage: "chart.xyaxis.line")
            }
        }
    }

    private var serviceBanner: some View {
        Label("Install the Pulse service (Service tab) to create and edit curves.", systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08))
    }

    // MARK: Actions

    private func ensureSelection() {
        let names = Set(entries.map(\.spec.name)).union(invalidNames)
        if let selected = navigation.selectedCurve, names.contains(selected) { return }
        navigation.selectedCurve = names.contains(store.activeProfile) ? store.activeProfile : entries.first?.spec.name
    }

    private func canDelete(_ name: String?) -> Bool {
        guard let name else { return false }
        return userCurves.contains { $0.spec.name == name } || store.invalidCurves[name] != nil
    }

    private func title(forName name: String) -> String {
        entries.first { $0.spec.name == name }.map { $0.spec.label ?? name } ?? name
    }

    private func duplicate(_ spec: FanCurveSpec) {
        Task {
            if let name = await store.duplicate(spec) { navigation.selectedCurve = name }
        }
    }

    private func startRename(_ spec: FanCurveSpec) {
        renameText = spec.label ?? spec.name.capitalized
        renaming = spec
    }

    private func delete(_ name: String) {
        Task {
            if await store.delete(curve: name), navigation.selectedCurve == name {
                navigation.selectedCurve = nil
                ensureSelection()
            }
        }
    }
}

/// The selected curve: header with actions, then the editor (user curves) or
/// a read-only chart and summary (presets).
struct CurveDetail: View {
    let store: PulseStore
    let entry: FanCurveEntryDTO
    let duplicate: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @AppStorage(SettingsKey.fanSpeedUnit) private var unit: FanSpeedUnit = .rpm
    @Environment(\.undoManager) private var undoManager
    @State private var editor: CurveEditorModel?
    @State private var saving = false

    private var spec: FanCurveSpec { entry.spec }
    private var isActive: Bool { store.activeProfile == spec.name }

    /// The first fan's range, for RPM labels; nil on fanless Macs or without telemetry.
    private var fanRange: FanSpeedRange? {
        guard let fan = store.fans.first, let low = fan.minimumRPM, let high = fan.maximumRPM, high > low else { return nil }
        return FanSpeedRange(minimumRPM: low, maximumRPM: high)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if entry.builtin || !store.canEditCurves {
                CurvesChart(specs: [(spec, .accentColor)], temperatures: CurveDraft.temperatureRange, showsLegend: false)
                    .frame(height: 250)
                summary(showsShape: true)
                Spacer(minLength: 0)
            } else if let editor {
                CurveEditor(model: editor, unit: $unit, hasFanRange: fanRange != nil,
                            preview: CurvePreview.make(draft: editor.draft, temperatures: store.telemetry?.temperatures ?? [], fan: store.fans.first))
                CurveSettingsForm(model: editor)
                Spacer(minLength: 0)
                saveBar(editor)
            }
        }
        .padding(20)
        .task(id: spec.name) { loadEditor() }
        .onChange(of: undoManager) { editor?.undoManager = undoManager }
    }

    private func loadEditor() {
        guard !entry.builtin else {
            editor = nil
            return
        }
        let model = CurveEditorModel(spec: spec, range: fanRange ?? FanSpeedRange(minimumRPM: 0, maximumRPM: 100))
        model.undoManager = undoManager
        editor = model
    }

    private func saveBar(_ editor: CurveEditorModel) -> some View {
        HStack {
            if let error = editor.draft.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Revert") { editor.revert() }
                .disabled(!editor.draft.isDirty || saving)
            Button("Save") {
                Task {
                    saving = true
                    defer { saving = false }
                    let draft = editor.draft.spec
                    if await store.save(draft, activate: false) {
                        editor.reload(spec: draft, range: editor.draft.range)
                    }
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!editor.draft.isDirty || editor.draft.validationError != nil || saving)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: PulseStore.symbol(for: spec.name, builtin: entry.builtin))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.label ?? spec.name.capitalized).font(.title3.weight(.semibold))
                Text(entry.builtin ? "Built-in preset, read-only" : "\(ProductIdentity.cliName) fan profile \(spec.name)")
                    .font(entry.builtin ? .caption : .caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if entry.builtin {
                Button("Duplicate", action: duplicate)
                    .disabled(!store.canEditCurves)
            } else {
                Menu {
                    Button("Duplicate", action: duplicate)
                    Button("Rename…", action: rename)
                    Divider()
                    Button("Delete…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!store.canEditCurves)
            }
            Button(isActive ? "Active" : "Activate") {
                Task { await store.activate(spec.name) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isActive || !store.canControlFans || store.busyProfile != nil)
        }
    }

    private func summary(showsShape: Bool) -> some View {
        let spec = editor?.draft.spec ?? spec
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            if showsShape {
                summaryRow("Shape", CurveSummary.shape(spec))
            }
            summaryRow("Sensors", CurveSummary.sensors(spec))
            summaryRow("Response", CurveSummary.response(spec))
            summaryRow("Hysteresis", CurveSummary.hysteresis(spec))
            summaryRow("Smoothing", CurveSummary.smoothing(spec))
        }
        .font(.callout)
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value)
        }
    }
}

/// A curve from the config file that failed validation.
struct InvalidCurveDetail: View {
    let name: String
    let reason: String
    let canDelete: Bool
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("“\(name)” could not be read", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
            Text(reason).font(.callout.monospaced()).textSelection(.enabled)
            Text("Fix it in \(ProductIdentity.configPath), or delete it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Delete…", role: .destructive, action: delete)
                .disabled(!canDelete)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
