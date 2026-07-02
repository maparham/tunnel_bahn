import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LogsView: View {
    @ObservedObject var store: LogCaptureStore
    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var didCopy = false

    private var displayedEntries: [LogEntry] {
        guard !filterText.isEmpty else { return store.entries }
        let q = filterText.lowercased()
        return store.entries.filter {
            $0.message.lowercased().contains(q)
            || $0.category.lowercased().contains(q)
            || $0.subsystem.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            filterBar
            Divider()
            columnHeader
            Divider()
            logScrollView
        }
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Time")
                .frame(width: 88, alignment: .leading)
            Text("Source")
                .frame(width: 42, alignment: .leading)
            Text("Category")
                .frame(width: 100, alignment: .leading)
            Text("Message")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced).weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Logs")
                .font(.title2.weight(.semibold))
            Text("\(store.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Toggle(isOn: $autoScroll) {
                Label("Auto-scroll", systemImage: "arrow.down.to.line")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .instantTooltip(autoScroll ? "Auto-scroll on" : "Auto-scroll off")

            Button {
                copyAll()
            } label: {
                Label(didCopy ? "Copied" : "Copy All", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .animation(.easeInOut(duration: 0.15), value: didCopy)
            }
            .buttonStyle(.borderless)
            .disabled(store.entries.isEmpty)
            .instantTooltip("Copy all log lines to clipboard")

            Button {
                exportLogs()
            } label: {
                Label("Export", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.borderless)
            .disabled(store.entries.isEmpty)
            .instantTooltip("Save logs to a text file")

            Button(role: .destructive) {
                store.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(store.entries.isEmpty)
            .instantTooltip("Clear captured logs and restart from now")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.callout)
            TextField("Filter by message, category, or subsystem", text: $filterText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Log scroll view

    private var logScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if displayedEntries.isEmpty {
                        Text(store.entries.isEmpty ? "Waiting for log entries…" : "No entries match the filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(displayedEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("log-bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Key on the last entry's identity, not the count: once the ring-buffer cap is
            // hit (removeFirst on append) the count stops changing and auto-scroll would die.
            .onChange(of: store.entries.last?.id) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            .onChange(of: filterText) { _, _ in
                guard autoScroll else { return }
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
    }

    // MARK: - Actions

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.allText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .prefix(19)
        panel.nameFieldStringValue = "tunnelbahn-logs-\(stamp).txt"
        panel.allowedContentTypes = [UTType.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let text = self.store.allText
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Log entry row

private struct LogEntryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)

            SubsystemBadge(subsystem: entry.subsystem)

            Text(entry.category)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.level.logLevelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - Subsystem badge

private struct SubsystemBadge: View {
    let subsystem: String

    private var config: (label: String, color: Color) {
        switch subsystem {
        case AppConstants.primaryBundleID:
            return ("App", .secondary)
        case "\(AppConstants.primaryBundleID).networkextension":
            return ("NE", .blue)
        case "\(AppConstants.primaryBundleID).transparentproxy":
            return ("Proxy", .purple)
        default:
            return (String(subsystem.split(separator: ".").last ?? "?"), .gray)
        }
    }

    var body: some View {
        Text(config.label)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(config.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(config.color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .frame(width: 42, alignment: .leading)
    }
}

// MARK: - Level color

private extension String {
    var logLevelColor: Color {
        switch self {
        case "debug": return .secondary
        case "info": return Color(nsColor: .labelColor)
        case "notice": return .accentColor
        case "warning": return .yellow
        case "error": return .orange
        case "critical", "fault": return .red
        default: return Color(nsColor: .labelColor)
        }
    }
}
