import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Destination CIDR filtering for app-tunnel / full-accounting flows via the transparent proxy.
struct RoutingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newCidrDraft = ""
    @State private var lastAddRejected = false
    @State private var newDomainDraft = ""
    @State private var lastDomainAddRejected = false
    @State private var confirmDeleteAllDomains = false
    @State private var importError: String?
    @State private var lastImportSummary: String?
    @State private var bulkPrefixBrowse: BulkPrefixBrowsePayload?
    private var bulkListsEnabled: Bool { appState.settings.destinationBulkListsEnabled }
    private var customRangesEnabled: Bool { appState.settings.destinationCustomRangesEnabled }
    private var domainNamesEnabled: Bool { appState.settings.destinationDomainNamesEnabled }

    private var bulkListsEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.destinationBulkListsEnabled },
                set: { appState.settings.destinationBulkListsEnabled = $0 })
    }
    private var customRangesEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.destinationCustomRangesEnabled },
                set: { appState.settings.destinationCustomRangesEnabled = $0 })
    }
    private var domainNamesEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.destinationDomainNamesEnabled },
                set: { appState.settings.destinationDomainNamesEnabled = $0 })
    }

    /// Shown as the macOS tooltip on the bulk-lists info icon (Import… and Paste List share one parser).
    private static let bulkListsImportPasteHelpText =
        "Plain UTF-8: IPv4/IPv6 CIDRs, one per line or comma-separated on a line. Lines starting with # are comments. Invalid tokens and duplicates are skipped."

    private static let allDestinationsTooltip =
        "All network traffic is routed through the VPN regardless of destination."

    private static let selectedDestinationsTooltip =
        "Only traffic to the CIDRs and domains you configure below is routed through the VPN."

    private static let customRangesTooltip =
        "Manually enter individual IPv4/IPv6 CIDRs (e.g. 10.0.0.0/8). Only traffic to these ranges is routed through the VPN when destination filtering is on."

    private static let domainNamesTooltip =
        "Enter domain names (e.g. x.com). Their IP addresses are resolved at connect time and treated as destination CIDRs. Re-resolved every 30 seconds."


    /// Destination routing is snapshotted to the extension; avoid mid-session edits (reconnect to apply changes).
    private var destinationRoutingEditingLocked: Bool {
        switch appState.vpnManager.stats.state {
        case .disconnected, .error:
            false
        case .connecting, .connected, .disconnecting, .reconnecting:
            true
        }
    }

    /// True when at least one destination entry exists, is enabled, and its section is turned on.
    private var hasAnyDestinations: Bool {
        (customRangesEnabled && appState.destinationRuleStore.customRules.contains(where: \.isEnabled))
            || (bulkListsEnabled && appState.destinationRuleStore.bulkGroups.contains(where: \.isEnabled))
            || (domainNamesEnabled && appState.destinationRuleStore.domainRules.contains(where: \.isEnabled))
    }

    /// True when enabled rules exist in any section regardless of section toggles.
    private var hasAnyRulesIgnoringSectionToggles: Bool {
        appState.destinationRuleStore.customRules.contains(where: \.isEnabled)
            || appState.destinationRuleStore.bulkGroups.contains(where: \.isEnabled)
            || appState.destinationRuleStore.domainRules.contains(where: \.isEnabled)
    }

    /// Controls in the bulk lists and custom ranges sections are disabled when the VPN is connected.
    private var controlsDisabled: Bool {
        destinationRoutingEditingLocked
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                restrictProxySection()
                bulkListsStandaloneSection()
                customRangesStandaloneSection()
                domainNamesSection()

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.body)
                    Text("If an IP does not match any rule here, it will **bypass the VPN tunnel**.")
                        .foregroundStyle(.primary)
                        .font(.footnote)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if !hasAnyDestinations {
                appState.settings.enforceDestinationFiltering = false
            }
        }
        .onChange(of: hasAnyDestinations) { _, hasAny in
            if !hasAny {
                appState.settings.enforceDestinationFiltering = false
            }
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

    private var destinationFilteringBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.enforceDestinationFiltering },
            set: { newValue in
                if newValue && !hasAnyDestinations { return }
                appState.settings.enforceDestinationFiltering = newValue
            }
        )
    }

    /// Grouped card for the routing radio buttons.
    private func restrictProxySection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: !appState.settings.enforceDestinationFiltering,
                            label: "Tunnel all destinations",
                            disabled: destinationRoutingEditingLocked
                        ) { destinationFilteringBinding.wrappedValue = false }
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.allDestinationsTooltip)
                    }
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: appState.settings.enforceDestinationFiltering,
                            label: "Tunnel selected destinations",
                            disabled: destinationRoutingEditingLocked || !hasAnyDestinations
                        ) { destinationFilteringBinding.wrappedValue = true }
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.selectedDestinationsTooltip)
                        if !hasAnyDestinations {
                            Label(
                                hasAnyRulesIgnoringSectionToggles
                                    ? "Enable a section below to activate destination filtering."
                                    : "Add destination IPs or CIDRs below to enable.",
                                systemImage: "info.circle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.blue)
                        }
                    }
                }

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
            .instantTooltip(Self.bulkListsImportPasteHelpText)
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
                    .disabled(controlsDisabled || !bulkListsEnabled)
                    Button("Paste List") {
                        importCidrFromPasteboard()
                    }
                    .disabled(controlsDisabled || !bulkListsEnabled)
                    Toggle("", isOn: bulkListsEnabledBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    if appState.destinationRuleStore.bulkGroups.isEmpty {
                        Text("No bulk lists. Import a country/zone file or paste many lines at once.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.destinationRuleStore.bulkGroups) { group in
                            DestinationCidrBulkGroupRow(
                                groupID: group.id,
                                controlsDisabled: controlsDisabled || !bulkListsEnabled,
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(bulkListsEnabled ? 1 : 0.4)
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
                        Image(systemName: "info.circle")
                            .font(.body)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.customRangesTooltip)
                        Spacer(minLength: 0)
                        Toggle("", isOn: customRangesEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Group {
                        if appState.destinationRuleStore.customRules.isEmpty {
                            Text("No custom ranges yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appState.destinationRuleStore.customRules) { rule in
                                DestinationCidrRuleRow(
                                    ruleID: rule.id,
                                    controlsDisabled: controlsDisabled || !customRangesEnabled
                                )
                                .environmentObject(appState)
                            }
                        }

                        addRow(sectionEnabled: customRangesEnabled)
                    }
                    .opacity(customRangesEnabled ? 1 : 0.4)
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

    private func addRow(sectionEnabled: Bool = true) -> some View {
        let disabled = controlsDisabled || !sectionEnabled
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $newCidrDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New CIDR range")
                    .onSubmit { commitDraft() }
                    .onChange(of: newCidrDraft) { _, _ in
                        lastAddRejected = false
                    }
                    .disabled(disabled)

                Button("Add") {
                    commitDraft()
                }
                .disabled(
                    disabled
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

    // MARK: - Domain names section

    private func domainNamesSection() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Domain names")
                            .font(.headline)
                        Image(systemName: "info.circle")
                            .font(.body)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.domainNamesTooltip)
                        Spacer(minLength: 0)
                        if !appState.destinationRuleStore.domainRules.isEmpty {
                            Button { confirmDeleteAllDomains = true } label: {
                                Image(systemName: "trash")
                                    .imageScale(.small)
                            }
                            .buttonStyle(.borderless)
                            .instantTooltip("Remove all domains")
                            .disabled(controlsDisabled || !domainNamesEnabled)
                        }
                        Toggle("", isOn: domainNamesEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    .confirmationDialog("Remove all domains?", isPresented: $confirmDeleteAllDomains) {
                        Button("Remove All", role: .destructive) {
                            appState.destinationRuleStore.removeAllDomainRules()
                        }
                    }

                    Group {
                        if appState.destinationRuleStore.domainRules.isEmpty {
                            Text("No domains yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appState.destinationRuleStore.domainRules) { rule in
                                DestinationDomainRuleRow(ruleID: rule.id, controlsDisabled: controlsDisabled || !domainNamesEnabled) {
                                    bulkPrefixBrowse = BulkPrefixBrowsePayload(
                                        id: rule.id,
                                        title: rule.domain,
                                        cidrs: rule.resolvedCidrs
                                    )
                                }
                                .environmentObject(appState)
                            }
                        }

                        domainAddRow(sectionEnabled: domainNamesEnabled)
                    }
                    .opacity(domainNamesEnabled ? 1 : 0.4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func domainAddRow(sectionEnabled: Bool = true) -> some View {
        let disabled = controlsDisabled || !sectionEnabled
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("e.g. x.com", text: $newDomainDraft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Domain name")
                    .onSubmit { commitDomainDraft() }
                    .onChange(of: newDomainDraft) { _, _ in lastDomainAddRejected = false }
                    .disabled(disabled)

                Button("Add") { commitDomainDraft() }
                    .disabled(
                        disabled ||
                        newDomainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            if lastDomainAddRejected {
                Text("Enter a valid domain name or remove duplicate.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private func commitDomainDraft() {
        let trimmed = newDomainDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let domains = Self.extractDomains(from: trimmed)
        guard !domains.isEmpty else {
            lastDomainAddRejected = true
            return
        }
        var anyAdded = false
        for domain in domains {
            if appState.destinationRuleStore.addDomainRule(domain: domain) {
                if let rule = appState.destinationRuleStore.domainRules.last {
                    appState.domainResolutionCoordinator.enqueueResolution(for: rule.id, domain: rule.domain)
                }
                anyAdded = true
            }
        }
        if anyAdded {
            newDomainDraft = ""
            lastDomainAddRejected = false
        } else {
            // All domains were duplicates
            lastDomainAddRejected = true
        }
    }

    /// Extracts the host from a URL or bare domain string, then also adds the
    /// parent domain when the host has more than two labels (e.g. www.youtube.com → youtube.com).
    /// Returns an ordered, deduplicated list so the most-specific entry comes first.
    private static func extractDomains(from input: String) -> [String] {
        // Attempt URL parse; prepend scheme if missing so URLComponents can parse the host.
        let candidate = input.lowercased()
        let urlString = candidate.hasPrefix("http://") || candidate.hasPrefix("https://")
            ? candidate
            : "https://\(candidate)"

        guard let components = URLComponents(string: urlString),
              let host = components.host,
              !host.isEmpty
        else { return [] }

        // Strip trailing dot (absolute FQDN notation).
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !bare.isEmpty else { return [] }

        var results: [String] = [bare]

        // If host has ≥ 3 labels, also add the parent (drop the leading label).
        let labels = bare.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count >= 3 {
            let parent = labels.dropFirst().joined(separator: ".")
            if parent != bare {
                results.append(parent)
            }
        }

        return results
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
    @State private var confirmDelete = false

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
                            .instantTooltip("Double-click to rename")
                            .onTapGesture(count: 2) { beginTitleEdit() }

                        Button(action: beginTitleEdit) {
                            Image(systemName: "square.and.pencil")
                                .font(.body)
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .instantTooltip("Edit list name")
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

            Button { onBrowse() } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .instantTooltip("View prefixes")
            .disabled(controlsDisabled || storedGroup() == nil)

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this bulk list")
            .disabled(controlsDisabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .confirmationDialog("Remove \"\(storedTitle)\"?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                appState.destinationRuleStore.removeBulkGroup(id: groupID)
            }
        }
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
    @State private var confirmDelete = false

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

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this range")
            .disabled(controlsDisabled)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove \"\(storedRecord()?.cidr ?? "")\"?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                appState.destinationRuleStore.removeRule(id: ruleID)
            }
        }
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

// MARK: - Domain rule row

private struct DestinationDomainRuleRow: View {
    let ruleID: UUID
    var controlsDisabled: Bool
    @State private var confirmDelete = false
    let onBrowse: () -> Void

    @EnvironmentObject private var appState: AppState

    private func rule() -> DestinationDomainRule? {
        appState.destinationRuleStore.domainRules.first { $0.id == ruleID }
    }

    private var statusLabel: String {
        switch rule()?.status {
        case .pending: return "Pending"
        case .resolving: return "Resolving\u{2026}"
        case .resolved(let count): return "\(count) IP\(count == 1 ? "" : "s")"
        case .failed(let msg): return "Error: \(msg)"
        case nil: return ""
        }
    }

    private var statusColor: Color {
        switch rule()?.status {
        case .failed: return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule()?.isEnabled ?? false },
                set: { appState.destinationRuleStore.setDomainEnabled($0, for: ruleID) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .disabled(controlsDisabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule()?.domain ?? "")
                    .font(.body)
                    .lineLimit(1)
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            Button { onBrowse() } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .instantTooltip("View resolved IPs")
            .disabled(rule()?.resolvedCidrs.isEmpty ?? true)

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this domain")
            .disabled(controlsDisabled)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove \"\(rule()?.domain ?? "")\"?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                appState.destinationRuleStore.removeDomainRule(id: ruleID)
            }
        }
    }
}
