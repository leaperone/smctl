import PolicyEngine
import ProductIdentity
import SMCtlProtocol
import SwiftUI

/// The Curves pane: built-in presets and user curves on the left, the selected
/// curve on the right. Owns the editor of the selected user curve, so unsaved
/// edits are protected when the selection changes or the window closes.
struct CurvesSettings: View {
    let store: PulseStore
    @Bindable var navigation: SettingsNavigation
    @Environment(\.undoManager) private var undoManager
    @State private var editor: CurveEditorModel?
    @State private var saving = false
    @State private var saveError: String?
    /// The saved version, when it changed elsewhere while the editor had edits.
    @State private var conflict: FanCurveSpec?
    @State private var renaming: FanCurveSpec?
    @State private var renameText = ""
    @State private var deleting: String?
    /// Leaving a curve whose edits could not be saved.
    @State private var unsavable = false

    private var entries: [FanCurveEntryDTO] { store.curveEntries }
    private var presets: [FanCurveEntryDTO] { entries.filter(\.builtin) }
    private var userCurves: [FanCurveEntryDTO] { entries.filter { !$0.builtin } }
    private var invalidNames: [String] { store.invalidCurves.keys.sorted() }

    private var selectedEntry: FanCurveEntryDTO? {
        entries.first { $0.spec.name == navigation.selectedCurve }
    }

    /// The first fan's range, for RPM labels; nil on fanless Macs or without telemetry.
    private var fanRange: FanSpeedRange? {
        guard let fan = store.fans.first, let low = fan.minimumRPM, let high = fan.maximumRPM, high > low else { return nil }
        return FanSpeedRange(minimumRPM: low, maximumRPM: high)
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
            loadEditor()
        }
        .onChange(of: entries.map(\.spec.name)) { ensureSelection() }
        .onChange(of: navigation.selectedCurve) { loadEditor() }
        .onChange(of: selectedEntry?.spec) { _, saved in reconcile(with: saved) }
        .onChange(of: undoManager) { editor?.undoManager = undoManager }
        .onChange(of: navigation.pending) { _, pending in
            guard pending != nil else { return }
            // Leaving a curve saves it; ask only when that fails.
            Task {
                if await save(activate: false) { navigation.confirmPending() } else { unsavable = true }
            }
        }
        .alert(pendingTitle, isPresented: $unsavable) {
            Button("Discard Changes", role: .destructive) {
                editor?.revert()
                navigation.confirmPending()
            }
            Button("Keep Editing", role: .cancel) { navigation.cancelPending() }
        } message: {
            Text(saveError ?? editor?.draft.validationError ?? "")
        }
        .alert("Rename Curve", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let spec = renaming { rename(spec, to: renameText) }
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

    private var pendingTitle: String {
        "Changes to “\(editor?.draft.spec.label ?? navigation.selectedCurve ?? "")” can't be saved"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { navigation.selectedCurve }, set: { navigation.request($0) })) {
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
                        if let name = await store.createCurve() { navigation.request(name) }
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
        let edited = editor?.draft.spec.name == spec.name && editor?.draft.isDirty == true
        return HStack {
            Label((edited ? editor?.draft.spec.label : spec.label) ?? spec.name.capitalized,
                  systemImage: PulseStore.symbol(for: spec.name, builtin: entry.builtin))
            if edited {
                Text("Edited").font(.caption).foregroundStyle(.secondary)
            }
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
            } else if store.isFanless {
                fanlessBanner
            }
            if let saved = conflict, let editor {
                conflictBanner(saved: saved, editor: editor)
            }
            if let entry = selectedEntry {
                CurveDetail(store: store, entry: entry, editor: entry.builtin || !store.canEditCurves ? nil : editor,
                            saving: saving, saveError: saveError,
                            save: { activate in Task { await save(activate: activate) } },
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

    private var fanlessBanner: some View {
        Label("This Mac has no fan. Pulse shows its temperatures; curves can be edited but have nothing to drive.", systemImage: "fanblades.slash")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08))
    }

    private func conflictBanner(saved: FanCurveSpec, editor: CurveEditorModel) -> some View {
        HStack(spacing: 10) {
            Label("This curve was changed elsewhere (command line or another window).", systemImage: "arrow.triangle.2.circlepath")
                .font(.callout)
            Spacer()
            Button("Use Saved Version") {
                editor.reload(spec: saved, range: editor.draft.range)
                conflict = nil
            }
            Button("Keep My Edits") {
                editor.keepEdits(over: saved)
                conflict = nil
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    // MARK: Editing

    /// One editor per selected user curve, kept while it stays selected.
    private func loadEditor() {
        conflict = nil
        saveError = nil
        guard let entry = selectedEntry, !entry.builtin else {
            editor = nil
            navigation.editor = nil
            return
        }
        if editor?.draft.spec.name == entry.spec.name { return }
        let model = CurveEditorModel(spec: entry.spec, range: fanRange ?? FanSpeedRange(minimumRPM: 0, maximumRPM: 100))
        model.undoManager = undoManager
        editor = model
        navigation.editor = model
    }

    private func reconcile(with saved: FanCurveSpec?) {
        guard let editor, let saved, saved.name == editor.draft.spec.name, !saving else { return }
        if editor.savedCurveChanged(to: saved) == .conflict {
            conflict = saved
        }
    }

    /// Saves the draft; on success it becomes the editor's new original.
    @discardableResult
    private func save(activate: Bool) async -> Bool {
        guard let editor, editor.draft.validationError == nil else { return false }
        saving = true
        defer { saving = false }
        let spec = editor.draft.spec
        if !editor.draft.isDirty {
            if activate { await store.activate(spec.name) }
            return true
        }
        if await store.save(spec, activate: activate) {
            editor.reload(spec: spec, range: editor.draft.range)
            conflict = nil
            saveError = nil
            return true
        }
        // Shown here rather than in the popover.
        saveError = store.actionError ?? "The curve could not be saved."
        store.actionError = nil
        return false
    }

    // MARK: Actions

    private func ensureSelection() {
        let names = Set(entries.map(\.spec.name)).union(invalidNames)
        if let selected = navigation.selectedCurve, names.contains(selected) { return }
        navigation.select(names.contains(store.activeProfile) ? store.activeProfile : entries.first?.spec.name)
    }

    private func canDelete(_ name: String?) -> Bool {
        guard let name else { return false }
        return userCurves.contains { $0.spec.name == name } || store.invalidCurves[name] != nil
    }

    private func title(forName name: String) -> String {
        entries.first { $0.spec.name == name }.map { $0.spec.label ?? name } ?? name
    }

    /// Duplicates what is on screen: the edits, when duplicating the curve
    /// being edited (they move to the copy and the original is left as saved).
    private func duplicate(_ spec: FanCurveSpec) {
        let source = editor?.draft.spec.name == spec.name ? (editor?.draft.spec ?? spec) : spec
        Task {
            guard let name = await store.duplicate(source) else { return }
            if editor?.draft.spec.name == spec.name { editor?.revert() }
            navigation.select(name)
        }
    }

    private func startRename(_ spec: FanCurveSpec) {
        renameText = editor?.draft.spec.name == spec.name ? (editor?.draft.spec.label ?? spec.name.capitalized) : (spec.label ?? spec.name.capitalized)
        renaming = spec
    }

    /// Renaming the curve being edited changes the draft's label, saved with
    /// the rest; otherwise it is saved right away.
    private func rename(_ spec: FanCurveSpec, to text: String) {
        if let editor, editor.draft.spec.name == spec.name, editor.draft.isDirty {
            editor.edit("Rename") { $0.setLabel(text) }
        } else {
            Task { await store.rename(curve: spec.name, to: text) }
        }
    }

    private func delete(_ name: String) {
        Task {
            if editor?.draft.spec.name == name { editor?.revert() }
            if await store.delete(curve: name), navigation.selectedCurve == name {
                navigation.select(nil)
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
    let editor: CurveEditorModel?
    let saving: Bool
    let saveError: String?
    let save: (_ activate: Bool) -> Void
    let duplicate: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @AppStorage(SettingsKey.fanSpeedUnit) private var unit: FanSpeedUnit = .rpm
    @State private var stressTest: StressTestModel?

    private var spec: FanCurveSpec { editor?.draft.spec ?? entry.spec }
    private var isActive: Bool { store.activeProfile == entry.spec.name }
    private var isDirty: Bool { editor?.draft.isDirty ?? false }

    private var fanRange: FanSpeedRange? {
        guard let fan = store.fans.first, let low = fan.minimumRPM, let high = fan.maximumRPM, high > low else { return nil }
        return FanSpeedRange(minimumRPM: low, maximumRPM: high)
    }

    private var hasFanRange: Bool { fanRange != nil }

    private var allowsStopping: Bool { store.telemetry?.safety.allowsStoppingFans ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let editor {
                CurveEditor(model: editor, unit: $unit, hasFanRange: hasFanRange,
                            preview: CurvePreview.make(draft: editor.draft, temperatures: store.telemetry?.temperatures ?? [], fan: store.fans.first),
                            allowsStopping: allowsStopping, fanRangeNote: FanRangeNote.text(fans: store.fans))
                CurveSettingsForm(model: editor, allowsStopping: allowsStopping)
                Spacer(minLength: 0)
                saveBar(editor)
            } else {
                let viewer = CurveEditorModel(spec: spec, range: fanRange ?? FanSpeedRange(minimumRPM: 0, maximumRPM: 100))
                CurveEditor(model: viewer, unit: $unit, hasFanRange: hasFanRange,
                            preview: CurvePreview.make(draft: viewer.draft, temperatures: store.telemetry?.temperatures ?? [], fan: store.fans.first),
                            editable: false, fanRangeNote: FanRangeNote.text(fans: store.fans))
                summary
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .sheet(item: $stressTest) { model in
            StressTestSheet(model: model, fanRange: fanRange.map { $0.minimumRPM...$0.maximumRPM })
        }
    }

    private func saveBar(_ editor: CurveEditorModel) -> some View {
        HStack {
            if let error = saveError ?? editor.draft.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(saveError != nil ? .red : .orange)
                    .lineLimit(2)
            } else if isDirty && isActive {
                Text("Active curve: saving applies it right away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if saving { ProgressView().controlSize(.small) }
            Button("Revert") { editor.revert() }
                .disabled(!isDirty || saving)
            Button("Save") { save(false) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isDirty || editor.draft.validationError != nil || saving)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: PulseStore.symbol(for: entry.spec.name, builtin: entry.builtin))
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
            Button("Stress Test…", action: openStressTest)
                .help(isDirty ? "Save your changes first: the test runs the saved curve." : "Heat the Mac and see how this curve responds.")
                .disabled(isDirty || !store.canControlFans)
            activateButton
        }
    }

    private func openStressTest() {
        let store = self.store
        stressTest = StressTestModel(profile: entry.spec.name, title: spec.label ?? spec.name.capitalized, service: store.service, store: store) {
            Task { await store.refresh(forceLists: true) }
        }
    }

    @ViewBuilder
    private var activateButton: some View {
        if isDirty {
            // Activating the saved version while edits are on screen would be
            // misleading: save them first.
            Button(isActive ? "Save" : "Save & Activate") { save(!isActive) }
                .buttonStyle(.borderedProminent)
                .disabled(saving || editor?.draft.validationError != nil || (!isActive && !store.canControlFans))
        } else {
            Button(isActive ? "Active" : "Activate") {
                Task { await store.activate(entry.spec.name) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isActive || !store.canControlFans || store.busyProfile != nil)
        }
    }

    private var summary: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            summaryRow("Shape", CurveSummary.shape(spec))
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
