import AppKit

// Drives the production user driver; replaces only Sparkle events and the UI surface.
// No network, windows, updater startup, preferences or installation.
protocol SPUUserDriver {}
final class SPUUpdatePermissionRequest {}
final class SUUpdatePermissionResponse {
    init(automaticUpdateChecks: Bool, automaticUpdateDownloading: NSNumber, sendSystemProfile: Bool) {}
}
enum SPUUserUpdateChoice: Equatable { case install, skip, dismiss }
struct SPUUserUpdateState {
    enum Stage { case notDownloaded, installing }
    let userInitiated: Bool
    var stage: Stage = .notDownloaded
}
final class SUAppcastItem {
    let displayVersionString = "0.0.30"
    let isInformationOnlyUpdate = false
    let isCriticalUpdate = false
    let infoURL: URL? = nil
}
final class SPUDownloadData {}
let SPUNoUpdateFoundReasonKey = "reason"
enum SPUNoUpdateFoundReason: Int32 {
    case onLatestVersion, onNewerThanLatestVersion, systemIsTooOld, systemIsTooNew, hardwareDoesNotSupportARM64
}
enum UpdatePanelProgress { case hidden, indeterminate, fraction(Double) }
@MainActor final class UpdatePanel {
    static var shows = 0
    static var primary: (() -> Void)?
    static var secondary: (() -> Void)?
    func show(title: String, detail: String? = nil, progress: UpdatePanelProgress = .hidden,
              primaryTitle: String? = nil, primaryAction: (() -> Void)? = nil,
              secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil, onClose: (() -> Void)? = nil) {
        Self.shows += 1; Self.primary = primaryAction; Self.secondary = secondaryAction
    }
    func setProgress(_ value: UpdatePanelProgress, detail: String? = nil) {}
    func dismiss() {}
    func focus() {}
}
@main @MainActor struct UpdatePresentationRegression {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let driver = UpdateUserDriver()
        var availability = false, notifications = 0, replies = [SPUUserUpdateChoice](), acknowledgements = 0
        driver.onAvailabilityChanged = { availability = $0; notifications += 1 }
        driver.showUpdateFound(with: SUAppcastItem(), state: SPUUserUpdateState(userInitiated: false)) { replies.append($0) }
        check(availability && notifications == 1, "scheduled discovery signals availability")
        check(UpdatePanel.shows == 0 && replies == [.dismiss], "scheduled discovery never presents or starts download")
        driver.dismissUpdateInstallation()
        check(availability, "ending check session retains availability")
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) { acknowledgements += 1 }
        check(UpdatePanel.shows == 0 && acknowledgements == 1 && availability, "offline background check stays silent and retains badge")
        driver.showUpdateNotFoundWithError(NSError(domain: "Sparkle", code: 1,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])) { acknowledgements += 1 }
        check(!availability && acknowledgements == 2 && UpdatePanel.shows == 0, "latest result clears badge silently")
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        check(UpdatePanel.shows == 1, "manual check presents progress")
        let staleCancel = UpdatePanel.secondary!
        driver.showUpdateFound(with: SUAppcastItem(), state: SPUUserUpdateState(userInitiated: true)) { replies.append($0) }
        check(availability && UpdatePanel.shows == 2, "manual discovery presents update choice")
        staleCancel()
        check(cancellations == 0 && replies.count == 1, "stale progress action cannot cancel new choice")
        let later = UpdatePanel.secondary!
        later(); later()
        check(replies == [.dismiss, .dismiss] && availability, "later replies once and keeps available badge")
        driver.dismissUpdateInstallation()
        driver.showUserInitiatedUpdateCheck {}
        driver.showUpdateFound(with: SUAppcastItem(), state: SPUUserUpdateState(userInitiated: true)) { replies.append($0) }
        UpdatePanel.primary?()
        check(replies.last == .install, "only explicit update action permits download/install")
        driver.showReady { replies.append($0) }
        UpdatePanel.secondary?()
        check(replies.last == .skip, "ready-to-install cancellation does not permit install on quit")
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        check(!availability, "completed install clears badge")
        UpdatePanel.primary?()
        check(acknowledgements == 3, "completed install acknowledgement occurs once")
        driver.dismissUpdateInstallation()
        driver.showUserInitiatedUpdateCheck {}
        let before = UpdatePanel.shows
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) { acknowledgements += 1 }
        check(UpdatePanel.shows == before + 1, "manual network failure remains visible")
        UpdatePanel.primary?()
        check(acknowledgements == 4, "manual failure acknowledgement")
        print("PASS update presentation: \(checks) checks; scheduled silence, availability, manual flow, stale/one-shot callbacks and installation cancellation; mocked UI/Sparkle")
    }
}
