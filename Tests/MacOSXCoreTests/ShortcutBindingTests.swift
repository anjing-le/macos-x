import XCTest
@testable import MacOSXCore

final class ShortcutBindingTests: XCTestCase {
    func testCaptureWhileHoldingSwitcherCommandKeepsOtherModifiersExact() {
        let capture = ShortcutBinding(keyCode: 122, modifiers: 0, keyLabel: "F1")
        XCTAssertTrue(capture.matches(keyCode: 122, modifiers: 8, ignoringHeldCommand: true))
        XCTAssertFalse(capture.matches(keyCode: 122, modifiers: 8))
        XCTAssertFalse(capture.matches(keyCode: 122, modifiers: 12, ignoringHeldCommand: true))
        XCTAssertFalse(capture.matches(keyCode: 99, modifiers: 8, ignoringHeldCommand: true))
        let custom = ShortcutBinding(keyCode: 0, modifiers: 5, keyLabel: "A")
        XCTAssertTrue(custom.matches(keyCode: 0, modifiers: 13, ignoringHeldCommand: true))
        XCTAssertFalse(custom.matches(keyCode: 0, modifiers: 9, ignoringHeldCommand: true))
    }
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
    func testFunctionKeysAllowSnippingWithoutInterceptingBareTyping() {
        XCTAssertTrue(ShortcutBinding(keyCode: 122, modifiers: 0, keyLabel: "F1").isValid)
        XCTAssertTrue(ShortcutBinding(keyCode: 99, modifiers: 4, keyLabel: "F3").isValid)
        XCTAssertTrue(ShortcutBinding(keyCode: 90, modifiers: 0, keyLabel: "F20").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 36, modifiers: 0, keyLabel: "Return").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 0, modifiers: 4, keyLabel: "A").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 127, modifiers: 0, keyLabel: "F1").isValid)
        XCTAssertFalse(ShortcutBinding(keyCode: 99, modifiers: 0, keyLabel: "F3")
            .conflicts(with: .init(keyCode: 99, modifiers: 4, keyLabel: "F3")))
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
