import SwiftUI

/// Displays the git build stamp the host app was compiled from.
///
/// Drop this anywhere you surface app info (e.g. an About box, a Settings
/// footer, or the menu-bar popover footer):
///
///     BuildStampView()
///
/// For a dev loop the value is `BuildInfo.stamp`, e.g. "555c587+dirty".
/// A "+dirty" suffix means the binary was built from an uncommitted working
/// tree — i.e. it may not match any commit.
struct BuildStampView: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: BuildInfo.dirty ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .foregroundStyle(BuildInfo.dirty ? .orange : .secondary)
            Text("build \(BuildInfo.stamp)")
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .instantTooltip("commit \(BuildInfo.commit) • \(BuildInfo.branch) • built \(Self.builtAtLocal)\(BuildInfo.dirty ? " • uncommitted changes" : "")")
    }

    /// `BuildInfo.builtAt` is stored as UTC (e.g. "2026-05-31T21:18:27Z").
    /// Render it in the viewer's local timezone as "dd.MM.yyyy, HH:mm",
    /// falling back to the raw UTC string if it ever fails to parse.
    private static let builtAtLocal: String = {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: BuildInfo.builtAt) else { return BuildInfo.builtAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter.string(from: date)
    }()
}
