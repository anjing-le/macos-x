import XCTest
@testable import MacOSXCore

final class ShortcutBindingTests: XCTestCase {
    func testConflictDoesNotDependOnKeyboardLayoutLabel() {
        let a = ShortcutBinding(keyCode: 1, modifiers: 5, keyLabel: "S")
        let b = ShortcutBinding(keyCode: 1, modifiers: 5, keyLabel: "Ы")
        XCTAssertTrue(a.conflicts(with: b))
        XCTAssertFalse(a.conflicts(with: .init(keyCode: 1, modifiers: 1, keyLabel: "S")))
        XCTAssertFalse(a.conflicts(with: .init(kind: .doubleModifier, keyCode: 61, modifiers: 0, keyLabel: "")))
    }
    func testBareTypingAndLoneModifierAreNotGlobalShortcuts() {
        XCTAssertFalse(ShortcutBinding(keyCode: 1, modifiers: 0, keyLabel: "S").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 1, modifiers: 4, keyLabel: "S").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 61, modifiers: 2, keyLabel: "Option").isValid)
        XCTAssertTrue(ShortcutBinding(kind: .doubleModifier, keyCode: 61, modifiers: 0, keyLabel: "").isValid)
    }
    func testTwoCompleteTapsAndNoTripleRetrigger() {
        var r = ModifierDoubleTap()
        XCTAssertFalse(r.update(isDown: true, timestamp: 1))
        XCTAssertFalse(r.update(isDown: false, timestamp: 1.05))
        XCTAssertFalse(r.update(isDown: true, timestamp: 1.18))
        XCTAssertTrue(r.update(isDown: false, timestamp: 1.23))
        XCTAssertFalse(r.update(isDown: true, timestamp: 1.3))
        XCTAssertFalse(r.update(isDown: false, timestamp: 1.35))
    }
    func testHoldInterruptionAndClockRegressionCannotSummon() {
        var r = ModifierDoubleTap()
        _ = r.update(isDown: true, timestamp: 1)
        XCTAssertFalse(r.update(isDown: false, timestamp: 1.8))
        _ = r.update(isDown: true, timestamp: 2)
        _ = r.update(isDown: false, timestamp: 2.05)
        r.reset()
        _ = r.update(isDown: true, timestamp: 2.1)
        XCTAssertFalse(r.update(isDown: false, timestamp: 2.15))
        _ = r.update(isDown: true, timestamp: 0)
        XCTAssertFalse(r.update(isDown: false, timestamp: 0.05))
    }
}
