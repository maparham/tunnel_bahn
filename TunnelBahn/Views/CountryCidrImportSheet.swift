import SwiftUI

/// Pick a country; its aggregated IPv4 prefixes are downloaded and handed back as plain text
/// for the regular bulk-list import path.
struct CountryCidrImportSheet: View {
    /// Called on the main actor with the validated prefixes and the chosen country.
    let onImport: (_ cidrs: [String], _ country: CountryCidrListEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var selection: String?
    @State private var isDownloading = false
    @State private var errorMessage: String?
    /// Held so Cancel (and dismissal) actually stops the download. An unstructured Task outlives
    /// the sheet, so without this a cancelled import still lands once the bytes arrive.
    @State private var downloadTask: Task<Void, Never>?

    private let countries = CountryCidrListSource.allCountries()

    private var filtered: [CountryCidrListEntry] {
        let f = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return countries }
        return countries.filter {
            $0.name.localizedCaseInsensitiveContains(f) || $0.code.localizedCaseInsensitiveContains(f)
        }
    }

    private var selectedEntry: CountryCidrListEntry? {
        countries.first { $0.code == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import country IP ranges").font(.headline)
                Spacer()
                Button("Cancel") { cancelAndDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { startImport(selectedEntry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedEntry == nil || isDownloading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search countries", text: $filter)
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

            List(filtered, selection: $selection) { entry in
                HStack {
                    Text(entry.name)
                    Spacer()
                    Text(entry.code)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .tag(entry.code)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    selection = entry.code
                    startImport(entry)
                }
            }
            .disabled(isDownloading)

            Divider()

            HStack(spacing: 8) {
                if isDownloading {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(selectedEntry?.name ?? "")…")
                        .foregroundStyle(.secondary)
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("IPv4 ranges from the ipverse/rir-ip project on GitHub, aggregated per country.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 440, idealHeight: 520)
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private func cancelAndDismiss() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        dismiss()
    }

    private func startImport(_ entry: CountryCidrListEntry?) {
        guard let entry, !isDownloading else { return }
        isDownloading = true
        errorMessage = nil
        downloadTask = Task {
            do {
                let cidrs = try await CountryCidrListSource.fetchPrefixes(forCountryCode: entry.code)
                guard !Task.isCancelled else { return }
                isDownloading = false
                onImport(cidrs, entry)
                dismiss()
            } catch {
                // A cancelled download is the user closing the sheet, not a failure to report.
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                isDownloading = false
                errorMessage = Self.describe(error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        CountryCidrListRefresher.describe(error)
    }
}
