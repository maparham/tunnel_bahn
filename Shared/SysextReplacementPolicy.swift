import Foundation

/// Decides whether an OSSystemExtension activation request should replace the installed
/// (possibly running) extension. Replacing a running extension tears down its live NE
/// sessions: a connected packet tunnel dies, while the transparent proxy re-activates and
/// keeps capturing flows with no tunnel behind them — a system-wide blackhole on every app
/// launch. Identical version+build means the installed copy IS this build, so the running
/// extension must be left alone. The build number is auto-bumped per build (see
/// tools/autobump-build-number.sh), so every new build still redeploys.
enum SysextReplacementPolicy {
    static func shouldReplace(
        existingVersion: String,
        existingBuild: String,
        candidateVersion: String,
        candidateBuild: String
    ) -> Bool {
        !(existingVersion == candidateVersion && existingBuild == candidateBuild)
    }
}
