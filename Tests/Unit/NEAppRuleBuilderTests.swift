import NetworkExtension
import XCTest

final class NEAppRuleBuilderTests: XCTestCase {
    // MARK: - signingIdentifier(forExecutableAtPath:)

    func testSigningIdentifierForSystemCLIBinary() {
        // /bin/ls is a bare Mach-O with no Info.plist; its signing identifier is stable.
        XCTAssertEqual(NEAppRuleBuilder.signingIdentifier(forExecutableAtPath: "/bin/ls"), "com.apple.ls")
    }

    func testSigningIdentifierForMissingPathReturnsNil() {
        XCTAssertNil(NEAppRuleBuilder.signingIdentifier(forExecutableAtPath: "/nonexistent/binary"))
    }

    // MARK: - build(from:) with a bare executable rule

    func testBuildUsesSigningIdentifierForBareExecutable() {
        let rule = AppRule(
            displayName: "ls",
            bundleIdentifier: "com.apple.ls",
            appPath: "/bin/ls",
            action: .routeVPN
        )
        let built = NEAppRuleBuilder.build(from: [rule], log: { _ in })
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.matchSigningIdentifier, "com.apple.ls")
        // System binaries carry a designated requirement; the builder must pick it up
        // instead of the anchor-apple-generic fallback.
        XCTAssertEqual(built.first?.matchDesignatedRequirement.isEmpty, false)
    }

    func testBuildSigningOnlyRuleWithoutOnDiskPath() {
        let id = "com.anthropic.claude-code"
        let rule = AppRule(
            displayName: "claude-code",
            bundleIdentifier: id,
            appPath: AppRule.signingOnlyPath(for: id),
            action: .routeVPN
        )
        let built = NEAppRuleBuilder.build(from: [rule], log: { _ in })
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built.first?.matchSigningIdentifier, id)
        // No Apple anchor: a signing-only rule has no on-disk path, so the real designated
        // requirement cannot be read, and requiring an Apple anchor would exclude the
        // ad-hoc signed CLI binaries this code path exists to serve.
        XCTAssertEqual(
            built.first?.matchDesignatedRequirement,
            #"identifier "com.anthropic.claude-code""#
        )
    }

    /// A path-based rule whose binary is missing (unmounted volume, moved bundle) must NOT
    /// degrade to the anchor-free signing-only form: a bare `identifier "X"` requirement is
    /// satisfiable by any locally ad-hoc-signed binary claiming that identifier, which would
    /// route an impostor's traffic through the VPN as if it were the app.
    func testMissingPathRuleKeepsAppleAnchor() {
        let rule = AppRule(
            displayName: "Gone",
            bundleIdentifier: "com.example.gone",
            appPath: "/Volumes/Missing/Gone.app",
            action: .routeVPN
        )
        let built = NEAppRuleBuilder.build(from: [rule], log: { _ in })
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(
            built.first?.matchDesignatedRequirement,
            #"anchor apple generic and identifier "com.example.gone""#
        )
    }

    func testBuildSkipsBypassRules() {
        let rule = AppRule(
            displayName: "ls",
            bundleIdentifier: "com.apple.ls",
            appPath: "/bin/ls",
            action: .bypass
        )
        XCTAssertTrue(NEAppRuleBuilder.build(from: [rule], log: { _ in }).isEmpty)
    }

    // MARK: - Ad-hoc signed binaries

    /// Establishes the premise of the next test: `anchor apple generic` demands a
    /// certificate chain to an Apple root, and an ad-hoc signature has no chain at all.
    /// Any rule carrying that anchor therefore excludes ad-hoc signed binaries outright.
    func testAppleAnchorRequirementNeverMatchesAdHocSignedBinary() throws {
        let (path, identifier) = try makeAdHocSignedBinary(identifier: "com.example.adhoc-anchor")
        XCTAssertTrue(
            codeAtPath(path, satisfies: #"identifier "\#(identifier)""#),
            "sanity: the bare identifier requirement must match the binary we just signed"
        )
        XCTAssertFalse(
            codeAtPath(path, satisfies: #"anchor apple generic and identifier "\#(identifier)""#),
            "an ad-hoc signature has no Apple anchor, so this requirement cannot match"
        )
    }

    /// The reported bug: a Tunnel-Monitor rule (signing identifier only, no on-disk path)
    /// must produce a requirement that actually matches the binary it names, including
    /// when that binary is ad-hoc signed. Previously it emitted an Apple anchor, so the
    /// NEAppRule was well-formed but matched nothing and traffic silently bypassed the VPN.
    func testSigningOnlyRuleRequirementMatchesAdHocSignedBinary() throws {
        let (path, identifier) = try makeAdHocSignedBinary(identifier: "com.example.adhoc-tool")
        let rule = AppRule(
            displayName: "adhoc-tool",
            bundleIdentifier: identifier,
            appPath: AppRule.signingOnlyPath(for: identifier),
            action: .routeVPN
        )
        let built = NEAppRuleBuilder.build(from: [rule], log: { _ in })
        let requirement = try XCTUnwrap(built.first?.matchDesignatedRequirement)
        XCTAssertTrue(
            codeAtPath(path, satisfies: requirement),
            "generated requirement \(requirement) does not match the ad-hoc binary it targets"
        )
    }

    // MARK: - Requirement string safety

    /// The identifier is interpolated into the code-requirement language. One containing a
    /// quote would produce a requirement that fails to compile, and the resulting rule
    /// would silently match nothing; the builder must drop it and say so instead.
    func testRuleWithUnsafeIdentifierIsSkippedAndLogged() {
        let rule = AppRule(
            displayName: "evil",
            bundleIdentifier: #"com.example.evil" or anchor apple generic and identifier "x"#,
            appPath: AppRule.signingOnlyPath(for: "evil"),
            action: .routeVPN
        )
        var logged: [String] = []
        let built = NEAppRuleBuilder.build(from: [rule], log: { logged.append($0) })
        XCTAssertTrue(built.isEmpty, "a rule whose identifier cannot be expressed safely must not be emitted")
        XCTAssertTrue(logged.contains { $0.contains("unsafe") }, "the skip must be logged; got \(logged)")
    }

    /// Every requirement the builder emits must be a compilable requirement. This is the
    /// backstop that turns any future malformed string into a test failure rather than a
    /// rule that is silently inert at runtime.
    func testAllGeneratedRequirementsCompile() {
        let rules = [
            AppRule(displayName: "ls", bundleIdentifier: "com.apple.ls", appPath: "/bin/ls", action: .routeVPN),
            AppRule(
                displayName: "claude-code",
                bundleIdentifier: "com.anthropic.claude-code",
                appPath: AppRule.signingOnlyPath(for: "com.anthropic.claude-code"),
                action: .routeVPN
            ),
        ]
        let built = NEAppRuleBuilder.build(from: rules, log: { _ in })
        XCTAssertFalse(built.isEmpty)
        for rule in built {
            var requirement: SecRequirement?
            let status = SecRequirementCreateWithString(
                rule.matchDesignatedRequirement as CFString, SecCSFlags(), &requirement
            )
            XCTAssertEqual(
                status, errSecSuccess,
                "requirement does not compile for \(rule.matchSigningIdentifier): \(rule.matchDesignatedRequirement)"
            )
        }
    }

    // MARK: - Helpers

    /// Copies a system binary into a temp dir and re-signs it ad-hoc under `identifier`,
    /// producing a signature with no certificate chain — the shape of a locally built CLI tool.
    private func makeAdHocSignedBinary(identifier: String) throws -> (path: String, identifier: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("adhoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: binary)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-f", "-s", "-", "--identifier", identifier, binary.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "codesign unavailable; cannot build an ad-hoc fixture")

        let readBack = NEAppRuleBuilder.signingIdentifier(forExecutableAtPath: binary.path)
        XCTAssertEqual(readBack, identifier, "fixture did not take the requested signing identifier")
        return (binary.path, identifier)
    }

    /// Whether the code at `path` satisfies `requirement`, as the NE flow matcher would evaluate it.
    private func codeAtPath(_ path: String, satisfies requirement: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, SecCSFlags(), &parsed) == errSecSuccess,
              let parsed
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), parsed) == errSecSuccess
    }
}
