import AppKit
import MacOSXCore

extension Check {
    @MainActor static func checkPromptPreviews() throws {
        var collection = PromptCollection(legacy: [])
        collection.prompts = (1...24).map {
            LibraryPrompt(id: "preview-\($0)", title: "办公 \($0)", content: "正文 \($0)")
        }
        collection.prompts[0].content = String(repeating: "第一段是正文摘要，复制仍保留完整内容。\n", count: 30)
        collection.slots = collection.prompts.prefix(10).map { Optional($0.id) }

        func label(_ view: PromptWheelView, _ identifier: String) -> NSTextField {
            view.subviews.first { $0.identifier?.rawValue == identifier } as! NSTextField
        }
        func layout(_ view: PromptWheelView) {
            view.frame.size = view.preferredSize; view.layoutSubtreeIfNeeded()
        }
        func query(_ text: String, in view: PromptWheelView) {
            view.search.stringValue = text
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.search))
            layout(view)
        }
        func rows(_ view: PromptWheelView) -> [NSButton] {
            view.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.hasPrefix("办公") }
        }
        func command(_ selector: Selector, in view: PromptWheelView, textView: NSTextView? = nil) {
            precondition(view.control(view.search, textView: textView ?? NSTextView(), doCommandBy: selector))
            layout(view)
        }
        func body(_ view: PromptWheelView, matches index: Int) {
            let preview = label(view, "prompt-body-preview")
            let heading = label(view, "prompt-preview-heading")
            precondition(!preview.isHidden && !heading.isHidden, "List selection has an explicit title and body summary")
            precondition(preview.stringValue == String(collection.prompts[index].content.prefix(400)))
            precondition(heading.stringValue == collection.prompts[index].title)
            precondition(view.bounds.contains(preview.frame) && view.bounds.contains(heading.frame))
            precondition(!preview.frame.intersects(view.search.frame) && !heading.frame.intersects(view.search.frame))
            for row in rows(view) {
                precondition(!row.frame.intersects(preview.frame) && !row.frame.intersects(heading.frame), "Body summaries do not cover selectable rows")
            }
        }
        func bounded(_ view: PromptWheelView) {
            precondition(view.subviews.filter { !$0.isHidden }.allSatisfy { view.bounds.contains($0.frame) }, "Native controls and summaries stay inside the available view")
        }
        func enter(_ row: NSButton) {
            let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            row.mouseEntered(with: event)
        }

        let list = PromptWheelView(size: CGSize(width: 360, height: 360), collection: collection, presentation: .init(style: .list))
        layout(list); bounded(list); body(list, matches: 0)
        precondition(rows(list).count == 10 && label(list, "prompt-body-preview").maximumNumberOfLines == 3)
        precondition(collection.prompts[0].content.count > label(list, "prompt-body-preview").stringValue.count, "Only the displayed summary is bounded")
        command(#selector(NSResponder.moveDown(_:)), in: list); body(list, matches: 1)
        enter(rows(list)[4]); layout(list); body(list, matches: 4)
        precondition(rows(list).filter { $0.state == .on }.map(\.title) == ["办公 5"], "Mouse entry and keyboard selection share one selected row")
        query("办公", in: list)
        for _ in 0..<12 { command(#selector(NSResponder.moveDown(_:)), in: list) }
        body(list, matches: 12); bounded(list)
        precondition(rows(list).contains { $0.title == "办公 13" && $0.state == .on })
        query("不存在", in: list)
        precondition(label(list, "prompt-body-preview").isHidden && label(list, "prompt-preview-heading").isHidden)
        precondition(rows(list).isEmpty, "Empty searches never leave an old row or body visible")
        query("", in: list); body(list, matches: 0)
        precondition(rows(list).count == 10 && list.search.stringValue.isEmpty)
        var copied = [Int]()
        list.onChoose = { copied.append($0) }
        let marked = NSTextView()
        marked.setMarkedText("办公", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(marked.hasMarkedText())
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.cancelOperation(_:))] {
            precondition(!list.control(list.search, textView: marked, doCommandBy: selector), "Composition commands belong to the input method")
        }
        precondition(copied.isEmpty); body(list, matches: 0)
        marked.unmarkText()
        command(#selector(NSResponder.insertNewline(_:)), in: list, textView: marked)
        command(#selector(NSResponder.insertNewline(_:)), in: list, textView: marked)
        precondition(copied == [0], "Repeated Enter submits the selected source prompt once")
        list.finish()

        let small = PromptWheelView(size: CGSize(width: 220, height: 200), collection: collection, presentation: .init(style: .list))
        layout(small); bounded(small); body(small, matches: 0)
        precondition(small.preferredSize.width <= 220 && small.preferredSize.height <= 200 && rows(small).count == 2)
        let next = small.subviews.compactMap { $0 as? NSButton }.first { $0.title == "›" }!
        precondition(!next.isHidden)
        next.performClick(nil); layout(small); body(small, matches: 2); bounded(small)
        enter(rows(small)[1]); layout(small); body(small, matches: 3)
        query("办公", in: small)
        command(#selector(NSResponder.moveUp(_:)), in: small); body(small, matches: 23); bounded(small)
        precondition(rows(small).contains { $0.title == "办公 24" && $0.state == .on } && small.search.stringValue == "办公")
        query("正文", in: small)
        precondition(rows(small).isEmpty && label(small, "prompt-body-preview").isHidden, "Searching still matches titles rather than preview body text")
        var smallCopied = [Int](); small.onChoose = { smallCopied.append($0) }
        command(#selector(NSResponder.insertNewline(_:)), in: small)
        precondition(smallCopied.isEmpty)
        query("", in: small); body(small, matches: 0); bounded(small)
        command(#selector(NSResponder.moveDown(_:)), in: small)
        command(#selector(NSResponder.insertNewline(_:)), in: small)
        command(#selector(NSResponder.insertNewline(_:)), in: small)
        precondition(smallCopied == [1]); small.finish()

        for dimension: CGFloat in [280, 300, 360] {
            let wheel = PromptWheelView(size: CGSize(width: dimension, height: dimension), collection: collection, presentation: .init())
            let window = NSWindow(contentRect: wheel.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false; window.contentView = wheel
            layout(wheel)
            let ring = wheel.subviews.compactMap { $0 as? PromptRingView }.first!
            let card = ring.subviews.compactMap { $0 as? NSButton }.first { $0.tag == 0 && !$0.isHidden }!
            let point = wheel.convert(CGPoint(x: dimension / 2, y: dimension - 40), to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
            card.mouseMoved(with: event); layout(wheel)
            let preview = label(wheel, "prompt-body-preview")
            precondition(!preview.isHidden && preview.stringValue == String(collection.prompts[0].content.prefix(400)))
            precondition(card.state == .on && abs(wheel.search.frame.midY - wheel.bounds.midY) < 1)
            precondition(!preview.frame.intersects(wheel.search.frame), "Ring body summaries stay below the centred search")
            let center = CGPoint(x: wheel.bounds.midX, y: wheel.bounds.midY)
            let inner = (dimension / 2 - 12) * 0.53
            for frame in [wheel.search.frame, preview.frame] {
                for point in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.maxY)] {
                    precondition(hypot(point.x-center.x, point.y-center.y) <= inner + 0.6, "Ring controls remain inside the centre instead of covering sectors")
                }
            }
            bounded(wheel)
            wheel.finish(); window.close()
        }
        print("PASS: prompt body summaries follow mouse/keyboard without altering source content, native list/footer bounds, small-screen paging, title-only search, empty/clear restore, IME Enter and one-shot selection; ring centre bounds at 280/300/360 pt")
    }
}
