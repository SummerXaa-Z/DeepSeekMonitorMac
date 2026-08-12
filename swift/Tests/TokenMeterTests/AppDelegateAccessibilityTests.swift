import AppKit
import XCTest
@testable import TokenMeter

final class AppDelegateAccessibilityTests: XCTestCase {
    @MainActor
    func testStatusButtonHasStableAccessibilityMetadata() throws {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }

        let button = try XCTUnwrap(item.button)
        AppDelegate.configureStatusButton(button)

        XCTAssertEqual(button.toolTip, "TokenMeter")
        XCTAssertEqual(button.accessibilityLabel(), "TokenMeter")
        XCTAssertEqual(button.accessibilityHelp(), "打开 TokenMeter 用量面板")
        XCTAssertEqual(button.accessibilityIdentifier(), "TokenMeter.StatusItem")
        XCTAssertEqual(button.image?.isTemplate, true)
    }
}
