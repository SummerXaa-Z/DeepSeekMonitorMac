import XCTest
@testable import TokenMeter

final class ConfigProfileTests: XCTestCase {
    func testOptionalLayerOnlyProfilesAreSyncable() {
        let profiles = [
            makeProfile(key: "codex", commands: "2"),
            makeProfile(key: "claude", agents: "3"),
            makeProfile(key: "cursor", hooks: "1"),
        ]

        for profile in profiles {
            XCTAssertTrue(profile.hasSyncableLayer, "\(profile.key) should be syncable")
        }
    }

    func testEmptyProfileIsNotSyncable() {
        let profile = makeProfile(key: "cursor", agents: "—", hooks: "")

        XCTAssertFalse(profile.hasSyncableLayer)
    }

    private func makeProfile(
        key: String,
        commands: String? = nil,
        agents: String? = nil,
        hooks: String? = nil
    ) -> ConfigProfile {
        ConfigProfile(
            key: key,
            label: key,
            variant: "default",
            mcpState: "none",
            mcpCount: nil,
            hasRules: false,
            memory: "—",
            skills: "—",
            commands: commands,
            agents: agents,
            hooks: hooks,
            declaredWritableLayers: nil
        )
    }
}
