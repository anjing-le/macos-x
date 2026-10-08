import AppKit

@main struct EditorRegression {
    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let context = CaptureRaster.context(width: 200, height: 160)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let image = context.makeImage()!
        let region = CGRect(x: 20, y: 40, width: 100, height: 80)
        let editor = CaptureEditor(image: image, selectionFrame: region)
        var states = [Bool]()
        editor.onEditingChanged = { states.append($0) }
        func key(_ code: UInt16, _ character: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code)!
        }
        precondition((editor.window.contentView as! CaptureCanvas).tool == nil, "Initial selection must have no annotation tool")
        precondition(editor.handleSelectionKey(key(18, "1")))
        precondition(states.last == true && !editor.window.ignoresMouseEvents, "Selecting rectangle gives drawing input to editor")
        precondition(editor.handleSelectionKey(key(18, "1")))
        precondition(states.last == false && editor.window.ignoresMouseEvents, "Clicking current tool again restores selection adjustment")
        precondition(editor.handleSelectionKey(key(19, "2")))
        precondition(states.last == true, "Arrow also locks selection while drawing")
        precondition(editor.handleSelectionKey(key(53, "\u{1b}")))
        precondition(states.last == false && editor.window.ignoresMouseEvents, "Leaving annotation restores draggable selection rather than closing")
        let before = editor.selectionFrame
        editor.beginRegionAdjustment()
        precondition(!editor.handleSelectionKey(key(18, "1")), "Pending crop cannot start a drawing tool")
        let next = before.offsetBy(dx: 20, dy: 10)
        editor.replaceSelectionImage(image, at: next)
        precondition(editor.selectionFrame == next && states.last == false, "Updated crop stays adjustable")
        precondition(!editor.window.isVisible, "Regression must not display windows")
        editor.close()
        let pin = CaptureEditor(image: image, selectionFrame: region, editingPin: true)
        pin.beginRegionAdjustment(); pin.replaceSelectionImage(image, at: next)
        precondition(pin.selectionFrame == region, "Pinned-image editing cannot recrop the desktop")
        pin.close()
        print("PASS editor interaction: default adjustment, tool lock/toggle, Esc, pending crop, region replacement and pin isolation; no displayed windows, capture or clipboard writes")
    }
}
