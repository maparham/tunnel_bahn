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

    /// A mode radio the user selected while its rule set is empty: lists are shown and editable,
    /// but enforcement stays off until the first effective destination exists. nil when the
    /// selected radio state is fully captured by enforceDestinationFiltering + filterMode.
    @State private var previewedEmptyMode: DestinationFilterMode?

    /// Which mode's lists the sections display (always follows the filter mode).
    private var displayedMode: DestinationFilterMode { appState.settings.destinationFilterMode }

    /// True when "Tunnel all destinations" is the selected radio: sections dim and lock.
    private var destinationSectionsInactive: Bool {
        !appState.settings.enforceDestinationFiltering && previewedEmptyMode == nil
    }

    private var bulkListsEnabled: Bool { appState.settings.activeSectionToggles.bulkLists }
    private var customRangesEnabled: Bool { appState.settings.activeSectionToggles.customRanges }
    private var domainNamesEnabled: Bool { appState.settings.activeSectionToggles.domainNames }

    private var bulkListsEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.activeSectionToggles.bulkLists },
                set: { newValue in
                    appState.settings.activeSectionToggles.bulkLists = newValue
                    if newValue && appState.destinationRuleStore.bulkGroups.contains(where: \.isEnabled) {
                        appState.settings.enforceDestinationFiltering = true
                    }
                })
    }
    private var customRangesEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.activeSectionToggles.customRanges },
                set: { newValue in
                    appState.settings.activeSectionToggles.customRanges = newValue
                    if newValue && appState.destinationRuleStore.customRules.contains(where: \.isEnabled) {
                        appState.settings.enforceDestinationFiltering = true
                    }
                })
    }
    private var domainNamesEnabledBinding: Binding<Bool> {
        Binding(get: { appState.settings.activeSectionToggles.domainNames },
                set: { newValue in
                    appState.settings.activeSectionToggles.domainNames = newValue
                    if newValue && appState.destinationRuleStore.domainRules.contains(where: \.isEnabled) {
                        appState.settings.enforceDestinationFiltering = true
                    }
                })
    }

    /// Shown as the macOS tooltip on the bulk-lists info icon (Import… and Paste List share one parser).
    private static let bulkListsImportPasteHelpText =
        "IPv4/IPv6 CIDRs, one per line or comma-separated. # starts a comment. Invalid and duplicate entries are skipped."

    private static let allDestinationsTooltip =
        "All network traffic is routed through the VPN regardless of destination."

    private static let selectedDestinationsTooltip =
        "Only traffic to the CIDRs and domains you configure below is routed through the VPN."

    private static let customRangesTooltip =
        "Individual IPv4/IPv6 CIDRs, e.g. 10.0.0.0/8."

    private static let domainNamesTooltip =
        "Domain names, e.g. x.com. Resolved to IPs at connect time and re-resolved every 30 seconds."

    private static let excludeDestinationsTooltip =
        "Tunnel everything except the destinations below, e.g. your country's IP ranges. App-Tunnel mode only."

    private static let resolveDNSLocallyTooltip =
        "Use the local resolver instead of the tunnel resolver, steering direct sites to nearby CDN edges. A censored local resolver can break tunneled sites. SSH profiles always resolve remotely."


    /// Destination routing is snapshotted to the extension at connect time. Editing is locked
    /// only while viewing the currently-connected profile; edits to a non-active profile go to
    /// its own on-disk snapshot and take effect on its next connect.
    private var destinationRoutingEditingLocked: Bool {
        appState.isViewingConnectedProfile
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

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                restrictProxySection()

                VStack(alignment: .leading, spacing: 0) {
                    bulkListsStandaloneSection()
                    customRangesStandaloneSection()
                    domainNamesSection()

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.body)
                        Text(destinationSectionsInactive
                            ? "All network traffic is tunneled. Destination lists are inactive."
                            : (displayedMode == .exclude
                                ? "IPs matching a list here will **bypass the tunnel**; everything else is tunneled."
                                : "IPs not matching any list here will **bypass the tunnel**."))
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
                .opacity(destinationSectionsInactive ? 0.5 : 1)

                resolveDNSLocallySection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if !hasAnyDestinations {
                appState.settings.enforceDestinationFiltering = false
            }
            normalizeExcludeModeForRoutingMode()
        }
        .onChange(of: hasAnyDestinations) { _, hasAny in
            if !hasAny {
                appState.settings.enforceDestinationFiltering = false
            } else if previewedEmptyMode == displayedMode {
                appState.settings.enforceDestinationFiltering = true
                previewedEmptyMode = nil
            }
        }
        .onChange(of: appState.settings.routingMode) { _, _ in
            normalizeExcludeModeForRoutingMode()
        }
        .onChange(of: appState.profileStore.selectedProfileID) { _, _ in
            previewedEmptyMode = nil
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

    /// Exclude mode is unsupported in full-tunnel routing mode (see `isFullTunnelDestFilterShape`).
    /// Collapse a residual `.exclude` back to `.include` so the UI never shows a selected-but-
    /// inert exclude radio and the connect-path shape stays consistent with what's displayed.
    private func normalizeExcludeModeForRoutingMode() {
        if appState.settings.routingMode == .fullTunnel,
           appState.settings.destinationFilterMode == .exclude {
            appState.settings.destinationFilterMode = .include
            previewedEmptyMode = nil
        }
    }

    private func selectTunnelAll() {
        previewedEmptyMode = nil
        appState.settings.enforceDestinationFiltering = false
        appState.settings.activeSectionToggles = DestinationSectionToggles(
            bulkLists: false, customRanges: false, domainNames: false
        )  // preserves the existing "deselecting filtering turns sections off" behavior, per mode
    }

    private func selectMode(_ mode: DestinationFilterMode) {
        appState.settings.destinationFilterMode = mode  // AppState sink swaps the store's arrays
        if hasAnyDestinations {  // now evaluates against the newly displayed mode
            appState.settings.enforceDestinationFiltering = true
            previewedEmptyMode = nil
        } else {
            appState.settings.enforceDestinationFiltering = false
            previewedEmptyMode = mode
        }
    }

    private func modeGlyph(_ mode: DestinationFilterMode) -> some View {
        Image(systemName: mode == .include ? "plus.circle" : "minus.circle")
            .foregroundStyle(mode == .include ? Color.blue : Color.orange)
            .imageScale(.medium)
            .accessibilityLabel(mode == .include ? "Tunnel only selected" : "Tunnel all except selected")
    }

    /// Grouped card for the routing radio buttons.
    private func restrictProxySection() -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: !appState.settings.enforceDestinationFiltering
                                && previewedEmptyMode == nil,
                            label: "Tunnel all destinations",
                            disabled: destinationRoutingEditingLocked
                        ) { selectTunnelAll() }
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.allDestinationsTooltip)
                    }
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: (appState.settings.enforceDestinationFiltering
                                && displayedMode == .include)
                                || previewedEmptyMode == .include,
                            label: "Tunnel only selected destinations",
                            disabled: destinationRoutingEditingLocked
                        ) { selectMode(.include) }
                        modeGlyph(.include)
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.selectedDestinationsTooltip)
                    }
                    HStack(spacing: 6) {
                        RadioButton(
                            isOn: ((appState.settings.enforceDestinationFiltering
                                && displayedMode == .exclude)
                                || previewedEmptyMode == .exclude)
                                && appState.settings.routingMode != .fullTunnel,
                            label: "Tunnel all except selected",
                            // Exclude semantics are unsupported in full-tunnel routing mode (the
                            // packet tunnel narrows routes with include semantics); offered only in
                            // App-Tunnel mode. See excludeDestinationsTooltip.
                            disabled: destinationRoutingEditingLocked
                                || appState.settings.routingMode == .fullTunnel
                        ) { selectMode(.exclude) }
                        modeGlyph(.exclude)
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.excludeDestinationsTooltip)
                    }
                }

                if previewedEmptyMode != nil {
                    Label(
                        hasAnyRulesIgnoringSectionToggles
                            ? "Enable a section below to activate destination filtering."
                            : "Add destination IPs or CIDRs below to enable.",
                        systemImage: "questionmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// DNS-resolution toggle, placed at the bottom since it applies profile-wide
    /// regardless of the routing mode selected above.
    private func resolveDNSLocallySection() -> some View {
        GroupBox {
            HStack(spacing: 6) {
                Toggle("Resolve DNS locally", isOn: $appState.settings.resolveDNSLocally)
                    .toggleStyle(.checkbox)
                    .disabled(destinationRoutingEditingLocked)
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .instantTooltip(Self.resolveDNSLocallyTooltip)
                Spacer(minLength: 0)
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
        Image(systemName: "questionmark.circle")
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
                    modeGlyph(displayedMode)
                    Text("Bulk lists")
                        .font(.headline)
                    bulkListsFormatInfoIcon()
                    Spacer(minLength: 8)
                    Button("Import…") {
                        importCidrFromFile()
                    }
                    .disabled(destinationRoutingEditingLocked || !bulkListsEnabled || destinationSectionsInactive)
                    Button("Paste List") {
                        importCidrFromPasteboard()
                    }
                    .disabled(destinationRoutingEditingLocked || !bulkListsEnabled || destinationSectionsInactive)
                    Toggle("", isOn: bulkListsEnabledBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(destinationRoutingEditingLocked || destinationSectionsInactive)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if appState.destinationRuleStore.bulkGroups.isEmpty {
                        Text("No bulk lists. Import a country/zone file or paste many lines at once.")
                            .foregroundStyle(.secondary)
                            .opacity(bulkListsEnabled ? 1 : 0.4)
                    } else {
                        ForEach(appState.destinationRuleStore.bulkGroups) { group in
                            DestinationCidrBulkGroupRow(
                                groupID: group.id,
                                controlsDisabled: destinationRoutingEditingLocked || !bulkListsEnabled || destinationSectionsInactive,
                                editingLocked: destinationRoutingEditingLocked || destinationSectionsInactive,
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
                            .opacity(bulkListsEnabled ? 1 : 0.4)
                    }
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
                        modeGlyph(displayedMode)
                        Text("Custom ranges")
                            .font(.headline)
                        Image(systemName: "questionmark.circle")
                            .font(.body)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .instantTooltip(Self.customRangesTooltip)
                        Spacer(minLength: 0)
                        Toggle("", isOn: customRangesEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(destinationRoutingEditingLocked || destinationSectionsInactive)
                    }

                    Group {
                        if appState.destinationRuleStore.customRules.isEmpty {
                            Text("No custom ranges yet.")
                                .foregroundStyle(.secondary)
                                .opacity(customRangesEnabled ? 1 : 0.4)
                        } else {
                            ForEach(appState.destinationRuleStore.customRules) { rule in
                                DestinationCidrRuleRow(
                                    ruleID: rule.id,
                                    controlsDisabled: destinationRoutingEditingLocked || !customRangesEnabled || destinationSectionsInactive,
                                    editingLocked: destinationRoutingEditingLocked || destinationSectionsInactive
                                )
                                .environmentObject(appState)
                            }
                        }

                        addRow(sectionEnabled: customRangesEnabled && !destinationSectionsInactive)
                            .opacity(customRangesEnabled ? 1 : 0.4)
                    }
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
        let disabled = destinationRoutingEditingLocked || !sectionEnabled
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
                        modeGlyph(displayedMode)
                        Text("Domain names")
                            .font(.headline)
                        Image(systemName: "questionmark.circle")
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
                            .disabled(destinationRoutingEditingLocked || destinationSectionsInactive)
                        }
                        Toggle("", isOn: domainNamesEnabledBinding)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(destinationRoutingEditingLocked || destinationSectionsInactive)
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
                                .opacity(domainNamesEnabled ? 1 : 0.4)
                        } else {
                            ForEach(appState.destinationRuleStore.domainRules) { rule in
                                DestinationDomainRuleRow(ruleID: rule.id, controlsDisabled: destinationRoutingEditingLocked || !domainNamesEnabled || destinationSectionsInactive, editingLocked: destinationRoutingEditingLocked || destinationSectionsInactive) {
                                    bulkPrefixBrowse = BulkPrefixBrowsePayload(
                                        id: rule.id,
                                        title: rule.domain,
                                        cidrs: rule.resolvedCidrs
                                    )
                                }
                                .environmentObject(appState)
                            }
                        }

                        domainAddRow(sectionEnabled: domainNamesEnabled && !destinationSectionsInactive)
                            .opacity(domainNamesEnabled ? 1 : 0.4)
                    }
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
        let disabled = destinationRoutingEditingLocked || !sectionEnabled
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

    /// Extracts exactly the host from a URL or bare domain string — no parent-domain expansion.
    /// The proxy's SNI matcher is already suffix-based (`x.com` matches `api.x.com`), so entering a
    /// specific host covers its subdomains going DOWN. The old behavior ALSO added the parent
    /// (www.youtube.com → youtube.com), which broadened UP to the whole registrable domain and, with
    /// no public-suffix awareness, turned `foo.blogspot.com` into a rule matching every blogspot
    /// site. Exact-only mirrors the destination-IP policy: route precisely what the user entered.
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

        return [bare]
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
    var editingLocked: Bool
    let onBrowse: () -> Void

    @EnvironmentObject private var appState: AppState
    @FocusState private var titleFieldFocused: Bool
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var confirmDelete = false
    @State private var copiedPrefixes = false

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
            .opacity(controlsDisabled ? 0.4 : 1)
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

            Button {
                if let cidrs = storedGroup()?.cidrs {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cidrs.joined(separator: "\n"), forType: .string)
                    copiedPrefixes = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedPrefixes = false
                    }
                }
            } label: {
                Image(systemName: copiedPrefixes ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .instantTooltip(copiedPrefixes ? "Copied!" : "Copy prefix list")

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this bulk list")
            .disabled(editingLocked)
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
    @State private var copied = false

    private var filteredEnumerated: [(offset: Int, cidr: String)] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pairs = Array(cidrs.enumerated().map { (offset: $0.offset, cidr: $0.element) })
        if f.isEmpty {
            return pairs
        }
        return pairs.filter { $0.cidr.lowercased().contains(f) }
    }

    private func copyVisible() {
        let text = filteredEnumerated.map(\.cidr).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: copyVisible) {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .animation(.default, value: copied)
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter prefixes", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .separatorColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            List(Array(filteredEnumerated), id: \.offset) { pair in
                Text(pair.cidr)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

// MARK: - Custom row (commit validated text on Return; invalid input is never saved)

private struct DestinationCidrRuleRow: View {
    let ruleID: UUID
    var controlsDisabled: Bool
    var editingLocked: Bool

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
                .opacity(controlsDisabled ? 0.4 : 1)

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this range")
            .disabled(editingLocked)
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
    var editingLocked: Bool
    @State private var confirmDelete = false
    @State private var copiedIPs = false
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
            .opacity(controlsDisabled ? 0.4 : 1)

            Spacer(minLength: 0)

            Button {
                if let r = rule() {
                    appState.domainResolutionCoordinator.forceResolve(id: r.id, domain: r.domain)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Refresh resolved IPs")
            .disabled(rule()?.status == .resolving)
            .opacity(controlsDisabled ? 0.4 : 1)

            Button { onBrowse() } label: {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .instantTooltip("View resolved IPs")

            Button {
                if let cidrs = rule()?.resolvedCidrs, !cidrs.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cidrs.joined(separator: "\n"), forType: .string)
                    copiedIPs = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedIPs = false
                    }
                }
            } label: {
                Image(systemName: copiedIPs ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .instantTooltip(copiedIPs ? "Copied!" : "Copy IP list")

            Button { confirmDelete = true } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .instantTooltip("Remove this domain")
            .disabled(editingLocked)
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove \"\(rule()?.domain ?? "")\"?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                appState.destinationRuleStore.removeDomainRule(id: ruleID)
            }
        }
    }
}
