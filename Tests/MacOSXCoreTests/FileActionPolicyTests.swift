import XCTest

@testable import MacOSXCore

final class FileActionPolicyTests: XCTestCase {
  func testRelevantOperations() {
    XCTAssertEqual(FileActionPolicy.operations(extension: "PDF"), [.pdfImages])
    XCTAssertEqual(
      FileActionPolicy.operations(extension: "HEIC"), [.jpeg, .png, .compress, .resize])
    XCTAssertEqual(FileActionPolicy.operations(extension: "doc"), [.markdown, .text])
    XCTAssertEqual(FileActionPolicy.operations(extension: "app"), [])
  }
  func testPageBoundsAndDeduplication() {
    XCTAssertEqual(FileActionPolicy.pages("1-3,2,5", count: 5), [0, 1, 2, 4])
    XCTAssertEqual(FileActionPolicy.pages("", count: 2), [0, 1])
    for value in ["0", "-1", "3-1", "1,", "1-99999999", "1--2", "9999999999999999999999"] {
      XCTAssertNil(FileActionPolicy.pages(value, count: 100))
    }
    XCTAssertNil(FileActionPolicy.pages("", count: 21))
    XCTAssertNil(FileActionPolicy.pages("1-21", count: 21))
  }
  func testCommandDoubleTapKeepsOrdinaryChordsOut() {
    XCTAssertTrue(
      ShortcutBinding(kind: .doubleModifier, keyCode: 55, modifiers: 0, keyLabel: "").isValid)
    var r = ModifierDoubleTap()
    XCTAssertFalse(r.update(keyCode: 55, eventFlags: 0x100008, timestamp: 1))
    XCTAssertFalse(r.update(keyCode: 55, eventFlags: 0, timestamp: 1.05))
    XCTAssertFalse(r.update(keyCode: 55, eventFlags: 0x100008, timestamp: 1.12))
    XCTAssertTrue(r.update(keyCode: 55, eventFlags: 0, timestamp: 1.17))
    r.reset()
    XCTAssertFalse(r.update(keyCode: 54, eventFlags: 0x100010, timestamp: 2))
    XCTAssertFalse(r.update(keyCode: 54, eventFlags: 0, timestamp: 2.4))
  }
}
