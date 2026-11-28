import AppKit

@MainActor private extension MenuBarController {
    func verifyAboutMenu() -> Bool {
        let entries = menu.items.filter { $0.action == #selector(showAbout) }
        precondition(entries.count == 1 && entries[0].title == AppLanguage.text("关于 macos-x"))
        return NSApp.sendAction(entries[0].action!, to: entries[0].target, from: entries[0])
    }
    func verifyFileFeedbackJourney() {
        var cancelled=0,revealed=0
        onCancelFileActions={ cancelled += 1 };onRevealFileActions={ revealed += 1 }
        let source=URL(fileURLWithPath:"/fixture/source.png"),result=URL(fileURLWithPath:"/fixture/source.jpg")
        let root=menu, rows=root.items.map(ObjectIdentifier.init)
        updateFileActions(FileActionFeedback(phase:.processing,input:source))
        precondition(unreadFileFeedback == false && !fileHeader.isHidden && !fileCancel.isHidden)
        precondition(fileCancel.title == AppLanguage.text("取消") && validateMenuItem(fileCancel))
        precondition(NSApp.sendAction(fileCancel.action!,to:fileCancel.target,from:fileCancel) && cancelled == 1)
        let done=FileActionFeedback(phase:.completed,input:source,output:result)
        updateFileActions(done)
        precondition(unreadFileFeedback && fileDetail.title == "source.jpg" && !fileReveal.isHidden)
        precondition(revealed == 0,"Completion cannot launch Finder automatically")
        precondition(NSApp.sendAction(fileReveal.action!,to:fileReveal.target,from:fileReveal) && revealed == 1)
        menuWillOpen(root)
        precondition(!unreadFileFeedback && fileFeedback == done,"Reading the menu acknowledges the badge but retains the result")
        menuDidClose(root); updateFileActions(done)
        precondition(!unreadFileFeedback,"Unchanged feedback cannot recreate an acknowledged badge")
        updateFileActions(FileActionFeedback(phase:.failed,input:source,message:"failure reason"))
        precondition(unreadFileFeedback && fileDetail.title == "failure reason" && fileReveal.isHidden && fileCancel.isHidden)
        updateFileActions(FileActionFeedback(phase:.processing,input:source)); menuWillOpen(root)
        updateFileActions(done)
        precondition(!fileCancel.isHidden && !fileCancel.isEnabled && !fileReveal.isHidden && !validateMenuItem(fileCancel),
                     "Completion disables the existing cancel row instead of replacing the action under the pointer")
        menuDidClose(root); precondition(fileCancel.isHidden)
        precondition(rows == root.items.map(ObjectIdentifier.init),"Status updates preserve the existing menu and row identities")
        updateFileActions(FileActionFeedback(phase:.processing,input:source)); menuWillOpen(root)
        updateFileActions(nil)
        precondition(fileHeader.isHidden && fileDetail.isHidden && fileCancel.isHidden && fileReveal.isHidden && fileSeparator.isHidden)
        precondition(!retainCancelRow,"Disabling during a tracked task menu clears reserved controls as well as its badge")
        menuDidClose(root)
        let hover=MenuBarHoverView(frame:CGRect(x:0,y:0,width:30,height:24))
        func pixels(_ phase:FileActionFeedback.Phase?)->Data {
            hover.feedbackPhase=phase
            let image=hover.bitmapImageRepForCachingDisplay(in:hover.bounds)!
            hover.cacheDisplay(in:hover.bounds,to:image)
            return image.representation(using:.png,properties:[:])!
        }
        let empty=pixels(nil),processing=pixels(.processing),success=pixels(.completed),failure=pixels(.failed)
        precondition(empty != processing && success != failure && empty == pixels(nil),"Actual offscreen badge pixels change and clear")
        precondition(hover.hitTest(CGPoint(x:25,y:5)) == nil && hover.frame.width == 30,"Badge never intercepts native clicks or changes the apple boundary")
        print("PASS quiet file feedback: live stable menu rows, cancel, explicit Finder, failure detail, unread acknowledgement and actual badge pixels; no status item or popup")
    }
}

@main struct MenuBarRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        var opened = 0, checked = 0, quit = 0, available = false
        let controller = MenuBarController(onOpen: { opened += 1 }, onCheckUpdates: { checked += 1 },
                                          canCheckUpdates: { available }, onQuit: { quit += 1 })
        func click(_ count: Int, type: NSEvent.EventType = .leftMouseUp) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
        }
        var drawerClicks = 0
        controller.onSingleClick = { drawerClicks += 1 }
        controller.handleClick(click(1), now: 10)
        precondition(opened == 0, "Single click must not raise the main window")
        controller.handleClick(click(1), now: 10 + NSEvent.doubleClickInterval / 2)
        precondition(drawerClicks == 1, "Apple single click can toggle its drawer without firing a second time on double click")
        precondition(opened == 1 && checked == 0 && quit == 0, "Two status actions with count one must open exactly once without other actions")
        controller.handleClick(click(1), now: 20)
        controller.handleClick(click(1), now: 20 + NSEvent.doubleClickInterval + 1)
        precondition(opened == 1, "Slow separate clicks must not open the window")
        controller.stop()
        controller.handleClick(click(1, type: .leftMouseDown), now: 30)
        controller.handleClick(click(1, type: .leftMouseDown), now: 30 + NSEvent.doubleClickInterval / 2)
        precondition(opened == 2, "Tracked button actions with mouse-down current event also recognize double click")
        controller.handleClick(click(1), now: 40)
        controller.handleClick(click(1, type: .rightMouseUp), now: 40.01)
        controller.handleClick(click(1), now: 40.02)
        precondition(opened == 2, "Right click resets pending left-click sequence")
        controller.stop()
        controller.handleClick(click(2), now: 50)
        precondition(opened == 2, "Restart cannot reuse a stale first click")
        let keyboard = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        controller.handleClick(keyboard, now: 60)
        precondition(opened == 3, "Keyboard activation opens the UI without requiring mouse double click")
        precondition(MenuBarController.icon()?.size == NSSize(width: 20, height: 22)
            && MenuBarController.icon()?.isTemplate == true, "Icon uses explicit larger size and adaptive template color")
        let update = NSMenuItem(title: "检查更新", action: NSSelectorFromString("checkUpdates"), keyEquivalent: "")
        precondition(!controller.validateMenuItem(update), "Unavailable update check stays disabled")
        available = true
        precondition(controller.validateMenuItem(update), "Ready updater enables manual check")
        precondition(NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) != nil,
                     "Menu bar apple symbol must exist on supported macOS")
        var aboutOpened = 0
        controller.onAbout = { aboutOpened += 1 }
        precondition(controller.verifyAboutMenu() && aboutOpened == 1, "About routes once without opening the client or changing modules")
        controller.stop(); controller.stop()
        controller.verifyFileFeedbackJourney()
        print("PASS menu bar: single-count double actions, slow clicks, tracked mouse-down actions, right-click reset, update availability, native icon and idempotent shutdown; no status item, window or permissions created")
    }
}
