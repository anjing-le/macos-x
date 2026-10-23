import AppKit

/// A covered handover between concealment and native rendering. Release the
/// concealment assertion only after the render lease is active; restore a fresh
/// concealment assertion before dropping the lease or removing the covers.
@MainActor final class MenuBarLiveSession {
    enum Phase: String { case idle, covering, rendering, ready, activating, restoring }
    var onPhase: ((Phase) -> Void)?
    private(set) var phase = Phase.idle { didSet { if phase != oldValue { onPhase?(phase) } } }
    var onPixels: (([String: MenuBarIconPixels]) -> Void)?
    var onCovered: (([CGRect]) -> Bool)?
    var onCoverageChanged: (([CGRect]) -> Void)?
    var onEnded: (() -> Void)?
    var onFailure: (() -> Void)?
    var onExposed: (() -> Void)?
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    var pixelsStartOverride: (([MenuBarEntry], MenuBarReadToken, @escaping ([String: MenuBarIconPixels]) -> Void, @escaping () -> Void) -> Void)?
    var pixelsStopOverride: (() -> Void)?
    var replayOverride: ((MenuBarEntry, [MenuBarPointerSample], MenuBarReadToken, @escaping (Bool) -> Void) -> Void)?
    var restoreTimeout: TimeInterval = 4
    var inputTimeout: TimeInterval = 5
    private let visibility: MenuVisibilityProviding
    let cover = MenuBarNativeInteraction()
    private let pixels = MenuBarLivePixels()
    private var token: MenuBarReadToken?
    private var lease: MenuVisibilityHandle?
    private var owners: Set<pid_t> = []
    private var display = CGRect.zero
    private var activating = false, closing = false, ready = false, interacting = false
    private var pendingGesture: (() -> Void)?
    private var pendingFailure: (() -> Void)?
    private var completions: [(Bool) -> Void] = []
    private var watchdog: DispatchWorkItem?
    var isActive: Bool { token != nil }
    var isInteracting: Bool { interacting }
    init(visibility: MenuVisibilityProviding) { self.visibility = visibility }

    func start(entries: [MenuBarEntry], displayID: CGDirectDisplayID) {
        guard token == nil, !entries.isEmpty else { return }
        let token = MenuBarReadToken(); self.token = token
        phase = .covering
        owners = Set(entries.map(\.pid)); display = CGDisplayBounds(displayID)
        let timeout = DispatchWorkItem { [weak self] in self?.failed(token) }
        watchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        cover.prepare(token: token) { [weak self] ok in
            guard let self, self.token === token, !token.isCancelled else { return }
            guard ok, self.onCovered?(self.cover.coverRects) != false else { self.failed(token); return }
            self.activating = true
            let allowed = Set(entries.map(\.bundle)).union(MenuBarSections.systemOwners).union([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"])
            self.visibility.activate(allowing: Array(allowed).sorted()) { [weak self] handle in
                guard let self, self.token === token, !token.isCancelled else { handle?.invalidate(); return }
                self.activating = false; self.lease = handle
                guard handle != nil else { self.failed(token); return }
                if self.closing { self.settle(token); return }
                self.onExposed?()
                self.phase = .rendering
                let receive: ([String: MenuBarIconPixels]) -> Void = { [weak self] values in
                    guard let self, self.token === token, !self.closing else { return }
                    if !self.ready, Set(values.keys).isSuperset(of: Set(entries.map(\.bundle))) {
                        self.ready = true
                        if !self.interacting { self.watchdog?.cancel(); self.watchdog = nil; self.phase = .ready }
                        self.cover.revealStableSuffix(owners: self.owners, token: token) { [weak self] in self?.onCoverageChanged?($0) }
                    }
                    self.onPixels?(values)
                    if self.ready { let pending = self.pendingGesture; self.pendingGesture = nil; pending?() }
                }
                let failure = { [weak self] in self?.failed(token) }
                // Remote widget pixels mount after AX geometry has reflowed.
                // Keep the previous verified image through that handover.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.token === token, !self.closing else { return }
                    if let start = self.pixelsStartOverride { start(entries, token, receive, { failure() }) }
                    else { self.pixels.start(displayID: MenuBarSourceDisplay.current(fallback: displayID), entries: entries, token: token, receive: receive, failure: { failure() }) }
                }
            }
        }
    }
    /// The already-rendered native owner handles the original gesture directly.
    /// Keep the covers/lease until its mouse-up, then drop the rendering lease.
    func activate(_ entry: MenuBarEntry, samples: [MenuBarPointerSample], completion: @escaping (Bool) -> Void) -> Bool {
        guard let token, !closing, !interacting else { return false }
        interacting = true
        phase = .activating
        pendingFailure = { completion(false) }
        watchdog?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.failed(token) }
        watchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + inputTimeout, execute: timeout)
        let perform = { [weak self] in
            guard let self, self.token === token, !self.closing else { return }
            self.stopPixels()
            self.onCoverageChanged?(self.cover.restoreFullCovers())
            let finish: (Bool) -> Void = { [weak self] ok in
                guard let self, self.token === token, !self.closing else { return }
                self.pendingFailure = nil
                self.finish { completion(ok && $0) }
            }
            // A single native owner gets the full available bar width, even on
            // a notched display whose system overflow hid it in a larger group.
            let allowed = Set([entry.bundle, Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"]).union(MenuBarSections.systemOwners)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, self.token === token, !self.closing else { return }
                self.visibility.activate(allowing: Array(allowed).sorted()) { [weak self] handle in
                    guard let self, self.token === token, !self.closing else { handle?.invalidate(); return }
                    guard let handle else { self.failed(token); return }
                    let previous = self.lease; self.lease = handle; previous?.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self, self.token === token, !self.closing else { return }
                        if let replay = self.replayOverride { replay(entry, samples, token, finish) }
                        else { self.cover.replay(samples, entry: entry, display: self.display, token: token, completion: finish) }
                    }
                }
            }
        }
        if ready { perform() } else { pendingGesture = perform }
        return true
    }
    func finish(completion: ((Bool) -> Void)? = nil) {
        if let completion, completions.count < 8 { completions.append(completion) }
        guard let token else { drain(true); return }
        guard !closing else { return }; closing = true
        phase = .restoring
        stopPixels(); pendingGesture = nil
        watchdog?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.token === token else { return }; self.onFailure?(); self.cancel()
        }
        watchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + restoreTimeout, execute: timeout)
        if activating { return }
        if lease == nil { cleanup(token, restored: true); return }
        settle(token)
    }
    private func settle(_ token: MenuBarReadToken) {
        cover.cancelInput()
        guard let onRestore else { lease?.invalidate(); lease = nil; onFailure?(); cleanup(token, restored: false); return }
        onRestore { [weak self] restored in
            guard let self, self.token === token else { return }
            self.lease?.invalidate(); self.lease = nil
            guard restored else { self.onFailure?(); self.cleanup(token, restored: false); return }
            self.cover.waitForHidden(self.owners) { [weak self] confirmed in
                guard let self, self.token === token else { return }
                if !confirmed { self.onFailure?() }
                self.cleanup(token, restored: confirmed)
            }
        }
    }
    private func failed(_ token: MenuBarReadToken) {
        guard self.token === token, !closing else { return }
        onFailure?()
        if activating { cancel() } else { finish() }
    }
    private func cleanup(_ token: MenuBarReadToken, restored: Bool) {
        guard self.token === token else { return }
        watchdog?.cancel(); watchdog = nil; token.cancel(); self.token = nil
        stopPixels(); cover.cancel(); owners.removeAll()
        ready = false; closing = false; interacting = false; activating = false; pendingGesture = nil
        phase = .idle
        let failedGesture = pendingFailure; pendingFailure = nil
        onEnded?(); drain(restored); failedGesture?()
    }
    private func drain(_ restored: Bool) { let pending = completions; completions.removeAll(); pending.forEach { $0(restored) } }
    private func stopPixels() { if let stop = pixelsStopOverride { stop() } else { pixels.stop() } }
    /// Explicit stop/show-all may reveal native icons. Late lease callbacks are
    /// invalidated by identity; no cover, stream or pending gesture survives.
    func cancel() {
        token?.cancel(); token = nil; watchdog?.cancel(); watchdog = nil
        lease?.invalidate(); lease = nil; stopPixels(); cover.cancel(); owners.removeAll()
        ready = false; closing = false; interacting = false; activating = false; pendingGesture = nil
        phase = .idle
        let failedGesture = pendingFailure; pendingFailure = nil
        onEnded?(); drain(false); failedGesture?()
    }
}
