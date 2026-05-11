import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Destination CIDR filtering for app-tunnel / full-accounting flows via the transparent proxy.
struct RoutingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newCidrDraft = ""
    @State private var lastAddRejected = false
    @State private var importError: String?
    @State private var lastImportSummary: String?
    @State private var bulkPrefixBrowse: BulkPrefixBrowsePayload?

    /// Shown as the macOS tooltip on the bulk-lists info icon (Import… and Paste List share one parser).
    private static let bulkListsImportPasteHelpText =
        "Plain UTF-8: IPv4/IPv6 CIDRs, one per line or comma-separated on a line. Lines starting with # are comments. Invalid tokens and duplicates are skipped."

    /// Destination routing is snapshotted to the extension; avoid mid-session edits (reconnect to apply changes).
    private var destinationRoutingEditingLocked: Bool {
        switch appState.vpnManager.stats.state {
        case .disconnected, .error:
            false
        case .connecting, .connected, .disconnecting, .reconnecting:
            true
        }
    }

    /// Controls in the bulk lists and custom ranges sections are disabled when filtering is off or the VPN is connected.
    private var controlsDisabled: Bool {
        destinationRoutingEditingLocked || !appState.settings.enforceDestinationFiltering
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                restrictProxySection()
                bulkListsStandaloneSection()
                    .opacity(appState.settings.enforceDestinationFiltering ? 1 : 0.4)
                customRangesStandaloneSection()
                    .opacity(appState.settings.enforceDestinationFiltering ? 1 : 0.4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Advanced")
        .alert("Import Failed", isPresented: .init(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .sheet(item: $bulkPrefixBrowse) { payload in
            BulkGroupPrefixesView(title: payload.title, cidrs: payload.cidrs)
        }
    }

    /// Grouped card for the enforce toggle — avoids `Form` stretching or odd split-view vertical centering when paired with `.fixedSize`.
    private func restrictProxySection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $appState.settings.enforceDestinationFiltering) {
                    Text("Destination Routing")
                        .font(.headline)
                }
                .toggleStyle(.switch)
                .help(
                    destinationRoutingEditingLocked
                        ? "Disconnect the VPN to change destination routing."
                        : "Toggle destination CIDR filtering for proxied TCP flows."
                )
                .disabled(destinationRoutingEditingLocked)

                Text(
                    "TCP only and IP destinations only (no DNS). UDP isn’t included."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func bulkListsFormatInfoIcon() -> some View {
        Image(systemName: "info.circle")
            .font(.body)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Bulk import and paste format")
            .help(Self.bulkListsImportPasteHelpText)
    }

    @ViewBuilder
    private func bulkListsStandaloneSection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Bulk lists")
                        .font(.headline)
                    bulkListsFormatInfoIcon()
                    Spacer(minLength: 8)
                    Button("Import…") {
                        importCidrFromFile()
                    }
                    .disabled(controlsDisabled)
                    Button("Paste List") {
                        importCidrFromPasteboard()
                    }
                    .disabled(controlsDisabled)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if appState.destinationRuleStore.bulkGroups.isEmpty {
                        Text("No bulk lists. Import a country/zone file or paste many lines at once.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.destinationRuleStore.bulkGroups) { group in
                            DestinationCidrBulkGroupRow(
                                groupID: group.id,
                                controlsDisabled: controlsDisabled,
                                onBrowse: {
                                    bulkPrefixBrowse = BulkPrefixBrowsePayload(
                                        id: group.id,
                                        title: group.title,
                                        cidrs: group.cidrs
                                    )
                                }
                            )
                            .environmentObject(appState)
                        }
                    }

                    if let lastImportSummary {
                        Text(lastImportSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    warningRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func customRangesStandaloneSection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Custom ranges")
                            .font(.headline)
                        Spacer(minLength: 0)
                    }

                    if appState.destinationRuleStore.customRules.isEmpty {
                        Text("No custom ranges yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.destinationRuleStore.customRules) { rule in
                            DestinationCidrRuleRow(
                                ruleID: rule.id,
                                controlsDisabled: controlsDisabled
                            )
                            .environmentObject(appState)
                        }
                    }

                    addRow()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Add individual prefixes by hand. Duplicates that already exist in bulk lists or here are rejected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func warningRow() -> some View {
        let enabledCount = enabledParsingRangeCount()
        let enforceOn = appState.settings.enforceDestinationFiltering
        if enforceOn, enabledCount == 0 {
            Label(
                "No valid CIDRs are enabled — with filtering on, proxied flows are not relayed.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enabledParsingRangeCount() -> Int {
        appState.destinationRuleStore.enabledFlattenedCidrs()
            .filter { !IPCIDRMatcher.prepare([$0]).isEmpty }
            .count
    }

    private func addRow() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $newCidrDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New CIDR range")
                    .onSubmit { commitDraft() }
                    .onChange(of: newCidrDraft) { _, _ in
                        lastAddRejected = false
                    }
                    .disabled(controlsDisabled)

                Button("Add") {
                    commitDraft()
                }
                .disabled(
                    controlsDisabled
                        || newCidrDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if lastAddRejected {
                Text("Enter a valid IPv4/IPv6 CIDR before adding, or remove duplicate.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func commitDraft() {
        let trimmed = newCidrDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastAddRejected = false
            return
        }
        if appState.destinationRuleStore.addRule(cidr: newCidrDraft) {
            newCidrDraft = ""
            lastAddRejected = false
        } else {
            lastAddRejected = true
        }
    }

    private func importCidrFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        var types: [UTType] = [.plainText, .utf8PlainText]
        if let conf = UTType(filenameExtension: "conf") {
            types.append(conf)
        }
        if let zone = UTType(filenameExtension: "zone") {
            types.append(zone)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let title = url.lastPathComponent
            applyCidrImport(text, bulkTitle: title)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importCidrFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            lastImportSummary = "Clipboard has no text to import."
            return
        }
        applyCidrImport(text, bulkTitle: "Pasted list")
    }

    private func applyCidrImport(_ plainText: String, bulkTitle: String) {
        let result = appState.destinationRuleStore.importCidrLines(from: plainText, bulkTitle: bulkTitle)
        lastImportSummary =
            "Added \(result.added) · skipped \(result.skippedInvalid) invalid · skipped \(result.skippedDuplicate) duplicate"
    }
}

// MARK: - Bulk group row (one line per import; toggle / remove / browse)

private struct BulkPrefixBrowsePayload: Identifiable {
    let id: UUID
    let title: String
    let cidrs: [String]
}

private struct DestinationCidrBulkGroupRow: View {
    let groupID: UUID
    var controlsDisabled: Bool
    let onBrowse: () -> Void

    @EnvironmentObject private var appState: AppState
    @FocusState private var titleFieldFocused: Bool
    @State private var editingTitle = false
    @State private var titleDraft = ""

    private var storedTitle: String {
        storedGroup()?.title ?? "Bulk list"
    }

    private func storedGroup() -> DestinationCidrBulkGroup? {
        appState.destinationRuleStore.bulkGroups.first(where: { $0.id == groupID })
    }

    private func beginTitleEdit() {
        guard !controlsDisabled else { return }
        titleDraft = storedTitle
        editingTitle = true
        titleFieldFocused = true
    }

    private func cancelTitleEdit() {
        titleDraft = storedTitle
        editingTitle = false
        titleFieldFocused = false
    }

    private func commitTitleEdit() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cancelTitleEdit()
            return
        }
        if trimmed != storedTitle {
            appState.destinationRuleStore.renameBulkGroup(id: groupID, title: trimmed)
            titleDraft = storedTitle
        }
        editingTitle = false
        titleFieldFocused = false
    }

    private var bulkTitleFieldBinding: Binding<String> {
        Binding(
            get: { editingTitle ? titleDraft : storedTitle },
            set: { if editingTitle { titleDraft = $0 } }
        )
    }

    private var bulkTitleWidthProbe: String {
        let s = editingTitle ? titleDraft : storedTitle
        return s.isEmpty ? "\u{00a0}" : s
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { storedGroup()?.isEnabled ?? false },
                set: { appState.destinationRuleStore.setBulkGroupEnabled($0, for: groupID) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(controlsDisabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if editingTitle {
                        TextField("", text: $titleDraft)
                            .font(.body)
                            .textFieldStyle(.plain)
                            .lineLimit(1)
                            .focused($titleFieldFocused)
                            .accessibilityLabel("Bulk list name")
                            .onSubmit { commitTitleEdit() }
                            .onExitCommand { cancelTitleEdit() }
                            .onChange(of: titleFieldFocused) { _, focused in
                                if editingTitle, !focused { commitTitleEdit() }
                            }
                            .padding(.horizontal, 3)
                            .padding(.vertical, 2)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                                    }
                            }
                            .frame(minWidth: 80)
                    } else {
                        Text(storedTitle)
                            .font(.body)
                            .lineLimit(1)
                            .help("Double-click to rename")
                            .onTapGesture(count: 2) { beginTitleEdit() }

                        Button(action: beginTitleEdit) {
                            Image(systemName: "square.and.pencil")
                                .font(.body)
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit list name")
                        .accessibilityLabel("Edit list name")
                        .disabled(controlsDisabled)
                    }
                }

                Text("\((storedGroup()?.cidrs.count ?? 0)) prefixes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear {
                titleDraft = storedTitle
            }
            .onChange(of: storedTitle) { _, _ in
                if !editingTitle {
                    titleDraft = storedTitle
                }
            }

            Spacer(minLength: 0)

            Button("View…") {
                onBrowse()
            }
            .disabled(controlsDisabled || storedGroup() == nil)

            Button {
                appState.destinationRuleStore.removeBulkGroup(id: groupID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, .quaternary)
            }
            .buttonStyle(.borderless)
            .help("Remove this bulk list")
            .disabled(controlsDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - Searchable prefix list (lazy List)

private struct BulkGroupPrefixesView: View {
    let title: String
    let cidrs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""

    private var filteredEnumerated: [(offset: Int, cidr: String)] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pairs = Array(cidrs.enumerated().map { (offset: $0.offset, cidr: $0.element) })
        if f.isEmpty {
            return pairs
        }
        return pairs.filter { $0.cidr.lowercased().contains(f) }
    }

    var body: some View {
        NavigationStack {
            List(Array(filteredEnumerated), id: \.offset) { pair in
                Text(pair.cidr)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .navigationTitle(title)
            .searchable(text: $filter, prompt: Text("Filter prefixes"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

// MARK: - Custom row (commit validated text on Return; invalid input is never saved)

private struct DestinationCidrRuleRow: View {
    let ruleID: UUID
    var controlsDisabled: Bool

    @EnvironmentObject private var appState: AppState
    @State private var draft: String = ""

    private func storedRecord() -> DestinationCidrRule? {
        appState.destinationRuleStore.customRules.first(where: { $0.id == ruleID })
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { storedRecord()?.isEnabled ?? false },
                set: { appState.destinationRuleStore.setEnabled($0, for: ruleID) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(controlsDisabled)

            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("CIDR range")
                .onAppear {
                    draft = storedRecord()?.cidr ?? ""
                }
                .onSubmit {
                    persistDraftOrRevert()
                }
                .disabled(controlsDisabled)

            Button {
                appState.destinationRuleStore.removeRule(id: ruleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, .quaternary)
            }
            .buttonStyle(.borderless)
            .help("Remove this range")
            .disabled(controlsDisabled)
        }
        .padding(.vertical, 2)
    }

    private func persistDraftOrRevert() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            appState.destinationRuleStore.removeRule(id: ruleID)
            return
        }
        guard !IPCIDRMatcher.prepare([trimmed]).isEmpty else {
            draft = storedRecord()?.cidr ?? ""
            return
        }
        appState.destinationRuleStore.updateCidr(ruleID, cidr: trimmed)
        draft = storedRecord()?.cidr ?? trimmed
    }
}
