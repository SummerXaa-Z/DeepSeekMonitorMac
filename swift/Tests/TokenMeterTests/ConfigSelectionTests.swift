import XCTest
@testable import TokenMeter

final class ConfigSelectionTests: XCTestCase {
    func testSyncableProfilesHideEmptyProfiles() {
        let profiles = [
            makeProfile(key: "claude", hasRules: true),
            makeProfile(key: "zed"),
            makeProfile(key: "qoder", commands: "1"),
        ]

        let visible = ConfigSelection.syncableProfiles(profiles).map(\.key)

        XCTAssertEqual(visible, ["claude", "qoder"])
    }

    func testValidTargetsExcludeSourceAndUnsyncableProfiles() {
        let profiles = [
            makeProfile(key: "claude", hasRules: true),
            makeProfile(key: "codex", hasRules: true),
            makeProfile(key: "cursor"),
        ]
        let selected: Set<String> = ["claude", "codex", "cursor", "missing"]

        let targets = ConfigSelection.validTargets(
            selected,
            profiles: profiles,
            source: "claude",
            layers: ["rules"]
        )

        XCTAssertEqual(targets, ["codex"])
    }

    func testAvailableLayersMatchTheSelectedSource() {
        let profiles = [
            makeProfile(key: "claude", hasRules: true, commands: "2", hooks: "1"),
            makeProfile(key: "codex", commands: "3"),
        ]

        XCTAssertEqual(
            ConfigSelection.availableLayers(for: "claude", profiles: profiles),
            ["rules", "commands", "hooks"]
        )
        XCTAssertEqual(ConfigSelection.availableLayers(for: "missing", profiles: profiles), [])
    }

    func testValidLayersDiscardLayersRemovedFromTheSourceAfterRefresh() {
        let refreshedProfiles = [
            makeProfile(key: "claude", mcpState: "present", mcpCount: 1),
        ]

        let valid = ConfigSelection.validLayers(
            ["mcp", "rules"],
            for: "claude",
            profiles: refreshedProfiles
        )

        XCTAssertEqual(valid, ["mcp"])
    }

    func testDeclaredWritableLayersKeepAbsentMCPCreateTargetAndFilterPartialTargets() {
        let profiles = [
            makeProfile(key: "source", mcpState: "present", mcpCount: 1, hasRules: true),
            makeProfile(key: "empty-mcp", mcpState: "absent", writableLayers: ["mcp"]),
            makeProfile(key: "mcp-only", mcpState: "present", mcpCount: 1, writableLayers: ["mcp"]),
            makeProfile(key: "blocked", hasRules: true, writableLayers: []),
        ]

        let mcpTargets = ConfigSelection.targetableProfiles(
            profiles,
            source: "source",
            layers: ["mcp"]
        ).map(\.key)
        let combinedTargets = ConfigSelection.targetableProfiles(
            profiles,
            source: "source",
            layers: ["mcp", "rules"]
        ).map(\.key)

        XCTAssertEqual(mcpTargets, ["empty-mcp", "mcp-only"])
        XCTAssertEqual(combinedTargets, [])
        XCTAssertEqual(
            ConfigSelection.validTargets(
                ["empty-mcp", "mcp-only", "blocked"],
                profiles: profiles,
                source: "source",
                layers: ["mcp"]
            ),
            ["empty-mcp", "mcp-only"]
        )
        XCTAssertEqual(
            ConfigSelection.validTargets(
                ["empty-mcp", "mcp-only"],
                profiles: profiles,
                source: "source",
                layers: ["mcp", "rules"]
            ),
            []
        )
    }

    private func makeProfile(
        key: String,
        mcpState: String = "none",
        mcpCount: Int? = nil,
        hasRules: Bool = false,
        skills: String = "—",
        commands: String? = nil,
        agents: String? = nil,
        hooks: String? = nil,
        writableLayers: [String]? = nil
    ) -> ConfigProfile {
        ConfigProfile(
            key: key,
            label: key,
            variant: "default",
            mcpState: mcpState,
            mcpCount: mcpCount,
            hasRules: hasRules,
            memory: "—",
            skills: skills,
            commands: commands,
            agents: agents,
            hooks: hooks,
            declaredWritableLayers: writableLayers
        )
    }
}
