import AppKit
import ApplicationServices

// Non-presenting native windows prove the production routing without changing
// another app's focus or requesting permission. Any AX write/action is a failure.
func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError {
    fatalError("Local focus reached AX setter")
}
func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError {
    fatalError("Local focus reached AX action")
}

@MainActor final class ProbeWindow: NSWindow {
    let fixtureID: Int
    var shown = true
    var mini = false
    var focused = 0, restored = 0
    var onFocus: (() -> Void)?
    init(id: Int) {
        fixtureID = id
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                   styleMask: [.titled], backing: .buffered, defer: true)
        title = "local fixture"; isReleasedWhenClosed = false
    }
    override var windowNumber: Int { fixtureID }
    override var isVisible: Bool { shown }
    override var isMiniaturized: Bool { mini }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        precondition(Thread.isMainThread); focused += 1; onFocus?()
    }
    override func deminiaturize(_ sender: Any?) {
        precondition(Thread.isMainThread); mini = false; restored += 1
    }
}

@main struct LocalWindowRegression {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let first = ProbeWindow(id: 101), second = ProbeWindow(id: 102)
        let snapshot = LocalSwitcherWindows.snapshot()
        precondition(Set(snapshot.windows.map(\.id)) == [101, 102], "Own windows must be native snapshots")
        let inventory = WindowInventory(); inventory.start()
        var completed: [Int] = [], lastApplied = -1
        for index in 0..<12 {
            let target = snapshot.windows.first { $0.id == (index % 2 == 0 ? 101 : 102) }!
            let probe = index % 2 == 0 ? first : second
            // Await the actual native operation, not an assumed 20 ms scheduler
            // interval. Earlier callbacks are valid if they beat the next request.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                probe.onFocus = { lastApplied = index; probe.onFocus = nil; continuation.resume() }
                DispatchQueue.global().async {
                    inventory.focus(target) { _ in
                        precondition(lastApplied == index, "A superseded native focus cannot deliver after a newer one was applied")
                        precondition(!completed.contains(index), "One focus request must not complete twice")
                        completed.append(index)
                    }
                }
            }
        }
        precondition(first.focused == 6 && second.focused == 6, "Repeated native focus must run on main")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(completed.last == 11, "The latest native focus must complete")
        second.mini = true
        let local = snapshot.windows.first { $0.id == 102 }!
        let beforeStop = completed.count
        // Stop at the native operation boundary, before verification is issued.
        // This does not depend on how long the CI runner takes to resume a task.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            second.onFocus = { second.onFocus = nil; inventory.stop(); continuation.resume() }
            inventory.focus(local) { _ in completed.append(12) }
        }
        precondition(second.restored == 1 && !second.mini, "Minimized local window is restored on main")
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        precondition(completed.count == beforeStop, "Stop cancels pending native focus verification")
        second.shown = false
        precondition(!LocalSwitcherWindows.focus(102), "Closed/invisible local window cannot be focused")
        precondition(!LocalSwitcherWindows.focus(999), "Missing local ID must fail safely")
        print("PASS local windows: 12 repeated focus operations on main, no AX writes/actions, native snapshot, restore, supersession, stop and dead-window guards; no displayed windows or TCC")
        withExtendedLifetime([first, second]) {}
    }
}
